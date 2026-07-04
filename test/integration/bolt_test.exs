defmodule Arcadic.Integration.BoltTest do
  use ExUnit.Case, async: false
  @moduletag :integration_bolt
  alias Arcadic.{Conn, Transport}

  setup_all do
    host = System.get_env("ARCADIC_BOLT_HOST") || flunk("set ARCADIC_BOLT_HOST")
    port = String.to_integer(System.get_env("ARCADIC_BOLT_PORT") || "7687")
    pass = System.get_env("ARCADIC_BOLT_PASSWORD") || flunk("set ARCADIC_BOLT_PASSWORD")

    {:ok, bolt} =
      Transport.Bolt.start_link(hostname: host, port: port, username: "root", password: pass)

    conn =
      Conn.new("http://#{host}:2481", "boltspike",
        auth: {"root", pass},
        transport: Transport.Bolt,
        transport_options: [bolt: bolt]
      )

    {:ok, conn: conn}
  end

  test "execute read/write over Bolt with params", %{conn: conn} do
    assert {:ok, [%{"n" => 1}]} = Arcadic.query(conn, "RETURN 1 AS n")

    assert {:ok, [%{"k" => "b1"}]} =
             Arcadic.command(conn, "CREATE (p:BoltProbe {k:$k}) RETURN p.k AS k", %{k: "b1"})
  end

  test "fun-based transaction commits, and Arcadic.rollback/2 discards", %{conn: conn} do
    {:ok, c} =
      Arcadic.transaction(conn, fn tx ->
        Arcadic.command!(tx, "CREATE (p:BoltTx {k:$k})", %{k: "t1"})

        [%{"c" => c}] =
          Arcadic.query!(tx, "MATCH (p:BoltTx {k:$k}) RETURN count(p) AS c", %{k: "t1"})

        c
      end)

    assert c == 1

    assert {:error, :abort} =
             Arcadic.transaction(conn, fn tx ->
               Arcadic.command!(tx, "CREATE (p:BoltRb {k:$k})", %{k: "r1"})
               Arcadic.rollback(tx, :abort)
             end)

    assert {:ok, [%{"c" => 0}]} =
             Arcadic.query(conn, "MATCH (p:BoltRb {k:$k}) RETURN count(p) AS c", %{k: "r1"})
  end

  test "ready? does a RETURN 1 health check", %{conn: conn} do
    assert {:ok, true} = Arcadic.Server.ready?(conn)
  end
end
