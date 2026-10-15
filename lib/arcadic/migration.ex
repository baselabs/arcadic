defmodule Arcadic.Migration do
  @moduledoc """
  Behaviour for an ArcadeDB migration — a versioned pair of forward/backward steps.
  Migrations are tenant-blind schema changes; author raw DDL/DML via `Arcadic.command/4`
  in `up/1` and `down/1`.

  Only `:ok` finalizes a migration (`Arcadic.Migrator` marks it done); an
  `{:error, reason}` return (or a raise) leaves the attempt's marker in place and the
  next migrator run refuses until you reconcile — see `Arcadic.Migrator`'s
  "Crash recovery" docs.

  Migrations SHOULD be idempotent (`IF NOT EXISTS` / `IF EXISTS`) — replay can still
  happen outside the marker window (a manually deleted tracking row, a version number
  reused) — but the marker, not author discipline, is the crash-safety mechanism.

      defmodule MyApp.Migrations.V1 do
        @behaviour Arcadic.Migration
        @impl true
        def version, do: 1
        @impl true
        def up(conn) do
          Arcadic.command!(conn, "CREATE VERTEX TYPE User IF NOT EXISTS", %{}, language: "sql")
          :ok
        end
        @impl true
        def down(conn) do
          Arcadic.command!(conn, "DROP TYPE User IF EXISTS", %{}, language: "sql")
          :ok
        end
      end
  """

  @doc "A unique, ascending version (integer — typically a timestamp)."
  @callback version() :: pos_integer()
  @doc "Apply the migration. Only `:ok` finalizes; `{:error, reason}` leaves the attempt marker."
  @callback up(Arcadic.Conn.t()) :: :ok | {:error, term()}
  @doc "Reverse the migration. Only `:ok` finalizes; `{:error, reason}` leaves the attempt marker."
  @callback down(Arcadic.Conn.t()) :: :ok | {:error, term()}
end
