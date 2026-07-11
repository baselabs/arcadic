defmodule Arcadic.Function do
  @moduledoc """
  ArcadeDB user-defined functions — tenant-blind `DEFINE FUNCTION` / `DELETE FUNCTION` DDL,
  parallel to `Arcadic.FullText`/`Arcadic.Geo`.

  A function `name` is a dotted `library.fn` reference validated **per segment**
  (`String.split(name, ".")`, each segment through `Arcadic.Identifier` — a bare
  `Identifier.validate` is wrong, it rejects `.`; a degenerate `lib..fn` yields an empty
  segment that fails closed). The body is embedded as a `"..."` DDL literal and admitted only
  through an internal positive-allowlist guard — the sole breakout byte `"`, the backslash,
  and control/line bytes are rejected value-free *before any wire call*. ArcadeDB's `"..."`
  body literal has **no escape** (`\\"`, doubled `""`, single-quote delimiter, and newlines all
  parse-error), so the single-line/single-quoted-body limit is a substrate constraint, not a
  narrowing — ArcadeDB's own e2e tests use only single-line, single-quoted-JS bodies.

  ## Calling a defined function

  There is **no call wrapper** here (a call wrapper is a query template — a charter non-goal).
  Invoke a defined function inside an ordinary `Arcadic.query/4` via the backtick idiom:

      Arcadic.query(conn, "SELECT `math.sum`(:a, :b) AS total", %{"a" => 1, "b" => 2},
        language: "sql")

  The library/function name is interpolated (behind the per-segment allowlist); the arguments
  ride the `params` map, never the statement.
  """
  alias Arcadic.{Conn, Identifier, Opts}

  @define_opts [:language]

  # Friendly language atom → the `LANGUAGE <token>` emitted into the DDL. `:js` is the default.
  @languages %{js: "js", sql: "sql", cypher: "cypher"}

  @doc """
  Defines a function `name` (a dotted `library.fn`) with a `body` literal, optional `params`
  (a list of parameter-name atoms/strings, each `Identifier`-validated), and `opts`:
  `:language` (`:js` default | `:sql` | `:cypher`).

  Emits `DEFINE FUNCTION lib.fn "body" [PARAMETERS [a, b]] LANGUAGE <lang>`. Value-free on a bad
  name (`:invalid_identifier`), a bad param (`:invalid_identifier`), an unencodable body
  (`:unencodable_body`), or an unknown language (`:invalid_language`) — none echo the offending
  value. A non-binary body is a caller-contract violation and raises `ArgumentError` value-free.
  """
  @spec define(Conn.t(), String.t(), String.t(), [atom() | String.t()], keyword()) ::
          :ok | {:error, atom() | Exception.t()}
  def define(%Conn{} = conn, name, body, params \\ [], opts \\ []) do
    Opts.validate_keys!(opts, @define_opts)

    with {:ok, lang} <- resolve_language(opts),
         {:ok, _} <- validate_name(name),
         {:ok, body2} <- Arcadic.DDLBody.encode(body),
         {:ok, names} <- validate_params(params) do
      command_ok(
        conn,
        "DEFINE FUNCTION #{name} \"#{body2}\"#{params_clause(names)} LANGUAGE #{lang}"
      )
    end
  end

  @doc "Defines a function, raising on error."
  @spec define!(Conn.t(), String.t(), String.t(), [atom() | String.t()], keyword()) :: :ok
  def define!(%Conn{} = conn, name, body, params \\ [], opts \\ []),
    do: bang(define(conn, name, body, params, opts))

  @doc "Deletes a function `name` (a dotted `library.fn`); idempotent server-side once the library exists (deleting from a never-defined library errors). Value-free on a bad name."
  @spec delete(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def delete(%Conn{} = conn, name) do
    with {:ok, _} <- validate_name(name) do
      command_ok(conn, "DELETE FUNCTION #{name}")
    end
  end

  @doc "Deletes a function, raising on error."
  @spec delete!(Conn.t(), String.t()) :: :ok
  def delete!(%Conn{} = conn, name), do: bang(delete(conn, name))

  # --- private ---

  # `:js` default; an unknown (or non-atom) language rejects value-free — the bare atom never
  # echoes the caller-supplied value.
  defp resolve_language(opts) do
    case Map.fetch(@languages, Keyword.get(opts, :language, :js)) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, :invalid_language}
    end
  end

  # A dotted `library.fn`: ≥2 non-empty segments, each an allowlisted identifier. `lib..fn` splits
  # to an empty middle segment that `Identifier.validate` rejects; a bare `nolib` has one segment.
  # Value-free (`:invalid_identifier`) on any failure; the total fallback handles a non-binary name.
  defp validate_name(name) when is_binary(name) do
    segments = String.split(name, ".")

    if length(segments) >= 2 and Enum.all?(segments, &(Identifier.validate(&1) == :ok)),
      do: {:ok, name},
      else: {:error, :invalid_identifier}
  end

  defp validate_name(_name), do: {:error, :invalid_identifier}

  # Each param → an allowlisted name string. A non-atom/non-binary param collapses to "" (which
  # `Identifier.validate` rejects) rather than reaching `to_string/1` — whose `Protocol` raise on
  # an unusual term would echo the caller value (Rule 3). Returns {:ok, [names]} in order.
  defp validate_params(params) when is_list(params) do
    Enum.reduce_while(params, {:ok, []}, fn param, {:ok, acc} ->
      name = param_name(param)

      case Identifier.validate(name) do
        :ok -> {:cont, {:ok, [name | acc]}}
        {:error, :invalid_identifier} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp validate_params(_params), do: {:error, :invalid_identifier}

  defp param_name(param) when is_atom(param), do: Atom.to_string(param)
  defp param_name(param) when is_binary(param), do: param
  defp param_name(_param), do: ""

  defp params_clause([]), do: ""
  defp params_clause(names), do: " PARAMETERS [#{Enum.join(names, ", ")}]"

  defp command_ok(conn, statement) do
    case Arcadic.command(conn, statement, %{}, language: "sql") do
      {:ok, _rows} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp bang(:ok), do: :ok
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)

  defp bang({:error, reason}),
    do: raise(ArgumentError, "function operation failed: #{inspect(reason)}")
end
