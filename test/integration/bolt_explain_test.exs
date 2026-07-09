defmodule Arcadic.Integration.BoltExplainTest do
  use ExUnit.Case, async: false
  @moduletag :integration_bolt
  alias Arcadic.{Conn, Transport}

  setup_all do
    host = System.get_env("ARCADIC_BOLT_HOST") || flunk("set ARCADIC_BOLT_HOST")
    port = String.to_integer(System.get_env("ARCADIC_BOLT_PORT") || "7687")
    http_port = String.to_integer(System.get_env("ARCADIC_BOLT_HTTP_PORT") || "2480")
    pass = System.get_env("ARCADIC_BOLT_PASSWORD") || flunk("set ARCADIC_BOLT_PASSWORD")

    # Self-contained + per-run randomized DB name (mirrors bolt_test.exs): a mispointed
    # ARCADIC_BOLT_HOST cannot collide with (and drop) real data, and a fresh DB makes the
    # suite idempotent.
    db = "boltexplain_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    admin = Conn.new("http://#{host}:#{http_port}", db, auth: {"root", pass})
    _ = Arcadic.Server.drop_database(admin, db)
    :ok = Arcadic.Server.create_database(admin, db)
    on_exit(fn -> Arcadic.Server.drop_database(admin, db) end)

    # setup/1 (the D2-recommended form) starts the pool AND returns the transport_options
    # ([bolt: pool, bolt_opts: resolved]) in one call, so the pool and per-stream connect opts
    # cannot drift. Returns {:ok, keyword()}.
    {:ok, topts} =
      Transport.Bolt.setup(hostname: host, port: port, username: "root", password: pass)

    conn =
      Conn.new("http://#{host}:#{http_port}", db,
        auth: {"root", pass},
        transport: Transport.Bolt,
        transport_options: topts
      )

    Arcadic.command!(conn, "CREATE (p:Person {name: $n})", %{n: "Ann"})

    {:ok, bolt: conn}
  end

  test "Bolt Cypher explain returns a plan (no rows)", %{bolt: conn} do
    assert {:ok, %{plan: plan, plan_tree: tree, rows: []}} =
             Arcadic.explain(conn, "MATCH (n:Person) RETURN n")

    assert plan =~ "OpenCypher"
    assert is_map(tree) and map_size(tree) > 0
  end

  test "Bolt Cypher profile executes and returns rows + a profile tree", %{bolt: conn} do
    assert {:ok, %{plan: plan, rows: rows}} =
             Arcadic.profile(conn, "MATCH (n:Person) RETURN n LIMIT 1")

    assert plan =~ "Profile"
    assert rows != []
  end
end
