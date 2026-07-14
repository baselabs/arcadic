defmodule Arcadic.Transport.Grpc.ChannelPoolTest do
  @moduledoc """
  Unit proofs for the caller-supervised gRPC channel cache — cache/reuse/reconnect logic, with fake
  channel structs (no live server). Liveness keys on the channel's `adapter_payload.conn_pid`.
  """
  use ExUnit.Case, async: false

  alias Arcadic.Transport.Grpc.ChannelPool

  setup do
    {:ok, pid} = ChannelPool.start_link([])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok
  end

  defp live_channel, do: %{adapter_payload: %{conn_pid: self()}}

  test "caches + reuses the same channel for an endpoint (connect_fn runs once)" do
    ch = live_channel()
    counter = :counters.new(1, [])

    connect = fn ->
      :counters.add(counter, 1, 1)
      {:ok, ch}
    end

    assert {:ok, ^ch} = ChannelPool.checkout({"h", 1, false}, connect)
    assert {:ok, ^ch} = ChannelPool.checkout({"h", 1, false}, connect)
    assert :counters.get(counter, 1) == 1
  end

  test "distinct endpoints get distinct channels" do
    a = live_channel()
    b = live_channel()
    assert {:ok, ^a} = ChannelPool.checkout({"h", 1, false}, fn -> {:ok, a} end)
    assert {:ok, ^b} = ChannelPool.checkout({"h", 2, false}, fn -> {:ok, b} end)
  end

  test "reconnects when the cached channel's connection process is dead" do
    dead = spawn(fn -> Process.sleep(:infinity) end)
    ref = Process.monitor(dead)
    Process.exit(dead, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    refute Process.alive?(dead)

    dead_ch = %{adapter_payload: %{conn_pid: dead}}
    live_ch = live_channel()

    # first checkout caches the (now-dead) channel; second sees it dead → reconnects
    assert {:ok, ^dead_ch} = ChannelPool.checkout({"h", 3, false}, fn -> {:ok, dead_ch} end)
    assert {:ok, ^live_ch} = ChannelPool.checkout({"h", 3, false}, fn -> {:ok, live_ch} end)
  end

  test "a connect failure is returned and nothing is cached" do
    assert {:error, :boom} = ChannelPool.checkout({"h", 4, false}, fn -> {:error, :boom} end)
    ch = live_channel()
    assert {:ok, ^ch} = ChannelPool.checkout({"h", 4, false}, fn -> {:ok, ch} end)
  end
end
