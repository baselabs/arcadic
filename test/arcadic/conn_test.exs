defmodule Arcadic.ConnTest do
  use ExUnit.Case, async: true
  alias Arcadic.Conn

  describe "new/3" do
    test "builds a conn with defaults and a trimmed base_url" do
      conn = Conn.new("http://localhost:2480/", "mydb", auth: {"root", "sekret"})
      assert conn.base_url == "http://localhost:2480"
      assert conn.database == "mydb"
      assert conn.auth == {"root", "sekret"}
      assert conn.session_id == nil
      assert conn.transport == Arcadic.Transport.HTTP
      assert conn.transport_options == []
    end

    test "requires auth — raises with a value-free message when missing" do
      err = assert_raise ArgumentError, fn -> Conn.new("http://localhost:2480", "mydb") end
      refute String.contains?(Exception.message(err), "root")
    end

    test "validates the database identifier" do
      assert_raise ArgumentError, fn ->
        Conn.new("http://localhost:2480", "bad.name", auth: {"root", "x"})
      end
    end

    test "carries transport_options and timeout" do
      conn =
        Conn.new("http://localhost:2480", "mydb",
          auth: {"root", "x"},
          transport_options: [finch: MyFinch],
          timeout: 30_000
        )

      assert conn.transport_options == [finch: MyFinch]
      assert conn.timeout == 30_000
    end
  end

  describe "with_database/2" do
    setup do
      %{conn: Conn.new("http://localhost:2480", "db1", auth: {"root", "x"})}
    end

    test "derives a conn on another database and clears the session", %{conn: conn} do
      tx = %{conn | session_id: "AS-123"}
      conn2 = Conn.with_database(tx, "db2")
      assert conn2.database == "db2"
      assert conn2.session_id == nil
    end

    test "validates the new identifier", %{conn: conn} do
      assert_raise ArgumentError, fn -> Conn.with_database(conn, "db 2") end
    end
  end

  describe "Inspect redaction" do
    test "never renders the password or a session id" do
      conn = %{
        Conn.new("http://localhost:2480", "mydb", auth: {"root", "sekret"})
        | session_id: "AS-secret"
      }

      rendered = inspect(conn)
      refute rendered =~ "sekret"
      refute rendered =~ "AS-secret"
      assert rendered =~ "[REDACTED]"
    end
  end
end
