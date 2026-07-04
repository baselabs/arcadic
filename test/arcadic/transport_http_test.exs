defmodule Arcadic.Transport.HTTPTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Error, TransportError}
  alias Arcadic.Transport.HTTP

  defp conn(overrides \\ %{}) do
    base =
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "sekret"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

    Map.merge(base, overrides)
  end

  defp req(%Conn{} = c, mode, request, opts \\ []), do: HTTP.execute(c, mode, request, opts)

  defp cypher(stmt, params \\ %{}), do: %{statement: stmt, params: params, language: "cypher"}

  test ":read routes to /api/v1/query/<db>; :write routes to /api/v1/command/<db>" do
    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), {:path, conn.request_path})
      Req.Test.json(conn, %{"result" => []})
    end)

    req(conn(), :read, cypher("MATCH (n) RETURN n"))
    assert_received {:path, "/api/v1/query/mydb"}

    req(conn(), :write, cypher("CREATE (n)"))
    assert_received {:path, "/api/v1/command/mydb"}
  end

  test "builds the body: language default, params only when present, opts passthrough" do
    Req.Test.stub(__MODULE__, fn conn ->
      raw = Req.Test.raw_body(conn)
      send(self(), {:body, Jason.decode!(raw)})
      Req.Test.json(conn, %{"result" => []})
    end)

    req(conn(), :write, cypher("CREATE (n {k:$k})", %{"k" => "v"}),
      limit: 10,
      serializer: "graph",
      retries: 3
    )

    assert_received {:body, body}
    assert body["language"] == "cypher"
    assert body["command"] == "CREATE (n {k:$k})"
    assert body["params"] == %{"k" => "v"}
    assert body["limit"] == 10
    assert body["serializer"] == "graph"
    assert body["retries"] == 3
  end

  test "omits params when empty" do
    Req.Test.stub(__MODULE__, fn conn ->
      raw = Req.Test.raw_body(conn)
      send(self(), {:body, Jason.decode!(raw)})
      Req.Test.json(conn, %{"result" => []})
    end)

    req(conn(), :read, cypher("MATCH (n) RETURN n"))
    assert_received {:body, body}
    refute Map.has_key?(body, "params")
  end

  test "sends basic auth; echoes the session header only when session_id is set" do
    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), {:headers, conn.req_headers})
      Req.Test.json(conn, %{"result" => []})
    end)

    req(conn(), :read, cypher("MATCH (n) RETURN n"))
    assert_received {:headers, h1}
    assert {"authorization", "Basic " <> b64} = List.keyfind(h1, "authorization", 0)
    assert Base.decode64!(b64) == "root:sekret"
    refute List.keyfind(h1, "arcadedb-session-id", 0)

    req(conn(%{session_id: "AS-9"}), :read, cypher("MATCH (n) RETURN n"))
    assert_received {:headers, h2}
    assert {"arcadedb-session-id", "AS-9"} = List.keyfind(h2, "arcadedb-session-id", 0)
  end

  test "normalizes a success body (strips @props)" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"result" => [%{"c" => 1, "@props" => "c:3"}]})
    end)

    assert {:ok, [%{"c" => 1}]} = req(conn(), :read, cypher("RETURN 1 AS c"))
  end

  test "a 2xx with an empty (non-map) body is a no-result success, not a crash" do
    # Req leaves an empty response body as "" — clause 1 of handle_result must not
    # hand a non-map to Result.normalize (FunctionClauseError); it degrades to {:ok, []}.
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
    assert {:ok, []} = req(conn(), :write, cypher("CREATE (n)"))
  end

  test "maps a 500 error body to a typed Arcadic.Error" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{
        "error" => "boom",
        "detail" => "line 1",
        "exception" => "com.arcadedb.exception.CommandParsingException"
      })
    end)

    assert {:error, %Error{reason: :parse_error, http_status: 500}} =
             req(conn(), :write, cypher("MATCHX"))
  end

  test "maps a transport failure to Arcadic.TransportError" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %TransportError{reason: :econnrefused}} =
             req(conn(), :read, cypher("RETURN 1"))
  end
end
