defmodule Arcadic.Migration do
  @moduledoc """
  Behaviour for an ArcadeDB migration — a versioned pair of forward/backward steps.
  Migrations are tenant-blind schema changes; author raw DDL/DML via `Arcadic.command/4`
  in `up/1` and `down/1`.

      defmodule MyApp.Migrations.V1 do
        @behaviour Arcadic.Migration
        @impl true
        def version, do: 1
        @impl true
        def up(conn), do: Arcadic.command!(conn, "CREATE VERTEX TYPE User", %{}, language: "sql") && :ok
        @impl true
        def down(conn), do: Arcadic.command!(conn, "DROP TYPE User IF EXISTS", %{}, language: "sql") && :ok
      end
  """

  @doc "A unique, ascending version (integer — typically a timestamp)."
  @callback version() :: pos_integer()
  @doc "Apply the migration."
  @callback up(Arcadic.Conn.t()) :: :ok
  @doc "Reverse the migration."
  @callback down(Arcadic.Conn.t()) :: :ok
end
