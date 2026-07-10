defmodule Arcadic.Integration.AdminTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias Arcadic.{Backup, Conn, Schema, Security, Server}

  setup_all do
    url = System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL")
    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    db = "admin_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, db, auth: {"root", pass})
    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)
    {:ok, conn: conn, url: url, pass: pass, db: db}
  end

  test "Server info/metrics/health/events/settings/check", %{conn: conn} do
    assert {:ok, %{"version" => _}} = Server.info(conn, mode: :basic)
    assert {:ok, %{"profiler" => _}} = Server.metrics(conn)
    assert {:ok, true} = Server.health?(conn)
    assert {:ok, %{"events" => _}} = Server.events(conn)
    assert :ok = Server.set_server_setting(conn, "arcadedb.serverMetrics", "true")
    assert {:ok, %{"operation" => "check database"}} = Server.check_database(conn)
    assert {:ok, %{"totalEntries" => _}} = Schema.dictionary(conn)
  end

  test "align_database is cluster-only (single-server → server error, surfaced not raised)", %{
    conn: conn,
    db: db
  } do
    assert {:error, %Arcadic.Error{}} = Server.align_database(conn, db)
  end

  test "Security: users/sessions/login + create_user stores the EXACT password (Jason round-trip)",
       %{conn: conn, url: url, db: db} do
    assert {:ok, [_ | _]} = Security.users(conn)
    assert {:ok, token} = Security.login(conn)
    assert is_binary(token)
    assert {:ok, _} = Security.sessions(conn)

    uname = "arc_it_u_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    # adversarial password: quote, backtick, backslash, brace, space (>=5 chars)
    pw = ~s(p"a`s\\s}w{o rd9)

    assert :ok =
             Security.create_user!(conn, %{
               name: uname,
               password: pw,
               databases: %{db => ["admin"]}
             })

    on_exit(fn -> Security.drop_user(conn, uname) end)
    # THE PROOF: log in as the new user with the EXACT password → the escaping round-tripped
    user_conn = Conn.new(url, db, auth: {uname, pw})
    assert {:ok, utoken} = Security.login(user_conn)
    assert is_binary(utoken)
    # Bearer flow: with_bearer/2 → a query authenticates
    bearer = Conn.with_bearer(conn, token)
    assert {:ok, _} = Arcadic.query(bearer, "SELECT 1 AS one", %{}, language: "sql")
  end

  test "Backup: backup + list on the throwaway db; restore validates inputs and composes correctly",
       %{conn: conn} do
    assert {:ok, %{"result" => "OK", "backupFile" => file}} = Backup.backup(conn)
    assert is_binary(file)
    assert {:ok, %{"backups" => _}} = Backup.list(conn)

    # restore composition reaches the server (a bad path → structured RestoreException, not a client crash)
    assert {:error, %Arcadic.Error{}} =
             Backup.restore(conn, "arc_restore_probe", "file:///nonexistent-#{file}")

    # value-free validation (no wire): a newline url / bad name
    assert {:error, :invalid_url} = Backup.restore(conn, "ok_name", "file:///a\nDROP")
    assert {:error, :invalid_identifier} = Backup.restore(conn, "bad name", "file:///x.zip")
  end
end
