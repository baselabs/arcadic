defmodule Arcadic.MaterializedViewTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, MaterializedView}

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

  describe "create/3" do
    test "emits CREATE MATERIALIZED VIEW name AS select_sql" do
      capture()
      assert :ok = MaterializedView.create(conn(), "mv1", "SELECT FROM Person")
      assert_received {:body, %{"command" => cmd, "language" => "sql"}}
      assert cmd == "CREATE MATERIALIZED VIEW mv1 AS SELECT FROM Person"
    end

    test "a single-quoted string literal in the SELECT passes through verbatim" do
      capture()
      select_sql = "SELECT FROM T WHERE n = 'a'"
      assert :ok = MaterializedView.create(conn(), "mv1", select_sql)
      assert_received {:body, %{"command" => cmd}}
      assert cmd == "CREATE MATERIALIZED VIEW mv1 AS SELECT FROM T WHERE n = 'a'"
    end

    test "a bad name returns invalid_identifier value-free (no wire call)" do
      capture()

      assert {:error, :invalid_identifier} =
               MaterializedView.create(conn(), "1bad", "SELECT FROM Person")

      refute_received {:body, _}
    end

    test "a non-binary select_sql raises ArgumentError value-free (no wire call, no echo)" do
      capture()

      err =
        assert_raise ArgumentError, fn ->
          MaterializedView.create(conn(), "mv1", 123)
        end

      refute Exception.message(err) =~ "123"

      err2 =
        assert_raise ArgumentError, fn ->
          MaterializedView.create(conn(), "mv1", nil)
        end

      refute Exception.message(err2) =~ "nil"

      refute_received {:body, _}
    end
  end

  describe "drop/2" do
    test "emits DROP MATERIALIZED VIEW name with NO IF EXISTS" do
      capture()
      assert :ok = MaterializedView.drop(conn(), "mv1")
      assert_received {:body, %{"command" => cmd, "language" => "sql"}}
      assert cmd == "DROP MATERIALIZED VIEW mv1"
      refute cmd =~ "IF EXISTS"
    end

    test "a bad name returns invalid_identifier value-free (no wire call)" do
      capture()
      assert {:error, :invalid_identifier} = MaterializedView.drop(conn(), "1bad")
      refute_received {:body, _}
    end
  end

  describe "bang variants" do
    test "create! returns :ok on success" do
      capture()
      assert :ok = MaterializedView.create!(conn(), "mv1", "SELECT FROM Person")
    end

    test "drop! returns :ok on success" do
      capture()
      assert :ok = MaterializedView.drop!(conn(), "mv1")
    end

    test "create! raises ArgumentError on a client reject (value-free)" do
      err =
        assert_raise ArgumentError, fn ->
          MaterializedView.create!(conn(), "1bad", "SELECT FROM Person")
        end

      assert err.message =~ "invalid_identifier"
    end

    test "create! raises Arcadic.Error on a server error" do
      Req.Test.stub(__MODULE__, fn c ->
        c
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{
          "error" => "boom",
          "exception" => "com.arcadedb.query.CommandException"
        })
      end)

      assert_raise Arcadic.Error, fn ->
        MaterializedView.create!(conn(), "mv1", "SELECT FROM Person")
      end
    end

    test "drop! raises Arcadic.Error on a server error" do
      Req.Test.stub(__MODULE__, fn c ->
        c
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{
          "error" => "boom",
          "exception" => "com.arcadedb.query.CommandException"
        })
      end)

      assert_raise Arcadic.Error, fn ->
        MaterializedView.drop!(conn(), "mv1")
      end
    end
  end
end
