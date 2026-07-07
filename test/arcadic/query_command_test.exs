defmodule Arcadic.QueryCommandTest do
  use ExUnit.Case, async: true
  alias Arcadic.Conn

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  test "query/2 hits /query and returns normalized rows" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:path, c.request_path})
      Req.Test.json(c, %{"result" => [%{"n" => 1, "@props" => "n:3"}]})
    end)

    assert {:ok, [%{"n" => 1}]} = Arcadic.query(conn(), "MATCH (n) RETURN n")
    assert_received {:path, "/api/v1/query/mydb"}
  end

  test "command/2 hits /command" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:path, c.request_path})
      Req.Test.json(c, %{"result" => []})
    end)

    assert {:ok, []} = Arcadic.command(conn(), "CREATE (n)")
    assert_received {:path, "/api/v1/command/mydb"}
  end

  test "language defaults to cypher and is overridable" do
    Req.Test.stub(__MODULE__, fn c ->
      raw = Req.Test.raw_body(c)
      send(self(), {:lang, Jason.decode!(raw)["language"]})
      Req.Test.json(c, %{"result" => []})
    end)

    Arcadic.query(conn(), "SELECT 1")
    assert_received {:lang, "cypher"}
    Arcadic.query(conn(), "SELECT 1", %{}, language: "sql")
    assert_received {:lang, "sql"}
  end

  test "params pass through untouched" do
    Req.Test.stub(__MODULE__, fn c ->
      raw = Req.Test.raw_body(c)
      send(self(), {:params, Jason.decode!(raw)["params"]})
      Req.Test.json(c, %{"result" => []})
    end)

    Arcadic.command(conn(), "CREATE (n {k:$k})", %{"k" => "v"})
    assert_received {:params, %{"k" => "v"}}
  end

  test "an unknown option raises ArgumentError" do
    assert_raise ArgumentError, ~r/unknown option/, fn ->
      Arcadic.query(conn(), "RETURN 1", %{}, bogus: true)
    end
  end

  test "an unknown :language value still raises after the opt-key guard runs first" do
    # validate_opts!/2 delegates the key-shape guard to Arcadic.Opts then validates the
    # :language VALUE — this pins that reordering did not drop language validation.
    assert_raise ArgumentError, ~r/unknown language/, fn ->
      Arcadic.query(conn(), "RETURN 1", %{}, language: "boguslang")
    end
  end

  test "rejects non-keyword opts value-free — never echoes the offending entry (Rule 3)" do
    for bad <- [[:SENTINEL_SECRET_9f3a], [{"SENTINEL_9f3a", 1}], %{language: "cypher"}] do
      for call <- [
            fn -> Arcadic.query(conn(), "RETURN 1", %{}, bad) end,
            fn -> Arcadic.command(conn(), "RETURN 1", %{}, bad) end
          ] do
        err = assert_raise ArgumentError, call
        assert err.message == "opts must be a keyword list"
        refute err.message =~ "SENTINEL"
      end
    end
  end

  test "rejects non-map params value-free — never echoes the offending value (Rule 3)" do
    # A caller passing a keyword list for params (a natural mistake — opts IS a keyword list) must
    # NOT reach build_body's `map_size/1` and raise a BadMapError echoing the value into the message.
    for call <- [
          fn ->
            Arcadic.query(conn(), "SELECT FROM V", [{"api_token", "SENTINEL_SECRET_9f3a"}])
          end,
          fn -> Arcadic.command(conn(), "CREATE (n)", [{"api_token", "SENTINEL_SECRET_9f3a"}]) end
        ] do
      err = assert_raise ArgumentError, call
      assert err.message =~ "params"
      refute err.message =~ "SENTINEL"
    end
  end

  test "query!/command! return the list or raise" do
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => [%{"n" => 1}]}) end)
    assert [%{"n" => 1}] = Arcadic.query!(conn(), "RETURN 1")

    Req.Test.stub(__MODULE__, fn c ->
      c
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{
        "error" => "boom",
        "exception" => "com.arcadedb.exception.CommandParsingException"
      })
    end)

    assert_raise Arcadic.Error, fn -> Arcadic.command!(conn(), "MATCHX") end
  end

  test "emits an :arcadic :query span" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :query, :stop]])
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => [%{"n" => 1}]}) end)
    Arcadic.query(conn(), "RETURN 1")
    assert_received {[:arcadic, :query, :stop], ^ref, _m, meta}
    assert meta.mode == :read
    refute Map.has_key?(meta, :database)
    # query spans do NOT carry in_transaction? (spec §10 lists it for command only)
    refute Map.has_key?(meta, :in_transaction?)
    :telemetry.detach(ref)
  end

  test "a command span inside a session is flagged in_transaction?: true (spec §10)" do
    # Pinning `in_transaction?: true` makes the selective receive immune to cross-talk
    # from concurrent standalone commands (which emit `in_transaction?: false`).
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :command, :stop]])
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => []}) end)
    tx = %{conn() | session_id: "AS-1"}
    Arcadic.command(tx, "CREATE (n)")
    assert_received {[:arcadic, :command, :stop], ^ref, _m, %{in_transaction?: true}}
    :telemetry.detach(ref)
  end
end
