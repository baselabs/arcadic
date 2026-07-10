defmodule Arcadic.Import do
  @moduledoc """
  Bulk load over ArcadeDB's `IMPORT DATABASE` command (imports a CSV / JSON / JSONL / GraphML /
  Neo4j / OrientDB / ArcadeDB export into `conn.database`, server-side).

  Tenant-blind. The source URL CANNOT be a bound parameter (ArcadeDB parse-rejects
  `IMPORT DATABASE :url`), so it is interpolated — behind a strict POSITIVE character allowlist
  (RFC 3986 URL characters minus the single quote and backslash) plus a scheme allowlist, which
  closes the SQL-string-literal injection surface by construction (ArcadeDB honors backslash-
  escapes inside single-quoted literals, so a mere quote-denylist would be unsound). `with:`
  import settings are developer config: names are `Arcadic.Identifier`-validated; number/boolean
  values are interpolated bare, and string values are single-quoted behind a positive ASCII charset
  allowlist (`'` / `\\` / control / non-ASCII excluded) — injection-inert either way. Every rejection
  is value-free (never echoes the offending URL / name / value — AGENTS.md Rule 3).

  ## Security & operational notes

  ArcadeDB blocks imports from private/loopback hosts by default (`importBlockLocalNetworks`) →
  a `%Arcadic.Error{reason: :unauthorized, http_status: 403, exception: "java.lang.SecurityException"}`.
  That is DISTINCT from an auth failure (`exception: "com.arcadedb.server.security.ServerSecurityException"`);
  disambiguate on `error.exception`. `file://` bypasses the block (server-local files).

  A source URL may embed basic-auth credentials (`https://user:pass@host/…`). The success row's
  `fromUrl` and a failed import's `error.detail` (quarantined from `message/1`/`inspect/1` but
  reachable) may echo it — do not embed credentials in the URL, or redact before logging.

  For an incremental (create → bulk-load → index) load, order it yourself: create the type,
  load the rows (a `command/4` loop or a `transaction/3`), then create the index — a `LSM_TREE`
  or dense `LSM_VECTOR` index retro-indexes existing rows, but a `LSM_SPARSE_VECTOR` index must
  be created BEFORE the load (it does not retro-index; see `Arcadic.Vector`). arcadic ships no
  index-deferral helper because the correct ordering is index-type-specific and arcadic is
  tenant-blind.
  """
  alias Arcadic.{Conn, Opts}

  # A string with:-value is interpolated into a single-quoted SQL literal, so it uses a POSITIVE
  # ASCII allowlist (the URL-validator's lane, `Identifier.validate_url/1`): the safe printable set MINUS `'` and
  # `\` (ArcadeDB honors backslash-escapes inside a quoted literal, so both must be excluded). Being
  # ASCII-only it also excludes control bytes AND invalid UTF-8 (a >=0x80 byte would make Jason.encode!
  # raise with the value bytes — a Rule-3 leak). arcadic stays tenant-blind about the value's MEANING;
  # a string setting is NOT a server-fetch vector (probed: a loopback `mapping` is not fetched — the
  # main source URL is the only SSRF vector, server-blocked by importBlockLocalNetworks).
  @setting_string_pattern ~r/\A[A-Za-z0-9 \-._~:\/?#\[\]@!$&()*+,;=%]+\z/

  @doc """
  Imports `url` into `conn.database` via `IMPORT DATABASE '<url>'[ WITH …]`. Returns
  `{:ok, rows}` (rows carry `operation`/`fromUrl`/`parsedRecords`/`result`) or
  `{:error, Arcadic.Error.t() | Arcadic.TransportError.t()}`.

  `opts`: `with` — a keyword list of import settings whose values are numbers, booleans, or
  allowlisted strings (e.g. `with: [commitEvery: 100, wal: false, mapping: "map.json"]`).

  Raises `ArgumentError` (value-free, before any request) on an invalid URL or `with:` entry.
  """
  @spec database(Conn.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, Exception.t()}
  def database(%Conn{} = conn, url, opts \\ []) do
    validate_url!(url)
    Opts.validate_keys!(opts, [:with])
    with_clause = build_with(Keyword.get(opts, :with, []))
    Arcadic.command(conn, "IMPORT DATABASE '#{url}'#{with_clause}", %{}, language: "sql")
  end

  @doc "Imports `url`, returning the rows or raising."
  @spec database!(Conn.t(), String.t(), keyword()) :: [map()]
  def database!(%Conn{} = conn, url, opts \\ []), do: bang(database(conn, url, opts))

  # --- URL validation: delegates to the shared audited allowlist validator, mapping its value-free
  # reasons to Import's messages; still fail-closed (raises) before any wire call. ---

  defp validate_url!(url) do
    case Arcadic.Identifier.validate_url(url) do
      :ok ->
        :ok

      {:error, :not_a_string} ->
        raise ArgumentError, "import url must be a string"

      {:error, :empty} ->
        raise ArgumentError, "import url must be non-empty"

      {:error, :too_long} ->
        raise ArgumentError, "import url exceeds 2048 characters"

      {:error, :invalid_chars} ->
        raise ArgumentError, "import url contains characters outside the allowed URL set"

      {:error, :invalid_scheme} ->
        raise ArgumentError, "import url scheme must be one of [\"http\", \"https\", \"file\"]"

      {:error, :invalid_uri} ->
        raise ArgumentError, "import url is not a valid URI"
    end
  end

  # --- WITH settings: developer config; names identifier-validated, values number|boolean|string
  # (string values single-quoted behind a positive ASCII charset allowlist, injection-inert) ---

  # Shared no-parens WITH-grammar seam: `Arcadic.Export` reuses this one builder so import + export
  # emit an identical clause. Public `@doc false` (not part of the documented API); `Import.database/3`
  # remains its internal caller. Mirrors `Arcadic.Bolt`'s `@doc false` `statement_of/1` precedent.
  @doc false
  @spec build_with(keyword()) :: String.t()
  def build_with([]), do: ""

  def build_with(settings) when is_list(settings) do
    pairs =
      Enum.map_join(settings, ", ", fn {name, value} ->
        "#{setting_name!(name)} = #{setting_value!(value)}"
      end)

    " WITH #{pairs}"
  end

  def build_with(_), do: raise(ArgumentError, "with: must be a keyword list of settings")

  defp setting_name!(name) when is_atom(name) do
    case Arcadic.Identifier.validate(Atom.to_string(name)) do
      :ok -> Atom.to_string(name)
      {:error, :invalid_identifier} -> raise ArgumentError, "invalid import setting name"
    end
  end

  defp setting_name!(_), do: raise(ArgumentError, "import setting name must be an atom")

  # Booleans are atoms, not numbers — this clause must precede the numeric clauses.
  defp setting_value!(v) when is_boolean(v), do: to_string(v)
  defp setting_value!(v) when is_integer(v), do: Integer.to_string(v)
  defp setting_value!(v) when is_float(v), do: Float.to_string(v)

  defp setting_value!(v) when is_binary(v) do
    if Regex.match?(@setting_string_pattern, v),
      do: "'#{v}'",
      else: raise(ArgumentError, "import setting value has characters outside the allowed set")
  end

  defp setting_value!(_),
    do: raise(ArgumentError, "import setting value must be a number, boolean, or string")

  defp bang({:ok, rows}), do: rows
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)
end
