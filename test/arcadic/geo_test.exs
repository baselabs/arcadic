defmodule Arcadic.GeoTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Geo}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  # Capture the outgoing request body (command + params) for assertions.
  defp capture do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:body, Jason.decode!(Req.Test.raw_body(c))})
      Req.Test.json(c, %{"result" => []})
    end)
  end

  describe "create_index/4" do
    test "emits CREATE INDEX IF NOT EXISTS … GEOSPATIAL (default)" do
      capture()
      assert :ok = Geo.create_index(conn(), "Loc", "coords")
      assert_received {:body, %{"command" => cmd, "language" => "sql"}}
      assert cmd == "CREATE INDEX IF NOT EXISTS ON Loc (coords) GEOSPATIAL"
    end

    test ":if_not_exists false drops the guard" do
      capture()
      assert :ok = Geo.create_index(conn(), "Loc", "coords", if_not_exists: false)
      assert_received {:body, %{"command" => cmd}}
      assert cmd == "CREATE INDEX ON Loc (coords) GEOSPATIAL"
    end

    test "an invalid type/property identifier returns {:error, :invalid_identifier} value-free" do
      assert {:error, :invalid_identifier} = Geo.create_index(conn(), "1Bad", "coords")
      assert {:error, :invalid_identifier} = Geo.create_index(conn(), "Loc", "bad prop")
    end

    test "an unknown opt key is rejected value-free" do
      assert_raise ArgumentError, fn ->
        Geo.create_index(conn(), "Loc", "coords", nope: 1)
      end
    end

    test "create_index! raises on a server error" do
      Req.Test.stub(__MODULE__, fn c ->
        c
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "boom", "exception" => "com.arcadedb.index.IndexException"})
      end)

      assert_raise Arcadic.Error, fn ->
        Geo.create_index!(conn(), "Loc", "coords")
      end
    end
  end

  describe "drop_index/3" do
    test "emits DROP INDEX `T[p]` IF EXISTS" do
      capture()
      assert :ok = Geo.drop_index(conn(), "Loc", "coords")
      assert_received {:body, %{"command" => cmd}}
      assert cmd == "DROP INDEX `Loc[coords]` IF EXISTS"
    end

    test "an invalid identifier returns {:error, :invalid_identifier} value-free" do
      assert {:error, :invalid_identifier} = Geo.drop_index(conn(), "1Bad", "coords")
      assert {:error, :invalid_identifier} = Geo.drop_index(conn(), "Loc", "bad prop")
    end

    test "drop_index! raises on a server error" do
      Req.Test.stub(__MODULE__, fn c ->
        c
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "boom", "exception" => "com.arcadedb.index.IndexException"})
      end)

      assert_raise Arcadic.Error, fn ->
        Geo.drop_index!(conn(), "Loc", "coords")
      end
    end
  end
end
