defmodule Arcadic.ReqTestSmokeTest do
  use ExUnit.Case, async: true

  test "Req routes through a Req.Test stub and returns its response + headers" do
    Req.Test.stub(SmokeStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("arcadedb-session-id", "AS-smoke")
      |> Req.Test.json(%{"result" => [%{"ok" => true}]})
    end)

    {:ok, resp} = Req.post("http://stub.invalid/x", json: %{a: 1}, plug: {Req.Test, SmokeStub})

    assert resp.status == 200
    assert resp.body == %{"result" => [%{"ok" => true}]}
    assert List.first(resp.headers["arcadedb-session-id"]) == "AS-smoke"
  end
end
