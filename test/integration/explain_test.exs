defmodule Arcadic.Integration.ExplainTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Conn, Error, Server}

  setup_all do
    url = System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL")
    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    admin = Conn.new(url, "arcadic_explain_it", auth: {"root", pass})
    _ = Server.drop_database(admin, "arcadic_explain_it")
    :ok = Server.create_database!(admin, "arcadic_explain_it")
    Arcadic.command!(admin, "CREATE VERTEX TYPE Person", %{}, language: "sql")
    Arcadic.command!(admin, "INSERT INTO Person SET name = :n", %{"n" => "Ann"}, language: "sql")
    on_exit(fn -> Server.drop_database(admin, "arcadic_explain_it") end)
    {:ok, conn: admin}
  end

  test "SQL explain returns a plan string + tree, no rows", %{conn: conn} do
    assert {:ok, %{plan: plan, plan_tree: tree, rows: []}} =
             Arcadic.explain(conn, "SELECT FROM Person", %{}, language: "sql")

    assert plan =~ "FETCH FROM TYPE Person"
    assert is_map(tree) and map_size(tree) > 0
  end

  test "Cypher explain works", %{conn: conn} do
    assert {:ok, %{plan: plan}} = Arcadic.explain(conn, "MATCH (n:Person) RETURN n")
    assert plan =~ "OpenCypher"
  end

  test "PROFILE EXECUTES a write (mutates) — routed, warned, proven", %{conn: conn} do
    {:ok, [%{"c" => before}]} =
      Arcadic.query(conn, "SELECT count(*) AS c FROM Person", %{}, language: "sql")

    assert {:ok, %{plan: p}} =
             Arcadic.profile(conn, "INSERT INTO Person SET name = :n", %{"n" => "ProfGhost"},
               language: "sql"
             )

    assert p =~ "SAVE"

    {:ok, [%{"c" => after_}]} =
      Arcadic.query(conn, "SELECT count(*) AS c FROM Person", %{}, language: "sql")

    assert after_ == before + 1
  end

  test "Cypher PROFILE returns the executed rows in :rows", %{conn: conn} do
    assert {:ok, %{rows: rows}} = Arcadic.profile(conn, "MATCH (n:Person) RETURN n LIMIT 1")
    assert rows != []
  end

  test "query/4 on a bare EXPLAIN surfaces :use_explain (not silent {:ok, []})", %{conn: conn} do
    assert {:error, %Error{reason: :use_explain}} =
             Arcadic.query(conn, "EXPLAIN SELECT FROM Person", %{}, language: "sql")
  end
end
