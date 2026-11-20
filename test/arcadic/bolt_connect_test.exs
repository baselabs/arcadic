# The Bolt transport exists only where DBConnection is present;
# the condition is the one lib/arcadic/transport/bolt.ex compiles under.
if Code.ensure_loaded?(DBConnection) do
  defmodule Arcadic.BoltConnectTest do
    use ExUnit.Case, async: false
    alias Arcadic.Test.BoltFakeServer
    alias Arcadic.Transport.Bolt.{Client, Connection}

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
      assert {:error, :version_negotiation_error} = Client.connect(opts_for(port))
      assert own_tcp_ports() - before == 0
    end

    test "path B (non-Bolt endpoint) returns a bare-atom error (no server payload) and leaks no fd" do
      {:ok, port} = BoltFakeServer.start(:non_bolt)
      before = own_tcp_ports()
      result = Client.connect(opts_for(port))
      assert {:error, reason} = result
      assert reason in [:version_negotiation_error, :bolt_protocol_error]
      assert is_atom(reason)
      assert own_tcp_ports() - before == 0
    end

    test "a stalled server surfaces :timeout within connect_timeout and leaks no fd" do
      {:ok, port} = BoltFakeServer.start(:stall)
      before = own_tcp_ports()
      assert {:error, :timeout} = Client.connect(opts_for(port))
      assert own_tcp_ports() - before == 0
    end

    test "a garbled HELLO response returns a redacted bare-atom error (no server bytes) and leaks no fd" do
      {:ok, port} = BoltFakeServer.start(:garbled_hello)
      before = own_tcp_ports()
      result = Client.connect(opts_for(port))
      assert {:error, reason} = result
      assert is_atom(reason)
      assert reason == :bolt_protocol_error
      refute inspect(result) =~ "SERVER_HELLO_SECRET"
      assert own_tcp_ports() - before == 0
    end

    test "a server that stalls AFTER the handshake bounds the HELLO leg by connect_timeout and leaks no fd" do
      {:ok, port} = BoltFakeServer.start(:stall_after_handshake)
      before = own_tcp_ports()

      assert {:error, :timeout} =
               Client.connect(opts_for(port))

      assert own_tcp_ports() - before == 0
    end

    test "pool connect/1 returns a typed exception and leaks no fd on a non-Bolt endpoint" do
      {:ok, port} = BoltFakeServer.start(:non_bolt)
      before = own_tcp_ports()
      result = Connection.connect(opts_for(port))
      assert {:error, %Arcadic.TransportError{reason: reason}} = result
      assert reason in [:version_negotiation_error, :bolt_protocol_error]
      assert own_tcp_ports() - before == 0
    end
  end
end
