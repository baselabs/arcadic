defmodule Arcadic.Transport.HTTPAdminTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Error, Transport.HTTP, TransportError}

  defp conn,
    do:
      Conn.new("http://a.invalid", "db",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  test "server_get/2 returns the decoded body map for a 2xx JSON response" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:req, c.method, c.request_path, c.query_string})
      Req.Test.json(c, %{"result" => [%{"name" => "root"}]})
    end)

    assert {:ok, %{"result" => [%{"name" => "root"}]}} =
             HTTP.server_get(conn(), "/api/v1/server/users")

    assert_received {:req, "GET", "/api/v1/server/users", _}
  end

  test "server_get/2 maps a non-2xx JSON response to an Arcadic.Error" do
    Req.Test.stub(__MODULE__, fn c ->
      c |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "forbidden"})
    end)

    assert {:error, %Error{}} = HTTP.server_get(conn(), "/api/v1/server/users")
  end

  test "server_get/2 maps a transport failure to a TransportError" do
    Req.Test.stub(__MODULE__, fn c -> Req.Test.transport_error(c, :econnrefused) end)

    assert {:error, %TransportError{reason: :econnrefused}} =
             HTTP.server_get(conn(), "/api/v1/server/users")
  end

  test "health?/1 maps 204 → true and a non-204 2xx → false" do
    Req.Test.stub(__MODULE__, fn c -> Plug.Conn.send_resp(c, 204, "") end)
    assert {:ok, true} = HTTP.health?(conn())

    Req.Test.stub(__MODULE__, fn c -> Plug.Conn.send_resp(c, 200, "") end)
    assert {:ok, false} = HTTP.health?(conn())
  end

  test "login/1 extracts the token from a 2xx body" do
    Req.Test.stub(__MODULE__, fn c ->
      Req.Test.json(c, %{"token" => "AU-tok", "user" => "root"})
    end)

    assert {:ok, "AU-tok"} = HTTP.login(conn())
  end

  test "login/1 returns an Arcadic.Error when a 2xx body carries no token" do
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"user" => "root"}) end)
    assert {:error, %Error{}} = HTTP.login(conn())
  end

  test "logout/1 returns :ok on 204" do
    Req.Test.stub(__MODULE__, fn c -> Plug.Conn.send_resp(c, 204, "") end)
    assert :ok = HTTP.logout(conn())
  end
end
