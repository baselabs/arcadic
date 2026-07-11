defmodule Arcadic.TriggerTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Trigger}

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

  describe "create/4" do
    test "emits CREATE TRIGGER with timing, event, type, language and body" do
      capture()

      assert :ok =
               Trigger.create(conn(), "tg", "Person",
                 timing: :before,
                 event: :create,
                 execute: {:javascript, "return true"}
               )

      assert_received {:body, %{"command" => cmd, "language" => "sql"}}
      assert cmd == ~s(CREATE TRIGGER tg BEFORE CREATE ON Person EXECUTE JAVASCRIPT "return true")
    end

    test "each timing atom maps to its token" do
      for {atom, token} <- [before: "BEFORE", after: "AFTER"] do
        capture()

        assert :ok =
                 Trigger.create(conn(), "tg", "Person",
                   timing: atom,
                   event: :create,
                   execute: {:sql, "x"}
                 )

        assert_received {:body, %{"command" => cmd}}
        assert cmd == ~s(CREATE TRIGGER tg #{token} CREATE ON Person EXECUTE SQL "x")
      end
    end

    test "each event atom maps to its token" do
      for {atom, token} <- [create: "CREATE", delete: "DELETE", update: "UPDATE", read: "READ"] do
        capture()

        assert :ok =
                 Trigger.create(conn(), "tg", "Person",
                   timing: :before,
                   event: atom,
                   execute: {:sql, "x"}
                 )

        assert_received {:body, %{"command" => cmd}}
        assert cmd == ~s(CREATE TRIGGER tg BEFORE #{token} ON Person EXECUTE SQL "x")
      end
    end

    test "each execute language atom maps to its token" do
      for {atom, token} <- [sql: "SQL", javascript: "JAVASCRIPT", java: "JAVA"] do
        capture()

        assert :ok =
                 Trigger.create(conn(), "tg", "Person",
                   timing: :before,
                   event: :create,
                   execute: {atom, "return true"}
                 )

        assert_received {:body, %{"command" => cmd}}
        assert cmd == ~s(CREATE TRIGGER tg BEFORE CREATE ON Person EXECUTE #{token} "return true")
      end
    end

    test "an off-enum timing is rejected value-free (no wire call)" do
      capture()

      assert {:error, :invalid_timing} =
               Trigger.create(conn(), "tg", "Person",
                 timing: :sideways,
                 event: :create,
                 execute: {:sql, "x"}
               )

      refute_received {:body, _}
    end

    test "an off-enum event is rejected value-free (no wire call)" do
      capture()

      assert {:error, :invalid_event} =
               Trigger.create(conn(), "tg", "Person",
                 timing: :before,
                 event: :upsert,
                 execute: {:sql, "x"}
               )

      refute_received {:body, _}
    end

    test "an off-enum execute language is rejected value-free (no wire call)" do
      capture()

      assert {:error, :invalid_language} =
               Trigger.create(conn(), "tg", "Person",
                 timing: :before,
                 event: :create,
                 execute: {:ruby, "return true"}
               )

      refute_received {:body, _}
    end

    test "a malformed or missing :execute rejects value-free (no MatchError echo, no wire call)" do
      capture()

      # A non-tuple :execute must not MatchError-echo the caller value (Rule 3).
      assert {:error, :invalid_execute} =
               Trigger.create(conn(), "tg", "Person",
                 timing: :before,
                 event: :create,
                 execute: "SEKRIT-not-a-tuple"
               )

      assert {:error, :invalid_execute} =
               Trigger.create(conn(), "tg", "Person",
                 timing: :before,
                 event: :create,
                 execute: :x
               )

      # A missing :execute rejects the same way.
      assert {:error, :invalid_execute} =
               Trigger.create(conn(), "tg", "Person", timing: :before, event: :create)

      refute_received {:body, _}
    end

    test "a 2-tuple :execute with a non-atom lang rejects value-free (no wire call)" do
      # The `when is_atom(lang_atom)` guard fails on a string lang, so this falls to the total
      # `:invalid_execute` clause — loosening the guard would let it slip through (red-capable).
      capture()

      assert {:error, :invalid_execute} =
               Trigger.create(conn(), "tg", "Person",
                 timing: :before,
                 event: :create,
                 execute: {"javascript", "return true"}
               )

      refute_received {:body, _}
    end

    test "a 3-tuple :execute rejects value-free (no wire call)" do
      # A 3-tuple never matches the 2-tuple `{lang_atom, code}` pattern, so it falls to the total
      # `:invalid_execute` clause — widening the pattern to a 3-tuple would let it slip through.
      capture()

      assert {:error, :invalid_execute} =
               Trigger.create(conn(), "tg", "Person",
                 timing: :before,
                 event: :create,
                 execute: {:javascript, "x", :extra}
               )

      refute_received {:body, _}
    end

    test "a bad name returns invalid_identifier value-free (no wire call)" do
      capture()

      assert {:error, :invalid_identifier} =
               Trigger.create(conn(), "1bad", "Person",
                 timing: :before,
                 event: :create,
                 execute: {:sql, "x"}
               )

      refute_received {:body, _}
    end

    test "a bad type returns invalid_identifier value-free (no wire call)" do
      capture()

      assert {:error, :invalid_identifier} =
               Trigger.create(conn(), "tg", "bad type",
                 timing: :before,
                 event: :create,
                 execute: {:sql, "x"}
               )

      refute_received {:body, _}
    end

    test "a double-quote body is rejected value-free (no wire call)" do
      capture()
      body = ~s(return "SEKRIT-body-value")

      assert {:error, :unencodable_body} =
               Trigger.create(conn(), "tg", "Person",
                 timing: :before,
                 event: :create,
                 execute: {:javascript, body}
               )

      refute_received {:body, _}
    end

    test "a non-binary body raises ArgumentError value-free (does not echo the value)" do
      err =
        assert_raise ArgumentError, fn ->
          Trigger.create(conn(), "tg", "Person",
            timing: :before,
            event: :create,
            execute: {:javascript, 987_654_321}
          )
        end

      refute err.message =~ "987654321"
      refute err.message =~ "987_654_321"
    end

    test "an unknown opt key is rejected value-free" do
      assert_raise ArgumentError, fn ->
        Trigger.create(conn(), "tg", "Person",
          timing: :before,
          event: :create,
          execute: {:sql, "x"},
          nope: 1
        )
      end
    end
  end

  describe "drop/2" do
    test "emits DROP TRIGGER name with NO IF EXISTS" do
      capture()
      assert :ok = Trigger.drop(conn(), "tg")
      assert_received {:body, %{"command" => cmd, "language" => "sql"}}
      assert cmd == "DROP TRIGGER tg"
      refute cmd =~ "IF EXISTS"
    end

    test "a bad name returns invalid_identifier value-free (no wire call)" do
      capture()
      assert {:error, :invalid_identifier} = Trigger.drop(conn(), "1bad")
      refute_received {:body, _}
    end
  end

  describe "bang variants" do
    test "create! returns :ok on success" do
      capture()

      assert :ok =
               Trigger.create!(conn(), "tg", "Person",
                 timing: :before,
                 event: :create,
                 execute: {:sql, "x"}
               )
    end

    test "drop! returns :ok on success" do
      capture()
      assert :ok = Trigger.drop!(conn(), "tg")
    end

    test "create! raises ArgumentError on a client reject (value-free)" do
      err =
        assert_raise ArgumentError, fn ->
          Trigger.create!(conn(), "1bad", "Person",
            timing: :before,
            event: :create,
            execute: {:sql, "x"}
          )
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
        Trigger.create!(conn(), "tg", "Person",
          timing: :before,
          event: :create,
          execute: {:sql, "x"}
        )
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
        Trigger.drop!(conn(), "tg")
      end
    end
  end
end
