defmodule Arcadic.ChangesTest do
  @moduledoc """
  Red-first proofs for `Arcadic.Changes`, arcadic's `/ws` change-events GenServer,
  driven against the real listening `WsEchoServer` (Task 7). Each proof starts a
  fresh ephemeral server plus a `Changes` process and exercises one edge of the
  state machine: deliver, filter, unsubscribe, reconnect+gap marker, overflow
  backpressure, terminal 401, supervisor subscriber-routing, subscriber-conflict,
  and subscriber `:DOWN`.
  """
  use ExUnit.Case, async: false

  alias Arcadic.Changes
  alias Arcadic.Changes.Event

  defp connect(port),
    do: Arcadic.connect("ws://127.0.0.1:#{port}", "testdb", auth: {"root", "root"})

  test "1: delivers a change event to the subscriber" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    :ok = Changes.subscribe(pid, "testdb")
    assert_receive {:ws_echo, "subscribe", %{"database" => "testdb"}}, 1000

    :ok = WsEchoServer.push(port, "create", %{"@rid" => "#1:0", "k" => 1})

    assert_receive {:arcadic_change,
                    %Event{change_type: :create, rid: "#1:0", record: %{"k" => 1}}},
                   500
  end

  test "2: filters change types outside the subscription" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    :ok = Changes.subscribe(pid, "testdb", change_types: [:create])
    assert_receive {:ws_echo, "subscribe", %{"changeTypes" => ["create"]}}, 1000

    :ok = WsEchoServer.push(port, "update", %{"@rid" => "#2:0"})

    refute_receive {:arcadic_change, _}, 200
  end

  test "3: unsubscribe stops delivery" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    :ok = Changes.subscribe(pid, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    :ok = Changes.unsubscribe(pid, "testdb")
    assert_receive {:ws_echo, "unsubscribe", %{"database" => "testdb"}}, 1000

    :ok = WsEchoServer.push(port, "create", %{"@rid" => "#3:0"})

    refute_receive {:arcadic_change, _}, 200
  end

  test "4: reconnects after a drop and delivers a :reconnected gap marker + re-subscribes" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    :ok = Changes.subscribe(pid, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    :ok = WsEchoServer.drop(port)

    assert_receive {:arcadic_change, %Event{change_type: :reconnected, database: "testdb"}}, 2000
    # The controller records a FRESH subscribe after the reconnect.
    assert_receive {:ws_echo, "subscribe", %{"database" => "testdb"}}, 2000
  end

  test "5: overflow drops oldest, emits exactly one marker + a dropped telemetry event, socket stays open" do
    {:ok, port} = WsEchoServer.start(self())
    test = self()
    handler = "changes-dropped-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:arcadic, :changes, :dropped],
      fn _event, measurements, meta, _ -> send(test, {:dropped, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, pid} = Changes.start_link(conn: connect(port), max_buffer: 2)
    :ok = Changes.subscribe(pid, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    # Push 10 identifiable events into a max_buffer:2 queue. "Exactly one overflow
    # marker" relies on the 15ms delivery debounce (@drain_interval) coalescing this
    # localhost burst into a SINGLE drain; the refute_receive 300ms window below
    # comfortably exceeds the @drain_max_wait 150ms cap, so a second drain (which would
    # emit a second marker) is proven not to happen.
    for i <- 1..10, do: WsEchoServer.push(port, "create", %{"@rid" => "#5:#{i}"})

    assert_receive {:arcadic_change, %Event{change_type: :overflow, database: nil}}, 1000
    assert_receive {:dropped, %{count: n}, %{operation: :changes}}, 1000
    assert is_integer(n) and n >= 1
    # Exactly ONE overflow marker for the burst.
    refute_receive {:arcadic_change, %Event{change_type: :overflow}}, 300

    # drop-OLDEST: the surviving buffered events are the NEWEST max_buffer (2), never
    # the oldest. A drop-newest regression would deliver #5:1/#5:2 and fail here.
    assert_receive {:arcadic_change, %Event{change_type: :create, rid: "#5:9"}}, 1000
    assert_receive {:arcadic_change, %Event{change_type: :create, rid: "#5:10"}}, 1000
    refute_receive {:arcadic_change, %Event{rid: "#5:1"}}, 300

    # The socket was never closed to apply backpressure: a later push still arrives.
    assert Process.alive?(pid)
    :ok = WsEchoServer.push(port, "create", %{"@rid" => "#5:post"})
    assert_receive {:arcadic_change, %Event{change_type: :create, rid: "#5:post"}}, 1000
  end

  test "6: a 401 on the reconnect handshake is terminal — unauthorized marker, stop, no spin" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    mref = Process.monitor(pid)
    :ok = Changes.subscribe(pid, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    WsEchoServer.reject_next_handshake(port)
    :ok = WsEchoServer.drop(port)

    assert_receive {:arcadic_change_error, :unauthorized}, 2000
    assert_receive {:DOWN, ^mref, :process, ^pid, :normal}, 2000
    # No spin: no fresh handshake/subscribe after the terminal failure.
    refute_receive {:ws_echo, "subscribe", _}, 500
  end

  test "7: subscriber captured in subscribe/3 routes to the caller, not the supervisor (B3)" do
    {:ok, port} = WsEchoServer.start(self())

    {:ok, sup} =
      Supervisor.start_link(
        [{Changes, conn: connect(port), name: :changes_proof7}],
        strategy: :one_for_one
      )

    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    # subscribe/3 runs in THIS (the test) process → subscriber defaults to the test pid.
    :ok = Changes.subscribe(:changes_proof7, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    :ok = WsEchoServer.push(port, "create", %{"@rid" => "#7:0"})

    # Event reaches THIS pid; a self()-at-init bug would route it to the Changes process.
    assert_receive {:arcadic_change, %Event{rid: "#7:0"}}, 500
  end

  test "8: a conflicting subscriber is rejected value-free (S4)" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    :ok = Changes.subscribe(pid, "testdb")

    other = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(other), do: Process.exit(other, :kill) end)

    err = Changes.subscribe(pid, "otherdb", subscriber: other)

    assert err == {:error, :subscriber_conflict}
    refute inspect(err) =~ inspect(other)
  end

  test "9: the subscriber's :DOWN stops the process (unsubscribe-all, S4)" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    mref = Process.monitor(pid)

    sub = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Changes.subscribe(pid, "testdb", subscriber: sub)

    Process.exit(sub, :kill)

    assert_receive {:DOWN, ^mref, :process, ^pid, :normal}, 2000
  end

  test "10: under a caller's Supervisor a terminal 401 stays dead (transient, not restarted)" do
    {:ok, port} = WsEchoServer.start(self())

    {:ok, sup} =
      Supervisor.start_link(
        [{Changes, conn: connect(port), name: :changes_terminal}],
        strategy: :one_for_one
      )

    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    # subscribe/3 from the test pid → the terminal marker routes back here.
    :ok = Changes.subscribe(:changes_terminal, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    WsEchoServer.reject_next_handshake(port)
    :ok = WsEchoServer.drop(port)

    assert_receive {:arcadic_change_error, :unauthorized}, 2000

    # The child stopped with `{:stop, :normal, _}`. A `restart: :permanent` child would
    # be RESTARTED by the supervisor here (a fresh pid appears — the supervision-level
    # spin proof 6 could not see against a directly-linked pid). `:transient` leaves it
    # dead: `which_children` retains the spec with pid `:undefined`. Wait past the
    # near-immediate restart window before checking.
    Process.sleep(500)

    child = List.keyfind(Supervisor.which_children(sup), Changes, 0)

    assert match?({Changes, :undefined, _type, _mods}, child),
           "the Changes child was restarted after a terminal 401 (expected it dead): #{inspect(child)}"
  end
end
