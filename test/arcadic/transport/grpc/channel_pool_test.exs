defmodule Arcadic.Transport.Grpc.ChannelPoolTest do
  @moduledoc """
  Unit proofs for the caller-supervised gRPC channel cache — cache/reuse/reconnect logic, with fake
  channel structs (no live server). Liveness keys on the channel's `adapter_payload.conn_pid`. The
  fake channels are intentionally NOT live `GRPC.Channel`s: teardown and stale-replacement
  disconnects must be best-effort (a channel that cannot be disconnected must not abort pool
  shutdown or reconnect — grpc 1.x owns the connection process under its own supervisor).
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

  describe "connect runs OUTSIDE the pool GenServer (a dead endpoint must not queue the world)" do
    test "two concurrent first-connects on DISTINCT endpoints do not serialize" do
      # DISTINCT keys: with the same key the old design also passed (the second checkout
      # reuses the first connect's channel and never sleeps twice) — only distinct
      # endpoints force two real connects, which the old GenServer-serialized design
      # runs back-to-back (2 × 250ms sequential).
      connect = fn key ->
        Process.sleep(250)
        {:ok, %{adapter_payload: %{conn_pid: key}}}
      end

      {elapsed_us, results} =
        :timer.tc(fn ->
          tasks =
            for i <- 1..2 do
              Task.async(fn ->
                ChannelPool.checkout({"h", 8 + i, false}, fn -> connect.({i}) end)
              end)
            end

          Task.await_many(tasks)
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert elapsed_us < 450_000
    end

    test "a slow connect on one endpoint does not block checkout of an already-cached endpoint" do
      ch = live_channel()
      assert {:ok, ^ch} = ChannelPool.checkout({"cached", 1, false}, fn -> {:ok, ch} end)

      slow =
        Task.async(fn ->
          ChannelPool.checkout({"slow", 1, false}, fn ->
            Process.sleep(400)
            {:error, :dead}
          end)
        end)

      Process.sleep(20)

      {elapsed_us, _} =
        :timer.tc(fn ->
          ChannelPool.checkout({"cached", 1, false}, fn ->
            flunk("cached endpoint must not reconnect")
          end)
        end)

      assert {:error, :dead} = Task.await(slow)
      assert elapsed_us < 300_000
    end
  end

  describe "custom :name is rejected (the transport resolves the pool by module name)" do
    test "start_link with a custom :name raises value-free" do
      err = assert_raise ArgumentError, fn -> ChannelPool.start_link(name: MyApp.Pool) end
      assert Exception.message(err) =~ ":name"
    end
  end
end
