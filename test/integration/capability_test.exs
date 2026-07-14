defmodule Arcadic.Integration.CapabilityTest do
  @moduledoc """
  Release capability contract: one live smoke over the public HTTP surface, proving a
  published tarball exposes and can call the whole client contract in a single place —
  readiness, database create/drop/exists?/list, query, command, transaction, migration,
  query_stream, backup/list/restore, and the 0.6.0 HTTP surfaces (managed-retry
  transaction, read-consistency + bookmarked read, and the Function/Geo/Trigger/
  MaterializedView programmability DDL). Optional Bolt v4 is proven by the
  `:integration_bolt` suite (`test/integration/bolt_test.exs`); TimeSeries (needs a
  ≥26.7.2 substrate) by `:integration_ts` and the live `/ws` change feed by
  `:integration_ws`.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Backup, Conn, Function, Geo, MaterializedView, Migrator, Server, Trigger}

  defmodule CapMigration do
    @behaviour Arcadic.Migration
    @impl true
    def version, do: 1
    @impl true
    def up(conn) do
      Arcadic.command!(conn, "CREATE VERTEX TYPE CapNode", %{}, language: "sql")
      :ok
    end

    @impl true
    def down(conn) do
      Arcadic.command!(conn, "DROP TYPE CapNode IF EXISTS", %{}, language: "sql")
      :ok
    end
  end

  defmodule CapRegistry do
    use Arcadic.MigrationRegistry
    migrations([CapMigration])
  end

  setup_all do
    url = System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL")
    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    db = "arcadic_cap_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, db, auth: {"root", pass})
    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)
    {:ok, conn: conn}
  end

  test "the published HTTP capability contract is callable end-to-end", %{conn: conn} do
    # readiness
    assert {:ok, true} = Server.ready?(conn)

    # database lifecycle: create → exists? → list → drop a second throwaway
    tmp = "arcadic_cap_tmp_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    assert :ok = Server.create_database!(conn, tmp)
    assert {:ok, true} = Server.database_exists?(conn, tmp)
    assert {:ok, dbs} = Server.list_databases(conn)
    assert tmp in dbs
    assert :ok = Server.drop_database!(conn, tmp)
    assert {:ok, false} = Server.database_exists?(conn, tmp)

    # migration: apply + status
    assert {:ok, 1} = Migrator.migrate(conn, CapRegistry)
    assert {:ok, [{1, :up}]} = Migrator.status(conn, CapRegistry)

    # command (write) with bound params
    assert {:ok, [%{"n" => "cap"}]} =
             Arcadic.command(conn, "CREATE (v:CapNode {name:$n}) RETURN v.name AS n", %{
               "n" => "cap"
             })

    # query (read) with bound params
    assert {:ok, [%{"c" => 1}]} =
             Arcadic.query(conn, "MATCH (v:CapNode {name:$n}) RETURN count(v) AS c", %{
               "n" => "cap"
             })

    # transaction: a read sees the transaction's own uncommitted write, then commits
    assert {:ok, 1} =
             Arcadic.transaction(conn, fn tx ->
               Arcadic.command!(tx, "CREATE (v:CapNode {name:$n})", %{"n" => "tx"})

               [%{"c" => c}] =
                 Arcadic.query!(tx, "MATCH (v:CapNode {name:$n}) RETURN count(v) AS c", %{
                   "n" => "tx"
                 })

               c
             end)

    # query_stream: SQL WHERE-less keyset drains every committed row (chunk < total)
    assert {:ok, stream} =
             Arcadic.query_stream(conn, "SELECT FROM CapNode", %{},
               language: "sql",
               chunk_size: 1
             )

    assert length(Enum.to_list(stream)) == 2

    # backup + list on the throwaway db
    assert {:ok, %{"result" => "OK", "backupFile" => file}} = Backup.backup(conn)
    assert is_binary(file)
    assert {:ok, %{"backups" => _}} = Backup.list(conn)

    # restore/3 is callable and validates value-free (no wire) on a bad URL
    assert {:error, :invalid_url} = Backup.restore(conn, "ok_name", "file:///a\nDROP")

    # --- 0.6.0 surfaces (HTTP only; TimeSeries → :integration_ts, live Changes → :integration_ws) ---

    # S10 managed-retry transaction: the opt-in :retry path commits the happy path
    assert {:ok, _} =
             Arcadic.transaction(
               conn,
               fn tx ->
                 Arcadic.command!(tx, "CREATE (v:CapNode {name:$n})", %{"n" => "retry"})
               end,
               retry: true
             )

    # S10 read-consistency conn + bookmarked read (single-server: the bookmark stays nil)
    rw = Conn.with_consistency(conn, :read_your_writes)

    assert {:ok, _rows, bm_conn} =
             Arcadic.query_bookmarked(rw, "MATCH (v:CapNode) RETURN count(v) AS c", %{})

    assert bm_conn.read_after == nil

    # S11 programmability DDL on a throwaway type
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE CapSrc", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY CapSrc.wkt STRING", %{}, language: "sql")
    Arcadic.command!(conn, "INSERT INTO CapSrc SET wkt = 'POINT (1 1)'", %{}, language: "sql")

    assert :ok = Geo.create_index(conn, "CapSrc", "wkt")

    caplib = "caplib_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    assert :ok =
             Function.define(conn, "#{caplib}.add", "return a + b",
               params: [:a, :b],
               language: :js
             )

    assert {:ok, [%{"t" => 3}]} =
             Arcadic.query(conn, "SELECT `#{caplib}.add`(:a, :b) AS t", %{"a" => 1, "b" => 2},
               language: "sql"
             )

    assert :ok = Function.delete(conn, "#{caplib}.add")

    cap_tg = "cap_tg_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    assert :ok =
             Trigger.create(conn, cap_tg, "CapSrc",
               timing: :before,
               event: :create,
               execute: {:sql, "return"}
             )

    assert :ok = Trigger.drop(conn, cap_tg)

    cap_mv = "cap_mv_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    assert :ok = MaterializedView.create(conn, cap_mv, "SELECT FROM CapSrc")
    assert :ok = MaterializedView.drop(conn, cap_mv)
  end
end
