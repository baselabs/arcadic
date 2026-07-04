defmodule Arcadic.Integration.BoltStreamTest do
  use ExUnit.Case, async: false
  @moduletag :integration_bolt
  alias Arcadic.{Conn, Server, Transport.Bolt}

  setup_all do
    host = System.get_env("ARCADIC_BOLT_HOST") || flunk("set ARCADIC_BOLT_HOST")
    bolt_port = String.to_integer(System.get_env("ARCADIC_BOLT_PORT") || "7687")
    http_port = String.to_integer(System.get_env("ARCADIC_BOLT_HTTP_PORT") || "2480")
    pass = System.get_env("ARCADIC_BOLT_PASSWORD") || flunk("set ARCADIC_BOLT_PASSWORD")

    # Per-run randomized DB name so a mispointed ARCADIC_BOLT_HOST cannot collide with
    # (and drop) real data; the suite stays self-contained and idempotent.
    db = "arcadic_stream_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    admin = Conn.new("http://#{host}:#{http_port}", db, auth: {"root", pass})
    _ = Server.drop_database(admin, db)
    :ok = Server.create_database(admin, db)

    {:ok, _} =
      Arcadic.command(admin, "UNWIND range(1,7) AS i CREATE (n:Row {i:i}) RETURN count(n)")

    {:ok, topts} = Bolt.setup(hostname: host, port: bolt_port, username: "root", password: pass)

    conn =
      Conn.new("http://#{host}:#{http_port}", db,
        auth: {"root", pass},
        transport: Bolt,
        transport_options: topts
      )

    on_exit(fn -> Server.drop_database(admin, db) end)

    {:ok,
     conn: conn,
     admin: admin,
     host: host,
     bolt_port: bolt_port,
     http_port: http_port,
     pass: pass,
     db: db}
  end

  test "streams a large result in ordered chunks with a small chunk_size", %{conn: conn} do
    {:ok, stream} =
      Arcadic.query_stream(conn, "MATCH (n:Row) RETURN n.i AS i ORDER BY n.i", %{}, chunk_size: 2)

    assert Enum.map(Enum.to_list(stream), & &1["i"]) == [1, 2, 3, 4, 5, 6, 7]
  end

  test "an empty result streams nothing and closes cleanly", %{conn: conn} do
    {:ok, stream} = Arcadic.query_stream(conn, "MATCH (n:Row) WHERE n.i > 999 RETURN n.i AS i")
    assert Enum.to_list(stream) == []
  end

  test "with_database/2 selects the streamed database", %{conn: conn, db: db} do
    derived = Arcadic.with_database(conn, db)
    {:ok, stream} = Arcadic.query_stream(derived, "MATCH (n:Row) RETURN count(n) AS c")
    assert [%{"c" => 7}] = Enum.to_list(stream)
  end

  test "params bind over the stream (params-only)", %{conn: conn} do
    {:ok, stream} = Arcadic.query_stream(conn, "RETURN $x AS x", %{x: "echo"})
    assert [%{"x" => "echo"}] = Enum.to_list(stream)
  end

  test "an early Enum.take closes the connection (resource safety)", %{conn: conn} do
    {:ok, stream} =
      Arcadic.query_stream(conn, "MATCH (n:Row) RETURN n.i AS i ORDER BY n.i", %{}, chunk_size: 2)

    ref =
      :telemetry_test.attach_event_handlers(self(), [[:arcadic, :query_stream, :stop]])

    try do
      assert length(Enum.take(stream, 3)) == 3

      # Observe teardown-on-early-halt: the stop event fired with reason: :halted, proving
      # the after-fun (stream_stop) ran on early halt rather than merely being inferred.
      assert_received {[:arcadic, :query_stream, :stop], ^ref, %{row_count: _},
                       %{reason: :halted}}
    after
      :telemetry.detach(ref)
    end

    {:ok, again} = Arcadic.query_stream(conn, "MATCH (n:Row) RETURN n.i AS i")
    assert length(Enum.to_list(again)) == 7
  end

  test "a malformed statement raises a typed error mid-stream", %{conn: conn} do
    {:ok, stream} = Arcadic.query_stream(conn, "MATCH (n:Row) RETURN nonexistent_fn(n)")
    assert_raise Arcadic.Error, fn -> Enum.to_list(stream) end
  end

  test "a 0ms per-pull timeout raises TransportError{reason: :timeout}", %{conn: conn} do
    {:ok, stream} = Arcadic.query_stream(conn, "MATCH (n:Row) RETURN n.i AS i", %{}, timeout: 0)
    err = assert_raise Arcadic.TransportError, fn -> Enum.to_list(stream) end
    assert err.reason == :timeout
  end

  test "a stream to an unreachable endpoint raises a typed (redacted) error, not a MatchError",
       %{host: host, http_port: http_port, pass: pass, db: db} do
    # A closed Bolt port → Boltx.Connection.connect returns {:error, _}; the stream must
    # surface a typed Arcadic error (redacted), never a raw MatchError.
    bad_opts = Bolt.resolve_opts(hostname: host, port: 65_535, username: "root", password: pass)

    conn =
      Conn.new("http://#{host}:#{http_port}", db,
        auth: {"root", pass},
        transport: Bolt,
        transport_options: [bolt_opts: bad_opts]
      )

    {:ok, stream} = Arcadic.query_stream(conn, "RETURN 1 AS x")
    err = assert_raise Arcadic.TransportError, fn -> Enum.to_list(stream) end
    # Redaction: no host/password bytes leak into the raised error. Assert on booleans
    # (not `=~ pass`) so a regression does not echo the live credential into ExUnit output.
    rendered = inspect(err)
    refute String.contains?(rendered, host), "host leaked into the raised transport error"
    refute String.contains?(rendered, pass), "password leaked into the raised transport error"
  end

  test "a stream to an OPEN non-Bolt endpoint (the HTTP port) raises a typed error, not a raw exception",
       %{host: host, http_port: http_port, pass: pass, db: db} do
    # Point Bolt at the HTTP port: TCP connects, but the handshake reply is non-Bolt
    # bytes, so boltx's decode_version/1 (single binary clause) FunctionClauseErrors
    # inside Boltx.Connection.connect. arcadic must convert that raise to a typed
    # (redacted) TransportError — never let the raw exception escape.
    bad_opts =
      Bolt.resolve_opts(
        hostname: host,
        port: http_port,
        username: "root",
        password: pass,
        connect_timeout: 2_000
      )

    conn =
      Conn.new("http://#{host}:#{http_port}", db,
        auth: {"root", pass},
        transport: Bolt,
        transport_options: [bolt_opts: bad_opts]
      )

    {:ok, stream} = Arcadic.query_stream(conn, "RETURN 1 AS x")
    err = assert_raise Arcadic.TransportError, fn -> Enum.to_list(stream) end
    refute String.contains?(inspect(err), pass), "password leaked into the raised transport error"
  end

  # tcp_inet ports owned by THIS test process — the enumerator owns the stream's
  # client socket, so a connect leak shows here as a surviving port.
  defp own_tcp_count do
    me = self()

    Enum.count(Port.list(), fn p ->
      Port.info(p, :name) == {:name, ~c"tcp_inet"} and
        Port.info(p, :connected) == {:connected, me}
    end)
  end

  test "a bad-password stream connect leaks no fd and surfaces :unauthorized (redacted)",
       %{host: host, bolt_port: bolt_port, http_port: http_port, pass: pass, db: db} do
    bad =
      Bolt.resolve_opts(
        hostname: host,
        port: bolt_port,
        username: "root",
        password: "WRONG_#{pass}"
      )

    conn =
      Conn.new("http://#{host}:#{http_port}", db,
        auth: {"root", pass},
        transport: Bolt,
        transport_options: [bolt_opts: bad]
      )

    before = own_tcp_count()
    {:ok, stream} = Arcadic.query_stream(conn, "RETURN 1 AS x")
    err = assert_raise Arcadic.Error, fn -> Enum.to_list(stream) end
    assert err.reason == :unauthorized
    assert own_tcp_count() - before == 0
    refute String.contains?(inspect(err), pass), "password leaked into the raised error"
  end

  test "an http-port stream connect leaks no fd (redacted typed error)",
       %{host: host, http_port: http_port, pass: pass, db: db} do
    bad =
      Bolt.resolve_opts(
        hostname: host,
        port: http_port,
        username: "root",
        password: pass,
        connect_timeout: 2_000
      )

    conn =
      Conn.new("http://#{host}:#{http_port}", db,
        auth: {"root", pass},
        transport: Bolt,
        transport_options: [bolt_opts: bad]
      )

    before = own_tcp_count()
    {:ok, stream} = Arcadic.query_stream(conn, "RETURN 1 AS x")
    assert_raise Arcadic.TransportError, fn -> Enum.to_list(stream) end
    assert own_tcp_count() - before == 0
  end
end
