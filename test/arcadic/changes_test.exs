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

  describe "input validation (value-free, before any connect / GenServer.call)" do
    test "start_link rejects a malformed auth shape value-free (no credential echo)" do
      # `Conn.new` does not strictly validate the auth tuple shape, so a 3-tuple typo constructs;
      # `auth_headers/1` would then FunctionClauseError and blame-echo the credentials (Rule 3).
      conn = Arcadic.connect("ws://127.0.0.1:1", "testdb", auth: {"root", "p3nnyleak", :extra})
      result = Changes.start_link(conn: conn)
      assert result == {:error, :invalid_auth}
      refute inspect(result) =~ "p3nnyleak"
    end

    test "start_link rejects an unknown URL scheme (no silent plaintext downgrade)" do
      conn = Arcadic.connect("htps://127.0.0.1:2480", "testdb", auth: {"u", "p"})
      assert Changes.start_link(conn: conn) == {:error, :invalid_url_scheme}
    end

    test "start_link rejects a non-positive / non-integer max_buffer" do
      conn = Arcadic.connect("ws://127.0.0.1:1", "testdb", auth: {"u", "p"})
      assert Changes.start_link(conn: conn, max_buffer: 0) == {:error, :invalid_max_buffer}
      assert Changes.start_link(conn: conn, max_buffer: -1) == {:error, :invalid_max_buffer}
      assert Changes.start_link(conn: conn, max_buffer: "big") == {:error, :invalid_max_buffer}
    end

    test "subscribe rejects a non-pid subscriber value-free (no value echo)" do
      err =
        assert_raise ArgumentError, fn ->
          Changes.subscribe(self(), "db", subscriber: :s3cret_atom_val)
        end

      refute Exception.message(err) =~ "s3cret_atom_val"
    end

    test "subscribe rejects a non-binary type value-free (no value echo)" do
      err = assert_raise ArgumentError, fn -> Changes.subscribe(self(), "db", type: 9_998_887) end
      refute Exception.message(err) =~ "9998887"
    end

    test "subscribe rejects an unknown opt key (fail-closed filter, not silent-open)" do
      assert_raise ArgumentError, fn ->
        Changes.subscribe(self(), "db", change_type: [:create])
      end
    end

    test "subscribe/unsubscribe with a non-binary database raise a clean ArgumentError (no opt blame-echo)" do
      # A total fallback clause: without it a non-binary database FunctionClauseErrors BEFORE the opt
      # guards, and the blame report echoes the :type/:subscriber opts. The fallback raises a fixed
      # ArgumentError (not FunctionClauseError), so no args are ever blame-formatted.
      assert_raise ArgumentError, "database must be a string", fn ->
        Changes.subscribe(self(), 12_345, type: "s3cret_type_val", subscriber: self())
      end

      assert_raise ArgumentError, "database must be a string", fn ->
        Changes.unsubscribe(self(), 12_345)
      end
    end

    test "start_link rejects a non-positive / non-integer establish_timeout" do
      conn = Arcadic.connect("ws://127.0.0.1:1", "testdb", auth: {"u", "p"})

      assert Changes.start_link(conn: conn, establish_timeout: 0) ==
               {:error, :invalid_establish_timeout}

      assert Changes.start_link(conn: conn, establish_timeout: "x") ==
               {:error, :invalid_establish_timeout}
    end

    test "start_link rejects an unknown opt key (fail-closed, symmetric with subscribe)" do
      # Without the key guard a typo'd `:max_buffer` silently falls back to the default (and the
      # process starts). The guard reports the offending KEY name only, value-free.
      conn = Arcadic.connect("ws://127.0.0.1:1", "testdb", auth: {"u", "p"})
      assert_raise ArgumentError, fn -> Changes.start_link(conn: conn, max_buffr: 5) end
    end

    test "init backstops a DIRECT GenServer.start_link that bypasses the public wrapper" do
      # A bad-scheme conn reaches init via a raw GenServer.start_link (bypassing the public
      # start_link/1, which short-circuits before spawning). The init backstop fails closed with
      # `{:stop, reason}` — no silent plaintext downgrade. Under a link that abnormal stop also
      # signals the linked caller, so we trap exits to observe the returned error.
      conn = Arcadic.connect("htps://127.0.0.1:2480", "testdb", auth: {"u", "p"})
      Process.flag(:trap_exit, true)
      assert GenServer.start_link(Changes, conn: conn) == {:error, :invalid_url_scheme}
    after
      Process.flag(:trap_exit, false)
    end
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

  test "11: a malformed (non-map) record does not crash the process and delivers value-free" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    mref = Process.monitor(pid)
    :ok = Changes.subscribe(pid, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    # A frame whose `record` is NOT a map (protocol violation / hostile frame): `get_in`/Access on
    # a scalar would raise and blame-echo the value (Rule 3). The change signal is still delivered,
    # with a nil record, and the process survives.
    :ok = WsEchoServer.push(port, "create", "s3cr3t_scalar")

    assert_receive {:arcadic_change, %Event{change_type: :create, record: rec, rid: nil}}, 1000
    assert is_nil(rec)
    refute_receive {:DOWN, ^mref, :process, ^pid, _}, 300
    assert Process.alive?(pid)
  end

  test "12: event.type reflects the record's @type on an all-types subscription" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    :ok = Changes.subscribe(pid, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    :ok = WsEchoServer.push(port, "create", %{"@rid" => "#9:0", "@type" => "Person"})

    # No :type filter set, no top-level "type" key in the frame — event.type falls back to the
    # record's own class rather than nil.
    assert_receive {:arcadic_change, %Event{change_type: :create, type: "Person"}}, 1000
  end

  test "13: a 403 on the reconnect handshake is terminal (not reconnect-forever)" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    mref = Process.monitor(pid)
    :ok = Changes.subscribe(pid, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    WsEchoServer.reject_next_handshake(port, 403)
    :ok = WsEchoServer.drop(port)

    assert_receive {:arcadic_change_error, :unauthorized}, 2000
    assert_receive {:DOWN, ^mref, :process, ^pid, :normal}, 2000
    # No spin: a 403 must not follow the wildcard reconnect branch.
    refute_receive {:ws_echo, "subscribe", _}, 500
  end

  test "14: a server error frame surfaces a value-free :subscribe_rejected marker (non-terminal)" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    :ok = Changes.subscribe(pid, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    WsEchoServer.push_error(port, "database 'x' does not exist", "s3cret_detail")

    assert_receive {:arcadic_change_error, :subscribe_rejected}, 1000
    # value-free: the server's error/detail strings are never forwarded to the subscriber.
    refute_received {:arcadic_change_error, "s3cret_detail"}
    # non-terminal: the socket stays open and still delivers changes.
    assert Process.alive?(pid)
    :ok = WsEchoServer.push(port, "create", %{"@rid" => "#14:0"})
    assert_receive {:arcadic_change, %Event{change_type: :create, rid: "#14:0"}}, 1000
  end

  test "15: a stalled upgrade (TCP accepted, no 101) hits the establishment timeout and reconnects" do
    {:ok, port} = WsEchoServer.start(self())

    # The FIRST handshake stalls for 2000ms (WsEchoServer hang mode); a 150ms establish_timeout must
    # break the stall well inside the 1200ms assert window below. The window is BELOW the 2000ms
    # stall on purpose: only the establishment timer can recover in time — the harness's eventual
    # 504 (which would self-heal via the generic non-101 reconnect) lands after the window, so this
    # test goes RED if the establishment timer is removed (gate non-vacuity, verified by tamper).
    WsEchoServer.hang_next_handshake(port)
    {:ok, pid} = Changes.start_link(conn: connect(port), establish_timeout: 150)
    :ok = Changes.subscribe(pid, "testdb")

    # Recovery proof: the deadline fired, the client reconnected, and the SECOND (non-stalling)
    # handshake succeeded → the deferred subscribe frame lands within the window.
    assert_receive {:ws_echo, "subscribe", %{"database" => "testdb"}}, 1200
    assert Process.alive?(pid)
  end

  test "16: buffered pre-gap events are flushed BEFORE the :reconnected marker (deterministic order)" do
    {:ok, port} = WsEchoServer.start(self())
    {:ok, pid} = Changes.start_link(conn: connect(port))
    :ok = Changes.subscribe(pid, "testdb")
    assert_receive {:ws_echo, "subscribe", _}, 1000

    # Buffer an event, then immediately drop the socket (before the 15ms drain fires). Without
    # flush-before-marker the drain races the reconnect and the order is non-deterministic; with it
    # the pre-gap event always precedes the :reconnected marker.
    :ok = WsEchoServer.push(port, "create", %{"@rid" => "#16:0"})
    :ok = WsEchoServer.drop(port)

    order =
      for _ <- 1..2 do
        assert_receive {:arcadic_change, %Event{} = e}, 2000
        e.change_type
      end

    assert order == [:create, :reconnected]
  end
end
