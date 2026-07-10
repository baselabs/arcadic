defmodule Arcadic.Integration.CapabilityTest do
  @moduledoc """
  Release capability contract: one live smoke over the public HTTP surface, proving a
  published tarball exposes and can call the whole client contract in a single place —
  readiness, database create/drop/exists?/list, query, command, transaction, migration,
  query_stream, and backup/list/restore. Optional Bolt v4 is proven by the
  `:integration_bolt` suite (`test/integration/bolt_test.exs`).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Backup, Conn, Migrator, Server}

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
  end
end
