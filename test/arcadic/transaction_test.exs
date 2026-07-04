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
end
