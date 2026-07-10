defmodule Arcadic.Transport.HTTPBatchTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Transport}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  test "posts raw NDJSON to /api/v1/batch/<db> and returns the parsed counts" do
    Req.Test.stub(__MODULE__, fn c ->
      send(
        self(),
        {:req, c.request_path, Req.Test.raw_body(c), URI.decode_query(c.query_string || ""),
         Plug.Conn.get_req_header(c, "content-type")}
      )

      Req.Test.json(c, %{"verticesCreated" => 2, "edgesCreated" => 1, "elapsedMs" => 7})
    end)

    ndjson = ~s({"@type":"vertex","@class":"P","id":1}\n{"@type":"vertex","@class":"P","id":2}\n)

    assert {:ok, %{"verticesCreated" => 2, "edgesCreated" => 1, "elapsedMs" => 7}} =
             Transport.HTTP.batch_ingest(conn(), ndjson,
               id_property: "id",
               light_edges: false,
               commit_every: 1000
             )

    assert_received {:req, "/api/v1/batch/mydb", ^ndjson, q, ctype}
    assert q["idProperty"] == "id"
    assert q["lightEdges"] == "false"
    assert q["commitEvery"] == "1000"
    assert Enum.any?(ctype, &(&1 =~ "application/x-ndjson"))
  end

  test "a 400 line-error maps to a typed Arcadic.Error (server text quarantined in :detail)" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:qs, c.query_string})

      c
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => "Cannot execute command",
        "detail" => "Edge missing @from or @to at line 4",
        "exception" => "java.lang.IllegalArgumentException"
      })
    end)

    assert {:error, %Arcadic.Error{reason: :server_error, http_status: 400} = err} =
             Transport.HTTP.batch_ingest(conn(), "{}\n", [])

    assert err.detail =~ "line 4"
    refute Exception.message(err) =~ "line 4"

    assert_received {:qs, qs}
    assert qs in [nil, ""]
  end
end
