defmodule Arcadic.BoltConnectTest do
  use ExUnit.Case, async: false
  alias Arcadic.Test.BoltFakeServer
  alias Arcadic.Transport.Bolt

  # tcp_inet ports OWNED BY this test process — isolates the arcadic-side client
  # socket from the fake server's listen/accept sockets and from concurrent suites.
  defp own_tcp_ports do
    self = self()

    Enum.count(Port.list(), fn p ->
      Port.info(p, :name) == {:name, ~c"tcp_inet"} and
        Port.info(p, :connected) == {:connected, self}
    end)
  end

  defp opts_for(port),
    do: [
      hostname: "127.0.0.1",
      port: port,
      scheme: "bolt",
      versions: [4.4, 4.3, 4.2, 4.1],
      connect_timeout: 300,
      auth: [username: "root", password: "irrelevant_for_these_paths"]
    ]

  test "path A (version negotiation) returns a typed error and leaks no fd" do
    {:ok, port} = BoltFakeServer.start(:version_negotiation)
    before = own_tcp_ports()
    assert {:error, :version_negotiation_error} = Bolt.leak_safe_connect(opts_for(port))
    assert own_tcp_ports() - before == 0
  end

  test "path B (non-Bolt endpoint) returns a bare-atom error (no server payload) and leaks no fd" do
    {:ok, port} = BoltFakeServer.start(:non_bolt)
    before = own_tcp_ports()
    result = Bolt.leak_safe_connect(opts_for(port))
    assert {:error, reason} = result
    assert reason in [:version_negotiation_error, :bolt_protocol_error]
    # Info-destroying property: the error is a BARE ATOM, structurally incapable of
    # carrying the dropped server bytes. Goes RED if handshake ever returns a reason
    # that embeds server data, e.g. {:error, {:unexpected, server_bytes}}.
    assert is_atom(reason)
    assert own_tcp_ports() - before == 0
  end

  # NOTE: the end-to-end redaction tripwire (a real server FAILURE message that COULD
  # echo a value) is the live path-C test in Task 4 (`refute inspect(err) =~ pass`) —
  # handshake path A/B ingests at most 4 value-free bytes, so there is nothing to leak here.

  test "a stalled server surfaces :timeout within connect_timeout and leaks no fd" do
    {:ok, port} = BoltFakeServer.start(:stall)
    before = own_tcp_ports()
    assert {:error, :timeout} = Bolt.leak_safe_connect(opts_for(port))
    assert own_tcp_ports() - before == 0
  end
end
