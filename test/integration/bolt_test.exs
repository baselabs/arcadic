defmodule Arcadic.Integration.BoltTest do
  @moduledoc """
  Live proofs for the Bolt transport. Substrate recipe (throwaway; probed 2026-08-22 on
  arcadedata/arcadedb:latest 26.9.1-SNAPSHOT — Bolt is NOT enabled by default):

      docker run -d --name arcadic-bolt-probe -p 42483:2480 -p 42484:7687 \\
        -e JAVA_OPTS="-Darcadedb.server.rootPassword=<pw> \\
          -Darcadedb.server.plugins=Bolt:com.arcadedb.bolt.BoltProtocolPlugin" \\
        arcadedata/arcadedb:latest

  Env (this file + bolt_explain/bolt_stream): `ARCADIC_BOLT_HOST` / `ARCADIC_BOLT_PORT` /
  `ARCADIC_BOLT_HTTP_PORT` / `ARCADIC_BOLT_PASSWORD`. The B6 Bolt-streaming describe in
  `streaming_tls_test.exs` reads a SEPARATE family — `ARCADIC_TEST_BOLT_HOST`/`_PORT` (plus
  `ARCADIC_TEST_URL`/`_PASSWORD`) — supply both families to run every `:integration_bolt` test.

  For `:integration_bolt_tls` (bolt.ssl REQUIRED), add to JAVA_OPTS (cert material from
  `test/support/tls/gen-grpc-certs.sh`, which emits server.p12 + truststore.jks):

      -Darcadedb.bolt.ssl=REQUIRED \\
      -Darcadedb.ssl.keyStore=/certs/server.p12 -Darcadedb.ssl.keyStorePassword=<kpw> \\
      -Darcadedb.ssl.trustStore=/certs/truststore.jks -Darcadedb.ssl.trustStorePassword=<kpw>

  (property spellings are the server's own — `arcadedb.ssl.keyStorePassword` in full; the
  plugin fails at startup naming whatever is missing). Env: `ARCADIC_TEST_BOLT_TLS_HOST` /
  `_PORT` / `_CACERT` + `ARCADIC_TEST_URL` / `_PASSWORD`; the `s3_tls_probe` db must exist
  (`-Darcadedb.server.defaultDatabases=s3_tls_probe[root]`).
  """
  use ExUnit.Case, async: false
  @moduletag :integration_bolt
  alias Arcadic.{Conn, Transport}
  alias Arcadic.Transport.Bolt.Connection

  setup_all do
    host = System.get_env("ARCADIC_BOLT_HOST") || flunk("set ARCADIC_BOLT_HOST")
    port = String.to_integer(System.get_env("ARCADIC_BOLT_PORT") || "7687")
    http_port = String.to_integer(System.get_env("ARCADIC_BOLT_HTTP_PORT") || "2480")
    pass = System.get_env("ARCADIC_BOLT_PASSWORD") || flunk("set ARCADIC_BOLT_PASSWORD")

    # Self-contained + per-run randomized DB name: a mispointed ARCADIC_BOLT_HOST cannot
    # collide with (and drop) real data. A fresh DB makes the suite idempotent (BoltTx
    # count is exactly 1) and ensures the DB the Bolt transport targets actually exists.
    db = "boltspike_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    admin = Conn.new("http://#{host}:#{http_port}", db, auth: {"root", pass})
    _ = Arcadic.Server.drop_database(admin, db)
    :ok = Arcadic.Server.create_database(admin, db)
    on_exit(fn -> Arcadic.Server.drop_database(admin, db) end)

    {:ok, bolt} =
      Transport.Bolt.start_link(hostname: host, port: port, username: "root", password: pass)

    conn =
      Conn.new("http://#{host}:#{http_port}", db,
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

  test "pool connect/1 with a bad password leaks no fd and returns :unauthorized" do
    host = System.get_env("ARCADIC_BOLT_HOST")
    port = String.to_integer(System.get_env("ARCADIC_BOLT_PORT") || "7687")
    pass = System.get_env("ARCADIC_BOLT_PASSWORD")

    opts =
      Arcadic.Transport.Bolt.resolve_opts(
        hostname: host,
        port: port,
        username: "root",
        password: "WRONG_#{pass}"
      )

    me = self()

    count = fn ->
      Enum.count(Port.list(), fn p ->
        Port.info(p, :name) == {:name, ~c"tcp_inet"} and
          Port.info(p, :connected) == {:connected, me}
      end)
    end

    before = count.()

    assert {:error, %Boltx.Error{code: :unauthorized} = err} =
             Connection.connect(opts)

    assert count.() - before == 0

    # Redaction (Rule 3): the server FAILURE message must not survive on the returned
    # struct, so it cannot ride DBConnection's connect-failure crash_reason / format_banner
    # log. The error CLASS (bolt.code) is preserved (Rule-3-permitted); the free-text
    # message is stripped. Goes RED against the pre-fix raw passthrough (bolt.message ==
    # "Authentication failed").
    assert err.bolt.code == "Neo.ClientError.Security.Unauthorized"
    assert err.bolt.message == nil
    refute String.contains?(inspect(err), pass)
  end
end
