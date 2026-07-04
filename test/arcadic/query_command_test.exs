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
    :telemetry.detach(ref)
  end
end
