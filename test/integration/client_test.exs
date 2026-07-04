defmodule Arcadic.Integration.ClientTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Conn, Error, Server}

  setup_all do
    url =
      System.get_env("ARCADIC_TEST_URL") ||
        flunk("set ARCADIC_TEST_URL to a live ArcadeDB base url")

    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    admin = Conn.new(url, "arcadic_it", auth: {"root", pass})

    # Fresh database per run (zero-config: no transport_options, so Req's default pool).
    _ = Server.drop_database(admin, "arcadic_it")
    :ok = Server.create_database!(admin, "arcadic_it")
    on_exit(fn -> Server.drop_database(admin, "arcadic_it") end)

    {:ok, conn: admin}
  end

  test "zero-config pool: connect with only auth completes a request", %{conn: conn} do
    assert {:ok, [%{"one" => 1}]} = Arcadic.query(conn, "RETURN 1 AS one")
  end

  test "create → read a node with bound params", %{conn: conn} do
    {:ok, [row]} =
      Arcadic.command(conn, "CREATE (u:User {id:$id, name:$name}) RETURN u", %{
        "id" => "u1",
        "name" => "Jo"
      })

    assert row["@rid"]
    assert row["k"] == nil

    assert {:ok, [%{"n" => "Jo"}]} =
             Arcadic.query(conn, "MATCH (u:User {id:$id}) RETURN u.name AS n", %{"id" => "u1"})
  end

  test "MERGE is idempotent (replay yields one node)", %{conn: conn} do
    for _ <- 1..3, do: Arcadic.command!(conn, "MERGE (u:User {id:$id})", %{"id" => "m1"})

    assert {:ok, [%{"c" => 1}]} =
             Arcadic.query(conn, "MATCH (u:User {id:$id}) RETURN count(u) AS c", %{"id" => "m1"})
  end

  test "/query rejects a non-idempotent statement", %{conn: conn} do
    assert {:error, %Error{reason: :not_idempotent}} = Arcadic.query(conn, "CREATE (n:Nope)")
  end

  test "a read inside a transaction sees the transaction's uncommitted write", %{conn: conn} do
    {:ok, seen} =
      Arcadic.transaction(conn, fn tx ->
        Arcadic.command!(tx, "CREATE (u:TxUser {id:$id})", %{"id" => "tx1"})

        {:ok, [%{"c" => c}]} =
          Arcadic.query(tx, "MATCH (u:TxUser {id:$id}) RETURN count(u) AS c", %{"id" => "tx1"})

        c
      end)

    assert seen == 1
  end

  test "rollback discards the write", %{conn: conn} do
    {:error, :abort} =
      Arcadic.transaction(conn, fn tx ->
        Arcadic.command!(tx, "CREATE (u:RbUser {id:$id})", %{"id" => "rb1"})
        Arcadic.rollback(tx, :abort)
      end)

    assert {:ok, [%{"c" => 0}]} =
             Arcadic.query(conn, "MATCH (u:RbUser {id:$id}) RETURN count(u) AS c", %{
               "id" => "rb1"
             })
  end
end
