defmodule Arcadic.MaterializedView do
  @moduledoc """
  ArcadeDB materialized views — tenant-blind `CREATE MATERIALIZED VIEW` / `DROP MATERIALIZED VIEW`
  DDL, parallel to `Arcadic.Function`/`Arcadic.Trigger`/`Arcadic.Geo`.

  Unlike `Arcadic.Function`/`Arcadic.Trigger`, the view's SELECT statement is deliberately NOT
  routed through a DDL-body reject-not-escape guard: it is raw trailing SQL, not a `"..."`-quoted
  literal, so a `'single-quoted string'` inside a WHERE clause is legitimate SQL and must pass
  through verbatim. Its injection safety instead rests on ArcadeDB's live-verified single-statement
  backstop — a `;`-separated second statement is a parse error — so the SELECT cannot smuggle a
  second command regardless of its content. The `name` is the only identifier injection surface
  (interpolated behind `Arcadic.Identifier`, closed by construction). `DROP MATERIALIZED VIEW`
  takes no `IF EXISTS` clause (mirrors `Arcadic.Trigger`) — dropping a missing view is a server
  error.
  """
  alias Arcadic.{Conn, Identifier}

  @doc """
  Creates a materialized view `name` from `select_sql`, emitting
  `CREATE MATERIALIZED VIEW name AS select_sql` — `select_sql` rides through verbatim (see
  moduledoc for the injection-safety rationale).

  Value-free on a bad name (`:invalid_identifier`). A non-binary `select_sql` is a caller-contract
  violation and raises `ArgumentError` value-free (never echoes the offending value).
  """
  @spec create(Conn.t(), String.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def create(%Conn{} = conn, name, select_sql) when is_binary(select_sql) do
    with :ok <- Identifier.validate(name) do
      command_ok(conn, "CREATE MATERIALIZED VIEW #{name} AS #{select_sql}")
    end
  end

  def create(_conn, _name, _select_sql), do: raise(ArgumentError, "select must be a string")

  @doc "Creates a materialized view, raising on error."
  @spec create!(Conn.t(), String.t(), String.t()) :: :ok
  def create!(%Conn{} = conn, name, select_sql), do: bang(create(conn, name, select_sql))

  @doc """
  Drops a materialized view `name` (no `IF EXISTS` — a missing view is a server error). Value-free
  on a bad name.
  """
  @spec drop(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop(%Conn{} = conn, name) do
    with :ok <- Identifier.validate(name) do
      command_ok(conn, "DROP MATERIALIZED VIEW #{name}")
    end
  end

  @doc "Drops a materialized view, raising on error."
  @spec drop!(Conn.t(), String.t()) :: :ok
  def drop!(%Conn{} = conn, name), do: bang(drop(conn, name))

  # --- private ---

  defp command_ok(conn, statement) do
    case Arcadic.command(conn, statement, %{}, language: "sql") do
      {:ok, _rows} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp bang(:ok), do: :ok
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)

  defp bang({:error, reason}),
    do: raise(ArgumentError, "materialized view operation failed: #{inspect(reason)}")
end
