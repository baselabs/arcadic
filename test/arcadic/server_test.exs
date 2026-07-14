defmodule Arcadic.ServerTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Server}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  test "create_database validates the identifier BEFORE any request" do
    # No stub set — if a request were made, it would fail loudly. Validation must short-circuit.
    assert {:error, :invalid_identifier} = Server.create_database(conn(), "bad; drop database x")
  end

  test "create_database sends a server command for a valid name" do
    Req.Test.stub(__MODULE__, fn c ->
      raw = Req.Test.raw_body(c)
      send(self(), {:cmd, c.request_path, Jason.decode!(raw)})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert :ok = Server.create_database(conn(), "newdb")
    assert_received {:cmd, "/api/v1/server", %{"command" => "create database newdb"}}
  end

  test "database_exists? returns a tagged tuple, not a bare boolean" do
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => ["mydb", "other"]}) end)
    assert {:ok, true} = Server.database_exists?(conn(), "mydb")
    assert {:ok, false} = Server.database_exists?(conn(), "absent")
  end

  test "list_databases parses the result list" do
    Req.Test.stub(__MODULE__, fn c ->
      Req.Test.json(c, %{"result" => ["commercegraph", "mydb"]})
    end)

    assert {:ok, ["commercegraph", "mydb"]} = Server.list_databases(conn())
  end

  test "database_info over HTTP normalizes the schema:database row (records/classes nil)" do
    Req.Test.stub(__MODULE__, fn c ->
      Req.Test.json(c, %{
        "result" => [%{"name" => "mydb", "size" => 4096, "mode" => "READ_WRITE"}]
      })
    end)

    assert {:ok, info} = Server.database_info(conn())
    assert info == %{database: "mydb", type: nil, records: nil, classes: nil, size_bytes: 4096}
  end

  test "ready? returns {:ok, true} on 204 and {:error, _} on transport failure" do
    Req.Test.stub(__MODULE__, fn c -> Plug.Conn.send_resp(c, 204, "") end)
    assert {:ok, true} = Server.ready?(conn())

    Req.Test.stub(__MODULE__, fn c -> Req.Test.transport_error(c, :econnrefused) end)
    assert {:error, %Arcadic.TransportError{reason: :econnrefused}} = Server.ready?(conn())
  end

  test "drop_database validates the identifier BEFORE any request" do
    # No stub — a fired request would error loudly; validation must short-circuit.
    assert {:error, :invalid_identifier} = Server.drop_database(conn(), "x; drop database y")
  end

  test "drop_database sends a drop server command for a valid name" do
    Req.Test.stub(__MODULE__, fn c ->
      raw = Req.Test.raw_body(c)
      send(self(), {:cmd, c.request_path, Jason.decode!(raw)})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert :ok = Server.drop_database(conn(), "olddb")
    assert_received {:cmd, "/api/v1/server", %{"command" => "drop database olddb"}}
  end

  test "create_database! returns :ok on success and raises on a server error" do
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => "ok"}) end)
    assert :ok = Server.create_database!(conn(), "newdb")

    # invalid identifier → bang raises ArgumentError (invalid_identifier is a bare atom, not an exception)
    assert_raise ArgumentError, ~r/invalid_identifier/, fn ->
      Server.create_database!(conn(), "bad; drop database x")
    end
  end

  test "ready? returns {:ok, false} for a non-204 response" do
    Req.Test.stub(__MODULE__, fn c -> Plug.Conn.send_resp(c, 500, "") end)
    assert {:ok, false} = Server.ready?(conn())
  end
end
