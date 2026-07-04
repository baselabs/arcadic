defmodule Arcadic.Integration.MigratorTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias Arcadic.{Conn, Migrator, Server}

  defmodule V1 do
    @behaviour Arcadic.Migration
    @impl true
    def version, do: 1
    @impl true
    def up(conn),
      do:
        (
          Arcadic.command!(conn, "CREATE VERTEX TYPE Account", %{}, language: "sql")
          :ok
        )

    @impl true
    def down(conn),
      do:
        (
          Arcadic.command!(conn, "DROP TYPE Account IF EXISTS", %{}, language: "sql")
          :ok
        )
  end

  defmodule V2 do
    @behaviour Arcadic.Migration
    @impl true
    def version, do: 2
    @impl true
    def up(conn),
      do:
        (
          Arcadic.command!(conn, "CREATE VERTEX TYPE Ledger", %{}, language: "sql")
          :ok
        )

    @impl true
    def down(conn),
      do:
        (
          Arcadic.command!(conn, "DROP TYPE Ledger IF EXISTS", %{}, language: "sql")
          :ok
        )
  end

  defmodule Registry do
    use Arcadic.MigrationRegistry
    migrations([V1, V2])
  end

  setup_all do
    url = System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL")
    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    admin = Conn.new(url, "arcadic_mig_it", auth: {"root", pass})
    _ = Server.drop_database(admin, "arcadic_mig_it")
    :ok = Server.create_database!(admin, "arcadic_mig_it")
    on_exit(fn -> Server.drop_database(admin, "arcadic_mig_it") end)
    {:ok, conn: admin}
  end

  test "migrate runs all, status reflects up, rollback reverses, reset re-applies", %{conn: conn} do
    assert {:ok, 2} = Migrator.migrate(conn, Registry)
    assert {:ok, [{1, :up}, {2, :up}]} = Migrator.status(conn, Registry)
    # schema exists:
    assert {:ok, [_]} =
             Arcadic.command(conn, "SELECT FROM schema:types WHERE name = 'Ledger'", %{},
               language: "sql"
             )

    # re-running migrate is a no-op:
    assert {:ok, 0} = Migrator.migrate(conn, Registry)

    # rollback the last one:
    assert {:ok, 1} = Migrator.rollback(conn, Registry, 1)
    assert {:ok, [{1, :up}, {2, :down}]} = Migrator.status(conn, Registry)

    # reset: rollback all remaining, then migrate all:
    assert {:ok, 2} = Migrator.reset(conn, Registry)
    assert {:ok, [{1, :up}, {2, :up}]} = Migrator.status(conn, Registry)
  end
end
