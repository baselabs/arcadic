defmodule Arcadic.OptionalTransportsTest do
  use ExUnit.Case, async: true

  # Each optional transport's tests compile only where the transport does; this keeps those
  # gates from passing vacuously, on a host with the dependency and on one without it.
  @transports [
    grpc: [Arcadic.Transport.Grpc, Arcadic.Transport.Grpc.ChannelPool],
    db_connection: [Arcadic.Transport.Bolt, Arcadic.Transport.Bolt.Connection]
  ]

  for {dep, modules} <- @transports do
    test "the #{dep} transport is available exactly when the optional dependency is declared" do
      declared? = Enum.any?(Mix.Project.config()[:deps], &(elem(&1, 0) == unquote(dep)))

      for module <- unquote(modules) do
        assert Code.ensure_loaded?(module) == declared?, inspect(module)
      end
    end
  end
end
