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

  # A migration that DIES mid-up (deterministic in-process kill — the crash window itself):
  # the marker was committed BEFORE the callback ran, so the next migrate refuses instead of
  # re-running a possibly half-applied migration, and resolve records the operator's outcome.
  defmodule Killer do
    @behaviour Arcadic.Migration
    @impl true
    def version, do: 9

    @impl true
    def up(conn) do
      # Half-applied on purpose: this statement COMMITS before the process dies.
      Arcadic.command!(conn, "CREATE VERTEX TYPE HalfApplied IF NOT EXISTS", %{}, language: "sql")
      Process.exit(self(), :kill)
    end

    @impl true
    def down(conn) do
      Arcadic.command!(conn, "DROP TYPE HalfApplied IF EXISTS", %{}, language: "sql")
      :ok
    end
  end

  defmodule KillerRegistry do
    use Arcadic.MigrationRegistry
    migrations([Killer])
  end

  # The crash window itself, live: run the killer migration in a nolinked child, await its
  # :killed exit, then prove the loud-stop contract end to end on the real substrate.
  test "kill-proof contract: marker survives, migrate refuses, callback does not re-run, resolve recovers",
       %{conn: conn} do
    db = "arcadic_mig_kill2_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    scoped = %{conn | database: db}
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)

    {:ok, :killed} = kill_during_migrate(scoped, KillerRegistry)

    # The marker is durable: interrupted/1 sees version 9.
    assert {:ok, [9]} = Migrator.interrupted(scoped)

    # The next migrate REFUSES (value-free) instead of re-running the killed migration.
    assert {:error, %Arcadic.Error{reason: :interrupted_migration}} =
             Migrator.migrate(scoped, KillerRegistry)

    # ...and the half-applied DDL from the dead attempt is still there (the operator inspects
    # exactly this before resolving).
    assert {:ok, [_]} =
             Arcadic.command(scoped, "SELECT FROM schema:types WHERE name = 'HalfApplied'", %{},
               language: "sql"
             )

    # The operator establishes it APPLIED → resolve finalizes → migrate proceeds (no-op).
    assert :ok = Migrator.resolve(scoped, 9, :applied)
    assert {:ok, []} = Migrator.interrupted(scoped)
    assert {:ok, 0} = Migrator.migrate(scoped, KillerRegistry)
  end

  test "legacy status-less rows read as applied; a down_started marker refuses rollback", %{
    conn: conn
  } do
    db = "arcadic_mig_legacy_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    scoped = %{conn | database: db}
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)

    # Simulate a pre-marker-contract database: a tracking row with NO status property.
    :ok =
      Arcadic.command!(scoped, "CREATE DOCUMENT TYPE _arcadic_migrations", %{}, language: "sql")

    :ok =
      Arcadic.command!(scoped, "INSERT INTO _arcadic_migrations SET version = 1", %{},
        language: "sql"
      )

    assert {:ok, [{1, :up}, {2, :down}]} = Migrator.status(scoped, Registry)
    assert {:ok, 1} = Migrator.migrate(scoped, Registry)

    # A hand-forged down_started marker (a down that died before the DELETE) refuses the
    # next rollback AND migrate, until resolved :applied (the migration is still applied).
    Arcadic.command!(
      scoped,
      "UPDATE _arcadic_migrations SET status = 'down_started' WHERE version = 1",
      %{},
      language: "sql"
    )

    assert {:error, %Arcadic.Error{reason: :interrupted_migration}} =
             Migrator.rollback(scoped, Registry)

    assert :ok = Migrator.resolve(scoped, 1, :applied)
    assert {:ok, [{1, :up}, {2, :up}]} = Migrator.status(scoped, Registry)
  end

  # An UNLINKED process runs the killer migration (a linked Task would take the TEST
  # process down with it); the monitor must observe exactly :killed — any other exit
  # reason means the crash simulation itself is broken and the test is vacuous.
  defp kill_during_migrate(conn, registry) do
    pid = spawn(fn -> Migrator.migrate(conn, registry) end)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:ok, :killed}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("killer migration exited #{inspect(reason)} instead of :killed")
    after
      30_000 -> flunk("killer migration task did not die")
    end
  end
end
