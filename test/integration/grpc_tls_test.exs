defmodule Arcadic.Integration.GrpcTlsTest do
  @moduledoc """
  Live fail-closed proofs for `grpcs://` (the gRPC transport's TLS path) against a TLS-enabled
  ArcadeDB gRPC plugin. Substrate recipe (throwaway):

      test/support/tls/gen-grpc-certs.sh            # trusted CA + server(SAN: localhost,
                                                    # 127.0.0.1, ::1) + a DISJOINT untrusted CA
      docker run -d --name arcadic-grpc-tls-probe -p 50252:50051 \
        -v /tmp/arcadic-grpc-tls:/certs:ro \
        -e JAVA_OPTS="-Darcadedb.server.rootPassword=<pw> \
          -Dio.grpc.netty.shaded.io.netty.handler.ssl.noOpenSsl=true \
          -Darcadedb.server.plugins=GRPC:com.arcadedb.server.grpc.GrpcServerPlugin \
          -Darcadedb.grpc.enabled=true -Darcadedb.grpc.port=50051 \
          -Darcadedb.grpc.tls.enabled=true \
          -Darcadedb.grpc.tls.cert=/certs/server.crt -Darcadedb.grpc.tls.key=/certs/server.key \
          -Darcadedb.server.defaultDatabases=probe[root]" arcadedata/arcadedb:latest

  The `noOpenSsl` flag works around netty-tcnative's ARM64 LSE-atomics crash in current images
  (TLS then runs on JDK SSL). Run with `ARCADIC_GRPC_TLS_TEST_URL=grpcs://localhost:50252`,
  `ARCADIC_GRPC_TLS_TEST_CACERT=<trusted ca.crt>`,
  `ARCADIC_GRPC_TLS_TEST_UNTRUSTED_CACERT=<untrusted.crt>`, `ARCADIC_GRPC_TLS_TEST_PASSWORD=<pw>`.

  The tripwire pair: a trusted CA (passed as `transport_options: [cacertfile: …]`) connects and
  executes; an UNTRUSTED CA — and the bare OS trust store against a private-CA server — must
  FAIL the handshake. `verify: :verify_peer` is hardcoded in the transport's credential; these
  tests exist so a silent downgrade to `verify_none` can never land green.
  """
  use ExUnit.Case, async: false
  @moduletag :integration_grpc_tls

  alias Arcadic.Conn
  alias Arcadic.Transport.Grpc

  setup_all do
    url =
      System.get_env("ARCADIC_GRPC_TLS_TEST_URL") ||
        flunk("set ARCADIC_GRPC_TLS_TEST_URL (grpcs://host:port)")

    ca =
      System.get_env("ARCADIC_GRPC_TLS_TEST_CACERT") ||
        flunk("set ARCADIC_GRPC_TLS_TEST_CACERT (the server's CA, PEM)")

    bad_ca =
      System.get_env("ARCADIC_GRPC_TLS_TEST_UNTRUSTED_CACERT") ||
        flunk("set ARCADIC_GRPC_TLS_TEST_UNTRUSTED_CACERT (a DISJOINT CA — must be rejected)")

    pass =
      System.get_env("ARCADIC_GRPC_TLS_TEST_PASSWORD") ||
        flunk("set ARCADIC_GRPC_TLS_TEST_PASSWORD")

    %{url: url, ca: ca, bad_ca: bad_ca, pass: pass}
  end

  test "grpcs:// with the server's CA (transport_options cacertfile) executes commands", %{
    url: url,
    ca: ca,
    pass: pass
  } do
    conn =
      Conn.new(url, "probe",
        transport: Grpc,
        auth: {"root", pass},
        transport_options: [cacertfile: ca]
      )

    assert {:ok, _rows} =
             Grpc.execute(conn, :read, %{statement: "SELECT 1", params: %{}, language: "sql"}, [])

    assert {:ok, true} = Grpc.ready?(conn)
  end

  test "grpcs:// with an UNTRUSTED CA fails closed (handshake rejected, value-free)", %{
    url: url,
    bad_ca: bad_ca,
    pass: pass
  } do
    conn =
      Conn.new(url, "probe",
        transport: Grpc,
        auth: {"root", pass},
        transport_options: [cacertfile: bad_ca]
      )

    assert {:error, %Arcadic.TransportError{}} =
             Grpc.execute(conn, :read, %{statement: "SELECT 1", params: %{}, language: "sql"}, [])
  end

  test "grpcs:// with the default OS trust store fails closed against a private CA", %{
    url: url,
    pass: pass
  } do
    conn = Conn.new(url, "probe", transport: Grpc, auth: {"root", pass})

    assert {:error, %Arcadic.TransportError{}} =
             Grpc.execute(conn, :read, %{statement: "SELECT 1", params: %{}, language: "sql"}, [])
  end
end
