defmodule Arcadic.Trigger do
  @moduledoc """
  ArcadeDB triggers — tenant-blind `CREATE TRIGGER` / `DROP TRIGGER` DDL, parallel to
  `Arcadic.Function`/`Arcadic.Geo`.

  A trigger fires a `timing` (`:before` / `:after`) × `event`
  (`:create` / `:delete` / `:update` / `:read`) action on a type, running a body in one of three
  action languages (`:sql` / `:javascript` / `:java`). Each of the three dimensions is an internal
  atom → token allowlist — an off-enum atom rejects value-free before any wire call, never echoing
  the caller value.

  The `type` name is the only identifier injection surface (interpolated behind `Arcadic.Identifier`,
  closed by construction); the body is embedded as a `"..."` DDL literal and admitted only through
  the same reject-not-escape guard `Arcadic.Function` uses — the sole breakout byte `"`, the
  backslash, and control/line bytes reject value-free (`:unencodable_body`) before any wire call.
  ArcadeDB's `"..."` body literal has no escape, so a body needing one is a substrate limit, not a
  narrowing. `DROP TRIGGER` takes no `IF EXISTS` clause (probe-confirmed) — dropping a missing
  trigger is a server error.
  """
  alias Arcadic.{Conn, Identifier, Opts}

  @create_opts [:timing, :event, :execute]

  # atom → emitted token allowlists. An off-enum atom (or non-atom) `Map.fetch` :error → a
  # value-free reject that never echoes the caller value.
  @timings %{before: "BEFORE", after: "AFTER"}
  @events %{create: "CREATE", delete: "DELETE", update: "UPDATE", read: "READ"}
  @langs %{sql: "SQL", javascript: "JAVASCRIPT", java: "JAVA"}

  @doc """
  Creates a trigger `name` on `type`, firing a `timing` × `event` action that runs `execute`.

  `opts` (all required): `:timing` (`:before` | `:after`), `:event`
  (`:create` | `:delete` | `:update` | `:read`), `:execute` (a `{lang, code}` tuple — `lang` one of
  `:sql` | `:javascript` | `:java`, `code` a single-line body literal). Emits
  `CREATE TRIGGER name TIMING EVENT ON type EXECUTE LANG "code"`.

  Value-free on a bad identifier (`:invalid_identifier`), an off-enum timing / event / language
  (`:invalid_timing` / `:invalid_event` / `:invalid_language`), a malformed or missing `:execute`
  (`:invalid_execute`), or an unencodable body (`:unencodable_body`) — none echo the offending
  value. A non-binary body is a caller-contract violation and raises `ArgumentError` value-free.
  """
  @spec create(Conn.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, atom() | Exception.t()}
  def create(%Conn{} = conn, name, type, opts \\ []) do
    Opts.validate_keys!(opts, @create_opts)

    with {:ok, lang_atom, code} <- fetch_execute(opts),
         {:ok, timing} <- resolve(@timings, Keyword.get(opts, :timing), :invalid_timing),
         {:ok, event} <- resolve(@events, Keyword.get(opts, :event), :invalid_event),
         {:ok, lang} <- resolve(@langs, lang_atom, :invalid_language),
         :ok <- Identifier.validate(name),
         :ok <- Identifier.validate(type),
         {:ok, code2} <- Arcadic.DDLBody.encode(code) do
      command_ok(
        conn,
        "CREATE TRIGGER #{name} #{timing} #{event} ON #{type} EXECUTE #{lang} \"#{code2}\""
      )
    end
  end

  @doc "Creates a trigger, raising on error."
  @spec create!(Conn.t(), String.t(), String.t(), keyword()) :: :ok
  def create!(%Conn{} = conn, name, type, opts \\ []),
    do: bang(create(conn, name, type, opts))

  @doc "Drops a trigger `name` (no `IF EXISTS` — a missing trigger is a server error). Value-free on a bad name."
  @spec drop(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop(%Conn{} = conn, name) do
    with :ok <- Identifier.validate(name) do
      command_ok(conn, "DROP TRIGGER #{name}")
    end
  end

  @doc "Drops a trigger, raising on error."
  @spec drop!(Conn.t(), String.t()) :: :ok
  def drop!(%Conn{} = conn, name), do: bang(drop(conn, name))

  # --- private ---

  # Guards the `:execute` shape value-free BEFORE destructuring: a non-tuple (or missing, or
  # non-atom-lang) value falls to the total clause and returns `:invalid_execute` rather than
  # MatchError-echoing the caller value (Rule 3). `code` type is checked downstream by `DDLBody.encode`.
  defp fetch_execute(opts) do
    case Keyword.fetch(opts, :execute) do
      {:ok, {lang_atom, code}} when is_atom(lang_atom) -> {:ok, lang_atom, code}
      _ -> {:error, :invalid_execute}
    end
  end

  # atom → token via the allowlist; an off-enum (or non-atom) key rejects value-free with the
  # supplied reason atom — the bare atom never echoes the caller-supplied value.
  defp resolve(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, reason}
    end
  end

  defp command_ok(conn, statement) do
    case Arcadic.command(conn, statement, %{}, language: "sql") do
      {:ok, _rows} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp bang(:ok), do: :ok
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)

  defp bang({:error, reason}),
    do: raise(ArgumentError, "trigger operation failed: #{inspect(reason)}")
end
