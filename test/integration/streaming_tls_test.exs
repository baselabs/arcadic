defmodule Arcadic.Integration.StreamingTLSTest do
  use ExUnit.Case, async: false

  alias Arcadic.{Conn, Server, Transport.Bolt}

  defp http_conn do
    url = System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL")
    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    db = "s3_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, db, auth: {"root", pass})
    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)
    conn
  end

  describe "B7 HTTP streaming" do
    @describetag :integration

    test "streams all rows in @rid order, @props/alias-free" do
      conn = http_conn()
      Arcadic.command!(conn, "CREATE DOCUMENT TYPE V", %{}, language: "sql")

      for i <- 1..2500,
          do: Arcadic.command!(conn, "INSERT INTO V SET n = #{i}", %{}, language: "sql")

      assert {:ok, stream} =
               Arcadic.query_stream(conn, "SELECT n FROM V", %{},
                 language: "sql",
                 chunk_size: 500
               )

      rows = Enum.to_list(stream)
      assert length(rows) == 2500
      assert Enum.map(rows, & &1["n"]) == Enum.to_list(1..2500)
      refute Enum.any?(rows, fn r -> Enum.any?(Map.keys(r), &String.starts_with?(&1, "_$$$")) end)
      refute Enum.any?(rows, &Map.has_key?(&1, "@props"))
    end

    test "refuses a self-ordered statement and a non-sql language client-side" do
      conn = http_conn()

      assert {:error, %Arcadic.Error{reason: :not_supported}} =
               Arcadic.query_stream(conn, "SELECT FROM V ORDER BY n", %{}, language: "sql")

      assert {:error, %Arcadic.Error{reason: :not_supported}} =
               Arcadic.query_stream(conn, "MATCH (n) RETURN n", %{}, language: "cypher")
    end
  end

  describe "B6 transaction-scoped Bolt streaming" do
    @describetag :integration_bolt

    setup do
      h = System.get_env("ARCADIC_TEST_BOLT_HOST") || "127.0.0.1"
      p = String.to_integer(System.get_env("ARCADIC_TEST_BOLT_PORT") || "41479")
      url = System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL")
      pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
      db = "s3_bolt_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      admin = Conn.new(url, db, auth: {"root", pass})
      _ = Server.drop_database(admin, db)
      :ok = Server.create_database!(admin, db)
      on_exit(fn -> Server.drop_database(admin, db) end)
      # Vertex type (Bolt reads/writes are Cypher) seeded via HTTP-SQL on the admin conn.
      Arcadic.command!(admin, "CREATE VERTEX TYPE V", %{}, language: "sql")

      for i <- 1..3,
          do: Arcadic.command!(admin, "INSERT INTO V SET n = #{i}", %{}, language: "sql")

      {:ok, topts} = Bolt.setup(hostname: h, port: p, username: "root", password: pass)

      {:ok,
       conn: Conn.new(url, db, auth: {"root", pass}, transport: Bolt, transport_options: topts)}
    end

    test "a tx-scoped stream sees the tx's uncommitted write, then the tx commits cleanly", %{
      conn: conn
    } do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:arcadic, :query_stream, :start],
          [:arcadic, :query_stream, :stop]
        ])

      {:ok, seen} =
        Arcadic.transaction(conn, fn tx ->
          # Cypher write on the Bolt tx client (Bolt speaks Cypher).
          Arcadic.command!(tx, "CREATE (v:V {n: 999})", %{})

          {:ok, stream} =
            Arcadic.query_stream(tx, "MATCH (v:V) RETURN v.n AS n", %{}, chunk_size: 2)

          # the stream runs on the SAME tx client → sees the uncommitted 999
          stream |> Enum.map(& &1["n"]) |> Enum.sort()
        end)

      assert 999 in seen
      # the tx-scoped stream emits the same value-free telemetry pair as the other stream paths
      assert_received {[:arcadic, :query_stream, :start], ^ref, _, %{mode: :read}}
      assert_received {[:arcadic, :query_stream, :stop], ^ref, %{row_count: rc}, %{mode: :read}}
      assert rc == length(seen)
      :telemetry.detach(ref)
      # committed cleanly after the stream fully drained (the cursor-desync guard held: COMMIT ran
      # on a socket with no un-pulled result). The count matches what the tx stream saw.
      assert {:ok, [%{"c" => c}]} = Arcadic.query(conn, "MATCH (v:V) RETURN count(v) AS c")
      assert c == length(seen)
    end

    test "an early-halted tx-scoped stream DISCARD-drains so the tx still commits cleanly", %{
      conn: conn
    } do
      # chunk_size 1 over the 3 seeded rows + Enum.take(1) leaves the cursor OPEN when the Stream
      # halts → handle_deallocate's cursor_open?: true branch must DISCARD the remaining server-side
      # result so the tx's COMMIT does not desync the shared Bolt socket (spec §10; the exercised
      # branch that unit tests can't reach — the guard flag is only true across a real fetch).
      {:ok, taken} =
        Arcadic.transaction(conn, fn tx ->
          {:ok, stream} =
            Arcadic.query_stream(tx, "MATCH (v:V) RETURN v.n AS n", %{}, chunk_size: 1)

          Enum.take(stream, 1)
        end)

      assert length(taken) == 1
      # the tx committed cleanly despite the un-drained cursor (deallocate drained it)
      assert {:ok, [%{"c" => c}]} = Arcadic.query(conn, "MATCH (v:V) RETURN count(v) AS c")
      assert c == 3
    end

    # NOTE: the execute-mid-cursor desync guard (`handle_execute` → :cursor_open) is tested
    # server-free in Task 2 — `DBConnection.stream` deallocates the cursor when the enumeration
    # halts, so it cannot be reliably left open across an execute at the integration level. The
    # unit test exercises the guard directly on a cursor_open? state.
  end

  describe "B8 Bolt over TLS (verify_peer is meaningful — fails closed on an untrusted cert)" do
    @describetag :integration_bolt_tls

    setup do
      %{
        h:
          System.get_env("ARCADIC_TEST_BOLT_TLS_HOST") ||
            flunk("set ARCADIC_TEST_BOLT_TLS_HOST (a bolt.ssl-enabled ArcadeDB)"),
        p:
          String.to_integer(
            System.get_env("ARCADIC_TEST_BOLT_TLS_PORT") ||
              flunk("set ARCADIC_TEST_BOLT_TLS_PORT")
          ),
        ca:
          System.get_env("ARCADIC_TEST_BOLT_TLS_CACERT") ||
            flunk("set ARCADIC_TEST_BOLT_TLS_CACERT (the test server's CA)"),
        url: System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL"),
        pass: System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
      }
    end

    test "verify_peer CONNECTS with the CA trusted", %{h: h, p: p, ca: ca, url: url, pass: pass} do
      {:ok, topts} =
        Bolt.setup(
          scheme: "bolt+s",
          ssl_opts: [cacertfile: ca, server_name_indication: :disable],
          hostname: h,
          port: p,
          username: "root",
          password: pass
        )

      # The "s3_tls_probe" db name is not exercised here: Bolt.ready?/1 runs a db-less `RETURN 1`,
      # so this block needs no create/drop (the db just has to exist, which the substrate ensures).
      conn =
        Conn.new(url, "s3_tls_probe",
          auth: {"root", pass},
          transport: Bolt,
          transport_options: topts
        )

      # arcadic bolt+s → boltx bolt+ssc (verify_peer); CA trusted → the SECURE path succeeds.
      assert {:ok, true} = Bolt.ready?(conn)
    end

    test "verify_peer FAILS CLOSED when the server cert is not trusted (proves verification is real)",
         %{h: h, p: p, url: url, pass: pass} do
      # Same secure scheme, but WITHOUT trusting the server's self-signed CA (only the OS store) →
      # verify_peer must REJECT the cert. A verify_none default would (wrongly) connect here.
      {:ok, topts} =
        Bolt.setup(scheme: "bolt+s", hostname: h, port: p, username: "root", password: pass)

      conn =
        Conn.new(url, "s3_tls_probe",
          auth: {"root", pass},
          transport: Bolt,
          transport_options: topts
        )

      # Assert ready?'s failure CONTRACT (a %TransportError{}), not a fully-open `{:error, _}` — the
      # loose form would ALSO pass on :econnrefused/timeout, which would NOT prove a CERT rejection.
      # (The reason atom is left unpinned: OTP wraps the TLS `unknown_ca` alert as a
      # DBConnection.ConnectionError, which is TLS-stack-version-fragile.)
      assert {:error, %Arcadic.TransportError{}} = Bolt.ready?(conn)
    end
  end
end
