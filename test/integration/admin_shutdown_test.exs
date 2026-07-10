defmodule Arcadic.Integration.AdminShutdownTest do
  use ExUnit.Case, async: false
  @moduletag :integration_shutdown
  alias Arcadic.{Conn, Server}

  # A DEDICATED throwaway-container URL — NEVER ARCADIC_TEST_URL (which points at the shared,
  # protected qor-arcadedb). Run: docker run --rm -p 2481:2480 -e \
  # JAVA_OPTS="-Darcadedb.server.rootPassword=throwaway" arcadedata/arcadedb:latest, then
  # ARCADIC_SHUTDOWN_TEST_URL=http://127.0.0.1:2481 ARCADIC_SHUTDOWN_TEST_PASSWORD=throwaway \
  # mix test test/integration/admin_shutdown_test.exs --only integration_shutdown
  test "shutdown/1 halts a throwaway server (success surfaces as :ok OR a transport-closed error)" do
    url =
      System.get_env("ARCADIC_SHUTDOWN_TEST_URL") ||
        flunk("set ARCADIC_SHUTDOWN_TEST_URL to a THROWAWAY container (never the shared server)")

    pass =
      System.get_env("ARCADIC_SHUTDOWN_TEST_PASSWORD") ||
        flunk("set ARCADIC_SHUTDOWN_TEST_PASSWORD")

    # Value-free hard guard: refuse to run if pointed at the shared substrate. A no-op when
    # ARCADIC_TEST_URL is unset (nil never equals the non-nil url) — code beats the comment.
    if url == System.get_env("ARCADIC_TEST_URL"),
      do:
        flunk(
          "ARCADIC_SHUTDOWN_TEST_URL must NOT equal the shared ARCADIC_TEST_URL — this test HALTS the server; point it at a throwaway container"
        )

    conn = Conn.new(url, "any", auth: {"root", pass})
    assert {:ok, true} = Server.health?(conn)
    result = Server.shutdown(conn)

    # Documented contract: :ok (server acked first) OR {:error, transport-closed} (died mid-response).
    assert result == :ok or match?({:error, %Arcadic.TransportError{}}, result)
    # And the server is now down (health fails). Bind once — a second round-trip could race an
    # async shutdown transition and see {:ok, true} then false → spurious false-or-false.
    health = Server.health?(conn)
    assert match?({:error, _}, health) or match?({:ok, false}, health)
  end
end
