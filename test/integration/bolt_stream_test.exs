defmodule Arcadic.Integration.BoltStreamTest do
  use ExUnit.Case, async: false
  @moduletag :integration_bolt
  alias Arcadic.{Conn, Server, Transport.Bolt}

  @db "arcadic_stream_it"

  setup_all do
    host = System.get_env("ARCADIC_BOLT_HOST") || flunk("set ARCADIC_BOLT_HOST")
    bolt_port = String.to_integer(System.get_env("ARCADIC_BOLT_PORT") || "7687")
    http_port = String.to_integer(System.get_env("ARCADIC_BOLT_HTTP_PORT") || "2480")
    pass = System.get_env("ARCADIC_BOLT_PASSWORD") || flunk("set ARCADIC_BOLT_PASSWORD")

    admin = Conn.new("http://#{host}:#{http_port}", @db, auth: {"root", pass})
    _ = Server.drop_database(admin, @db)
    :ok = Server.create_database(admin, @db)

    {:ok, _} =
      Arcadic.command(admin, "UNWIND range(1,7) AS i CREATE (n:Row {i:i}) RETURN count(n)")

    {:ok, topts} = Bolt.setup(hostname: host, port: bolt_port, username: "root", password: pass)

    conn =
      Conn.new("http://#{host}:#{http_port}", @db,
        auth: {"root", pass},
        transport: Bolt,
        transport_options: topts
      )

    on_exit(fn -> Server.drop_database(admin, @db) end)
    {:ok, conn: conn, admin: admin, host: host, http_port: http_port, pass: pass}
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

  test "with_database/2 selects the streamed database", %{conn: conn} do
    derived = Arcadic.with_database(conn, @db)
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
       %{host: host, http_port: http_port, pass: pass} do
    # A closed Bolt port → Boltx.Connection.connect returns {:error, _}; the stream must
    # surface a typed Arcadic error (redacted), never a raw MatchError.
    bad_opts = Bolt.resolve_opts(hostname: host, port: 65_535, username: "root", password: pass)

    conn =
      Conn.new("http://#{host}:#{http_port}", @db,
        auth: {"root", pass},
        transport: Bolt,
        transport_options: [bolt_opts: bad_opts]
      )

    {:ok, stream} = Arcadic.query_stream(conn, "RETURN 1 AS x")
    err = assert_raise Arcadic.TransportError, fn -> Enum.to_list(stream) end
    # Redaction: no host/password bytes leak into the raised error.
    refute inspect(err) =~ host
    refute inspect(err) =~ pass
  end
end
