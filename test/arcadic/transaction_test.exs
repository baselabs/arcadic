defmodule Arcadic.TransactionTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Transaction}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  # A stub that: returns a session id on begin, records the body+headers of every
  # call, and 204s on commit/rollback.
  defp tx_stub do
    Req.Test.stub(__MODULE__, fn c ->
      raw = Req.Test.raw_body(c)

      send(
        self(),
        {:call, c.request_path, raw, Plug.Conn.get_req_header(c, "arcadedb-session-id")}
      )

      cond do
        String.contains?(c.request_path, "/begin/") ->
          c
          |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-tx1")
          |> Plug.Conn.send_resp(204, "")

        String.contains?(c.request_path, "/commit/") or
            String.contains?(c.request_path, "/rollback/") ->
          Plug.Conn.send_resp(c, 204, "")

        true ->
          Req.Test.json(c, %{"result" => [%{"ok" => true}]})
      end
    end)
  end

  test "begin sends NO body and the session header is echoed on every subsequent call incl. commit" do
    tx_stub()

    assert {:ok, [%{"ok" => true}]} =
             Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end)

    assert_received {:call, "/api/v1/begin/mydb", begin_body, _}
    assert begin_body == ""

    assert_received {:call, "/api/v1/command/mydb", _cmd_body, ["AS-tx1"]}
    assert_received {:call, "/api/v1/commit/mydb", _commit_body, ["AS-tx1"]}
  end

  test "isolation: sends an explicit isolationLevel body" do
    tx_stub()

    Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
      isolation: :repeatable_read
    )

    assert_received {:call, "/api/v1/begin/mydb", begin_body, _}
    assert Jason.decode!(begin_body) == %{"isolationLevel" => "REPEATABLE_READ"}
  end

  test "reraises on an exception in the fun (and rolls back)" do
    tx_stub()

    assert_raise RuntimeError, "boom", fn ->
      Arcadic.transaction(conn(), fn _tx -> raise "boom" end)
    end

    assert_received {:call, "/api/v1/begin/mydb", _, _}
    assert_received {:call, "/api/v1/rollback/mydb", _, ["AS-tx1"]}
  end

  test "rollback/2 returns {:error, reason} without raising" do
    tx_stub()

    assert {:error, :nope} =
             Arcadic.transaction(conn(), fn tx -> Arcadic.rollback(tx, :nope) end)

    assert_received {:call, "/api/v1/rollback/mydb", _, ["AS-tx1"]}
  end

  test "a nested transaction raises ArgumentError" do
    tx_stub()

    assert_raise ArgumentError, ~r/nested/, fn ->
      Arcadic.transaction(conn(), fn tx ->
        Arcadic.transaction(tx, fn _inner -> :never end)
      end)
    end
  end

  test "emits an :arcadic :transaction span with a value-free reason (no db name)" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :transaction, :stop]])
    tx_stub()
    Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end)
    assert_received {[:arcadic, :transaction, :stop], ^ref, _m, meta}
    assert meta.reason == :commit
    refute Map.has_key?(meta, :database)
    :telemetry.detach(ref)
  end

  test "unknown isolation raises a clean ArgumentError (not FunctionClauseError)" do
    tx_stub()

    assert_raise ArgumentError, ~r/unknown isolation/, fn ->
      Arcadic.transaction(conn(), fn _tx -> :ok end, isolation: :bogus)
    end
  end

  test "manual begin/2 returns a session-scoped conn" do
    tx_stub()
    assert {:ok, %Conn{session_id: "AS-tx1"}} = Transaction.begin(conn())
  end

  test "manual commit/1 with no active session returns an error without a network call" do
    assert {:error, %Arcadic.Error{reason: :transaction_error}} = Transaction.commit(conn())
  end

  test "manual rollback/1 with no active session is a no-op :ok" do
    assert :ok = Transaction.rollback(conn())
  end

  test "a non-rollback throw in the fun rolls back and re-propagates the throw" do
    tx_stub()

    assert catch_throw(Arcadic.transaction(conn(), fn _tx -> throw(:custom) end)) == :custom

    assert_received {:call, "/api/v1/begin/mydb", _, _}
    assert_received {:call, "/api/v1/rollback/mydb", _, ["AS-tx1"]}
  end

  test "an exit in the fun rolls back and re-propagates the exit" do
    tx_stub()

    assert catch_exit(Arcadic.transaction(conn(), fn _tx -> exit(:boom) end)) == :boom

    assert_received {:call, "/api/v1/begin/mydb", _, _}
    assert_received {:call, "/api/v1/rollback/mydb", _, ["AS-tx1"]}
  end

  test "manual begin/2 on a conn already in a session returns an error without a network call" do
    # No stub set — the nested-session guard must short-circuit before any request.
    tx = %{conn() | session_id: "AS-existing"}
    assert {:error, %Arcadic.Error{reason: :transaction_error}} = Transaction.begin(tx)
  end

  describe "managed retry (S10 G13)" do
    # A stub that fails commit with :concurrent_modification for the first N commits, then succeeds.
    defp flaky_commit_stub(fail_commits) do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn c ->
        cond do
          String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/commit/") ->
            commit_reply(c, Agent.get_and_update(counter, &{&1, &1 + 1}) < fail_commits)

          String.contains?(c.request_path, "/rollback/") ->
            Plug.Conn.send_resp(c, 204, "")

          true ->
            Req.Test.json(c, %{"result" => [%{"ok" => true}]})
        end
      end)

      counter
    end

    # A 409 :concurrent_modification body, shared by the commit- and command-flaky stubs.
    defp conflict_409(c) do
      c
      |> Plug.Conn.put_status(409)
      |> Req.Test.json(%{
        "error" => "conflict",
        "exception" => "com.arcadedb.exception.ConcurrentModificationException"
      })
    end

    defp commit_reply(c, true = _fail?), do: conflict_409(c)
    defp commit_reply(c, false = _fail?), do: Plug.Conn.send_resp(c, 204, "")

    test "retry: true re-runs the closure on a commit-phase :concurrent_modification and succeeds" do
      flaky_commit_stub(2)

      assert {:ok, [%{"ok" => true}]} =
               Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
                 retry: [max_attempts: 3, base_backoff_ms: 1, max_backoff_ms: 2]
               )
    end

    test "retry exhaustion returns the last {:error, %Error{reason: :concurrent_modification}}" do
      flaky_commit_stub(5)

      assert {:error, %Arcadic.Error{reason: :concurrent_modification}} =
               Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
                 retry: [max_attempts: 2, base_backoff_ms: 1, max_backoff_ms: 2]
               )
    end

    test "default (no :retry) does NOT retry — a commit conflict returns immediately" do
      counter = flaky_commit_stub(5)

      assert {:error, %Arcadic.Error{reason: :concurrent_modification}} =
               Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end)

      # commit ran exactly once — proves no retry on the default path (RED if retry became the default)
      assert Agent.get(counter, & &1) == 1
    end

    test "a non-retriable commit error (:parse_error) is NOT retried" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn c ->
        cond do
          String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/commit/") ->
            Agent.update(counter, &(&1 + 1))

            c
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"error" => "x", "exception" => "com.x.CommandParsingException"})

          true ->
            Req.Test.json(c, %{"result" => []})
        end
      end)

      assert {:error, %Arcadic.Error{reason: :parse_error}} =
               Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
                 retry: [max_attempts: 3, base_backoff_ms: 1]
               )

      assert Agent.get(counter, & &1) == 1
    end

    test "emits [:arcadic, :transaction, :retry] with attempt + reason on each retry" do
      flaky_commit_stub(2)
      ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :transaction, :retry]])

      Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
        retry: [max_attempts: 3, base_backoff_ms: 1]
      )

      assert_received {[:arcadic, :transaction, :retry], ^ref, %{attempt: 1},
                       %{reason: :concurrent_modification}}

      assert_received {[:arcadic, :transaction, :retry], ^ref, %{attempt: 2},
                       %{reason: :concurrent_modification}}
    end

    test "an invalid :retry opt is rejected value-free" do
      assert_raise ArgumentError, ~r/retry/, fn ->
        Arcadic.transaction(conn(), fn _ -> :ok end, retry: :sometimes)
      end
    end

    test "non-integer / non-positive :retry inner values are rejected value-free (no unbounded loop)" do
      # A non-integer max_attempts defeats the `attempt < max_attempts` loop bound (Elixir term
      # ordering: 1 < "3" is true) → unbounded retry on a persistent fault. A float backoff crashes
      # :rand.uniform. Reject the SHAPE value-free at parse time (before any HTTP), never echo the value.
      bad_opts = [
        [max_attempts: "3"],
        [max_attempts: 0],
        [max_attempts: 1.5],
        [base_backoff_ms: 5.0],
        [max_backoff_ms: -1]
      ]

      for bad <- bad_opts do
        e =
          assert_raise ArgumentError, fn ->
            Arcadic.transaction(conn(), fn _ -> :ok end, retry: bad)
          end

        assert Exception.message(e) =~ "positive integer"
        # value-free: no offending value ("3"/"5"/"1") echoed
        refute Exception.message(e) =~ ~r/\d/
      end
    end

    test "a commit-phase :timeout is post-commit-ambiguous → NOT retried, returned once (D3)" do
      {:ok, commits} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn c ->
        cond do
          String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/commit/") ->
            Agent.update(commits, &(&1 + 1))

            c
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => "t", "exception" => "com.arcadedb.exception.TimeoutException"})

          true ->
            Req.Test.json(c, %{"result" => [%{"ok" => true}]})
        end
      end)

      assert {:error, %Arcadic.Error{reason: :timeout}} =
               Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
                 retry: [max_attempts: 3, base_backoff_ms: 1, max_backoff_ms: 2]
               )

      # commit called EXACTLY ONCE: a commit-phase :timeout is NOT in @retriable_commit
      # (post-commit-ambiguous — the coordinator may have applied then timed out reporting →
      # replay could double-apply a non-idempotent write). RED if :timeout is added to that set.
      assert Agent.get(commits, & &1) == 1
    end

    test "a commit-phase :not_leader IS retried and succeeds (D3/D15 in the tx path)" do
      {:ok, commits} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn c ->
        cond do
          String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/commit/") ->
            n = Agent.get_and_update(commits, &{&1, &1 + 1})

            if n < 2 do
              c
              |> Plug.Conn.put_status(400)
              |> Req.Test.json(%{
                "error" => "x",
                "exception" => "com.arcadedb.network.binary.ServerIsNotTheLeaderException"
              })
            else
              Plug.Conn.send_resp(c, 204, "")
            end

          true ->
            Req.Test.json(c, %{"result" => [%{"ok" => true}]})
        end
      end)

      assert {:ok, [%{"ok" => true}]} =
               Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
                 retry: [max_attempts: 5, base_backoff_ms: 1, max_backoff_ms: 2]
               )

      # 2 :not_leader commit rejections + 1 success — RED if :not_leader removed from @retriable_commit.
      assert Agent.get(commits, & &1) == 3
    end

    test "a RAISED pre-commit :not_leader (command! rejection) IS retried and succeeds (D3/D4)" do
      {:ok, cmds} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn c ->
        cond do
          String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/command/") ->
            n = Agent.get_and_update(cmds, &{&1, &1 + 1})

            if n < 2 do
              c
              |> Plug.Conn.put_status(400)
              |> Req.Test.json(%{
                "error" => "x",
                "exception" => "com.arcadedb.network.binary.ServerIsNotTheLeaderException"
              })
            else
              Req.Test.json(c, %{"result" => [%{"ok" => true}]})
            end

          String.contains?(c.request_path, "/commit/") or
              String.contains?(c.request_path, "/rollback/") ->
            Plug.Conn.send_resp(c, 204, "")

          true ->
            Req.Test.json(c, %{"result" => []})
        end
      end)

      assert {:ok, [%{"ok" => true}]} =
               Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
                 retry: [max_attempts: 5, base_backoff_ms: 1, max_backoff_ms: 2]
               )

      # command! raised :not_leader twice (pre-commit, rolled back) then succeeded —
      # RED if :not_leader removed from @retriable_precommit.
      assert Agent.get(cmds, & &1) == 3
    end

    # --- The RAISED pre-commit arm (the D3 fix). flaky_command_stub fails the /command/ so
    # command! RAISES inside the closure (rolled back = pre-commit). Counts /command/ calls.
    defp flaky_command_stub(fail_cmds) do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn c ->
        cond do
          String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/command/") ->
            command_reply(c, Agent.get_and_update(counter, &{&1, &1 + 1}) < fail_cmds)

          String.contains?(c.request_path, "/commit/") or
              String.contains?(c.request_path, "/rollback/") ->
            Plug.Conn.send_resp(c, 204, "")

          true ->
            Req.Test.json(c, %{"result" => []})
        end
      end)

      counter
    end

    defp command_reply(c, true = _fail?), do: conflict_409(c)
    defp command_reply(c, false = _fail?), do: Req.Test.json(c, %{"result" => [%{"ok" => true}]})

    test "a RAISED pre-commit :concurrent_modification (command! in the closure) is retried and succeeds" do
      counter = flaky_command_stub(2)

      assert {:ok, [%{"ok" => true}]} =
               Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
                 retry: [max_attempts: 3, base_backoff_ms: 1, max_backoff_ms: 2]
               )

      assert Agent.get(counter, & &1) == 3
    end

    test "exhaustion of a RAISED retriable error RE-RAISES (not converted to {:error}); command ran max_attempts×" do
      counter = flaky_command_stub(5)

      assert_raise Arcadic.Error, fn ->
        Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
          retry: [max_attempts: 2, base_backoff_ms: 1, max_backoff_ms: 2]
        )
      end

      assert Agent.get(counter, & &1) == 2
    end

    test "a RAISED non-retriable error (:parse_error) propagates immediately under :retry — command ran once" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn c ->
        cond do
          String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/command/") ->
            Agent.update(counter, &(&1 + 1))

            c
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"error" => "x", "exception" => "com.x.CommandParsingException"})

          String.contains?(c.request_path, "/rollback/") ->
            Plug.Conn.send_resp(c, 204, "")

          true ->
            Req.Test.json(c, %{"result" => []})
        end
      end)

      assert_raise Arcadic.Error, fn ->
        Arcadic.transaction(conn(), fn tx -> Arcadic.command!(tx, "CREATE (n)") end,
          retry: [max_attempts: 3, base_backoff_ms: 1]
        )
      end

      assert Agent.get(counter, & &1) == 1
    end

    test "an intentional rollback/2 under :retry returns {:error, reason} once, never retried (D7)" do
      {:ok, begins} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn c ->
        cond do
          String.contains?(c.request_path, "/begin/") ->
            Agent.update(begins, &(&1 + 1))

            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/rollback/") ->
            Plug.Conn.send_resp(c, 204, "")

          true ->
            Req.Test.json(c, %{"result" => []})
        end
      end)

      assert {:error, :abort} =
               Arcadic.transaction(conn(), fn tx -> Transaction.rollback(tx, :abort) end,
                 retry: [max_attempts: 3, base_backoff_ms: 1]
               )

      assert Agent.get(begins, & &1) == 1
    end

    test "rollback/2 with a retriable %Error{} reason is terminal under :retry — never retried (D7)" do
      {:ok, begins} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn c ->
        cond do
          String.contains?(c.request_path, "/begin/") ->
            Agent.update(begins, &(&1 + 1))

            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/rollback/") ->
            Plug.Conn.send_resp(c, 204, "")

          true ->
            Req.Test.json(c, %{"result" => []})
        end
      end)

      # A DELIBERATE abort whose reason happens to be a retriable %Error{} must still be terminal —
      # not confused with a commit/begin-phase server fault (D7: the abort reason is caller-chosen,
      # never retried).
      err = %Arcadic.Error{reason: :concurrent_modification, message: "conflict"}

      assert {:error, %Arcadic.Error{reason: :concurrent_modification}} =
               Arcadic.transaction(conn(), fn tx -> Transaction.rollback(tx, err) end,
                 retry: [max_attempts: 3, base_backoff_ms: 1]
               )

      # begin ran EXACTLY ONCE — RED before the fix (the abort's %Error{} matched @retriable_commit
      # and re-ran begin max_attempts times).
      assert Agent.get(begins, & &1) == 1
    end

    test "tx begin fails over to the next host on a pre-send connect error and pins the session to it" do
      Req.Test.stub(__MODULE__, fn c ->
        cond do
          c.host == "h1.invalid" ->
            Req.Test.transport_error(c, :econnrefused)

          String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/commit/") ->
            Plug.Conn.send_resp(c, 204, "")

          true ->
            Req.Test.json(c, %{"result" => [%{"host" => c.host}]})
        end
      end)

      conn =
        Conn.new("http://h1.invalid", "db",
          auth: {"root", "x"},
          hosts: ["http://h2.invalid"],
          transport_options: [plug: {Req.Test, __MODULE__}]
        )

      # h1 refuses begin (pre-send) → pin to h2; the in-tx command runs against h2
      assert {:ok, [%{"host" => "h2.invalid"}]} =
               Arcadic.transaction(conn, fn tx ->
                 Arcadic.command!(tx, "SELECT 1", %{}, language: "sql")
               end)
    end

    test "tx begin returns a TransportError when all hosts refuse the connection" do
      Req.Test.stub(__MODULE__.AllRefuse, fn c -> Req.Test.transport_error(c, :econnrefused) end)

      conn =
        Conn.new("http://h1.invalid", "db",
          auth: {"root", "x"},
          hosts: ["http://h2.invalid"],
          transport_options: [plug: {Req.Test, __MODULE__.AllRefuse}]
        )

      assert {:error, %Arcadic.TransportError{reason: :econnrefused}} =
               Arcadic.transaction(conn, fn _ -> :ok end)
    end

    test "tx begin fails over to the next host on a :not_leader begin rejection and pins to it" do
      Req.Test.stub(__MODULE__.NotLeaderBegin, fn c ->
        cond do
          c.host == "h1.invalid" and String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{
              "error" => "Cannot execute command",
              "exception" => "com.arcadedb.network.binary.ServerIsNotTheLeaderException"
            })

          String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-1")
            |> Plug.Conn.send_resp(204, "")

          String.contains?(c.request_path, "/commit/") ->
            Plug.Conn.send_resp(c, 204, "")

          true ->
            Req.Test.json(c, %{"result" => [%{"host" => c.host}]})
        end
      end)

      conn =
        Conn.new("http://h1.invalid", "db",
          auth: {"root", "x"},
          hosts: ["http://h2.invalid"],
          transport_options: [plug: {Req.Test, __MODULE__.NotLeaderBegin}]
        )

      # h1 begin rejects with :not_leader (unambiguous 400, no session created) → safe to
      # fail over; pin to h2 and run the in-tx command there (D15/D16: begin iterates until it
      # succeeds; a :not_leader rejection is "safe for both modes").
      assert {:ok, [%{"host" => "h2.invalid"}]} =
               Arcadic.transaction(conn, fn tx ->
                 Arcadic.command!(tx, "SELECT 1", %{}, language: "sql")
               end)
    end

    test "tx begin does NOT fail over on a non-rejection begin error (e.g. :parse_error) — returns it" do
      Req.Test.stub(__MODULE__.BadBegin, fn c ->
        cond do
          c.host == "h1.invalid" and String.contains?(c.request_path, "/begin/") ->
            c
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"error" => "x", "exception" => "com.x.CommandParsingException"})

          true ->
            Req.Test.json(c, %{"result" => [%{"host" => c.host}]})
        end
      end)

      conn =
        Conn.new("http://h1.invalid", "db",
          auth: {"root", "x"},
          hosts: ["http://h2.invalid"],
          transport_options: [plug: {Req.Test, __MODULE__.BadBegin}]
        )

      # A begin that fails with a non-connection, non-:not_leader error is surfaced (h2 untried):
      # failing over would mask a genuine begin fault.
      assert {:error, %Arcadic.Error{reason: :parse_error}} =
               Arcadic.transaction(conn, fn _ -> :ok end)
    end
  end
end
