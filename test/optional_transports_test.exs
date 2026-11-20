defmodule Arcadic.OptionalTransportsTest do
  use ExUnit.Case, async: true

  # Each optional dependency's tests compile only where it is present; this keeps those gates
  # from passing vacuously, on a host with the dependency and on one without it. protobuf is
  # covered through grpc: the gRPC transport compiles only when both are present.
  @gated [
    grpc: [Arcadic.Transport.Grpc, Arcadic.Transport.Grpc.ChannelPool],
    db_connection: [Arcadic.Transport.Bolt, Arcadic.Transport.Bolt.Connection],
    mint_web_socket: [Mint.WebSocket]
  ]

  defp declared?(dep), do: Enum.any?(Mix.Project.config()[:deps], &(elem(&1, 0) == dep))

  for {dep, modules} <- @gated do
    test "#{dep}'s gated modules are available exactly when the dependency is declared" do
      declared? = declared?(unquote(dep))

      for module <- unquote(modules) do
        assert Code.ensure_loaded?(module) == declared?, inspect(module)
      end
    end
  end

  # The absent branch of the runtime gate, defined only on a host without the dependency
  # (the without-optional job), so it never passes without asserting.
  unless Enum.any?(Mix.Project.config()[:deps], &(elem(&1, 0) == :mint_web_socket)) do
    test "change events refuse to start without mint_web_socket" do
      conn = Arcadic.Conn.new("http://localhost:2480", "db", auth: {"u", "p"})

      assert {:error, :mint_web_socket_not_available} =
               Arcadic.Changes.start_link(conn: conn)
    end
  end
end
