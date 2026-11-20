defmodule Arcadic.OptionalGrpcTest do
  use ExUnit.Case, async: true

  # The gRPC tests compile only where the transport does; this keeps that gate from passing
  # vacuously on a host that declares the dependency.
  test "the gRPC transport is available exactly when the optional grpc dependency is declared" do
    declared? = Enum.any?(Mix.Project.config()[:deps], &(elem(&1, 0) == :grpc))

    for module <- [Arcadic.Transport.Grpc, Arcadic.Transport.Grpc.ChannelPool] do
      assert Code.ensure_loaded?(module) == declared?, inspect(module)
    end
  end
end
