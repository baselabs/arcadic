defmodule Arcadic.FunctionTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Function}

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

  describe "define/4" do
    test "emits DEFINE FUNCTION with PARAMETERS and the language token" do
      capture()

      assert :ok =
               Function.define(conn(), "math.sum", "return a + b",
                 params: [:a, :b],
                 language: :js
               )

      assert_received {:body, %{"command" => cmd, "language" => "sql"}}
      assert cmd == ~s(DEFINE FUNCTION math.sum "return a + b" PARAMETERS [a, b] LANGUAGE js)
    end

    test "no params omits PARAMETERS and defaults LANGUAGE js" do
      capture()
      assert :ok = Function.define(conn(), "l.f", "return 1")
      assert_received {:body, %{"command" => cmd}}
      assert cmd == ~s(DEFINE FUNCTION l.f "return 1" LANGUAGE js)
      refute cmd =~ "PARAMETERS"
    end

    test "a bare keyword 4th arg is opts, not params (no positional footgun)" do
      # Under the old `params \\ [], opts \\ []` signature this bound the keyword list to positional
      # `params`, dropped :language, and returned {:error, :invalid_identifier}. Now the 4th arg is
      # opts, so :language is honored and no PARAMETERS clause is emitted.
      capture()
      assert :ok = Function.define(conn(), "no.params", "return 1", language: :sql)
      assert_received {:body, %{"command" => cmd}}
      assert cmd == ~s(DEFINE FUNCTION no.params "return 1" LANGUAGE sql)
      refute cmd =~ "PARAMETERS"
    end

    test "language: :sql maps to the sql token" do
      capture()
      assert :ok = Function.define(conn(), "l.f", "return 1", language: :sql)
      assert_received {:body, %{"command" => cmd}}
      assert cmd == ~s(DEFINE FUNCTION l.f "return 1" LANGUAGE sql)
    end

    test "language: :cypher maps to the cypher token" do
      capture()
      assert :ok = Function.define(conn(), "l.f", "return 1", language: :cypher)
      assert_received {:body, %{"command" => cmd}}
      assert cmd == ~s(DEFINE FUNCTION l.f "return 1" LANGUAGE cypher)
    end

    test "an unknown :language is rejected value-free (no wire call)" do
      capture()

      assert {:error, :invalid_language} =
               Function.define(conn(), "l.f", "return 1", language: :ruby)

      refute_received {:body, _}
    end

    test "each param is Identifier.validate'd — a bad param returns invalid_identifier value-free" do
      capture()

      assert {:error, :invalid_identifier} =
               Function.define(conn(), "l.f", "return 1", params: [:"1x"])

      refute_received {:body, _}
    end

    test "a non-atom/non-binary param rejects value-free (param_name total-fallback)" do
      # No Req.Test stub -> a leaked wire call would fail loudly. Pins the `param_name(_) -> ""`
      # clause: without it, an integer param FunctionClauseErrors and its blame echoes the args
      # (Rule 3), and this returns-not-raises assertion would go red.
      capture()

      assert {:error, :invalid_identifier} =
               Function.define(conn(), "l.f", "return 1", params: [123])

      assert {:error, :invalid_identifier} =
               Function.define(conn(), "l.f", "return 1", params: [{:a, 1}])

      refute_received {:body, _}
    end

    test "an unknown opt key is rejected value-free" do
      assert_raise ArgumentError, fn ->
        Function.define(conn(), "l.f", "return 1", nope: 1)
      end
    end
  end

  describe "name validation (per segment)" do
    test "a degenerate lib..fn (empty middle segment) returns invalid_identifier value-free" do
      capture()
      assert {:error, :invalid_identifier} = Function.define(conn(), "l..f", "return 1")
      refute_received {:body, _}
    end

    test "a bare name with no dot returns invalid_identifier (a function needs library.name)" do
      capture()
      assert {:error, :invalid_identifier} = Function.define(conn(), "nolib", "return 1")
      refute_received {:body, _}
    end

    test "an injection-shaped segment returns invalid_identifier" do
      assert {:error, :invalid_identifier} = Function.define(conn(), "l.f`; DROP", "return 1")
    end
  end

  describe "body guard (DDLBody)" do
    test "a body containing a double-quote is rejected value-free (no wire call)" do
      capture()
      body = ~s(return "SEKRIT-body-value")
      assert {:error, :unencodable_body} = Function.define(conn(), "l.f", body)
      refute_received {:body, _}
    end

    test "a non-binary body raises ArgumentError value-free (does not echo the value)" do
      err =
        assert_raise ArgumentError, fn ->
          Function.define(conn(), "l.f", 987_654_321)
        end

      refute err.message =~ "987654321"
      refute err.message =~ "987_654_321"
    end
  end

  describe "delete/2" do
    test "emits DELETE FUNCTION lib.name" do
      capture()
      assert :ok = Function.delete(conn(), "l.f")
      assert_received {:body, %{"command" => cmd, "language" => "sql"}}
      assert cmd == "DELETE FUNCTION l.f"
    end

    test "an invalid name returns invalid_identifier value-free (no wire call)" do
      capture()
      assert {:error, :invalid_identifier} = Function.delete(conn(), "nolib")
      refute_received {:body, _}
    end
  end

  describe "bang variants" do
    test "define! returns :ok on success" do
      capture()
      assert :ok = Function.define!(conn(), "math.sum", "return a + b", params: [:a, :b])
    end

    test "delete! returns :ok on success" do
      capture()
      assert :ok = Function.delete!(conn(), "l.f")
    end

    test "define! raises on a client reject (value-free)" do
      err = assert_raise ArgumentError, fn -> Function.define!(conn(), "nolib", "return 1") end
      assert err.message =~ "invalid_identifier"
    end

    test "define! raises Arcadic.Error on a server error" do
      Req.Test.stub(__MODULE__, fn c ->
        c
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{
          "error" => "boom",
          "exception" => "com.arcadedb.query.CommandException"
        })
      end)

      assert_raise Arcadic.Error, fn ->
        Function.define!(conn(), "l.f", "return 1")
      end
    end

    test "delete! raises Arcadic.Error on a server error" do
      Req.Test.stub(__MODULE__, fn c ->
        c
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{
          "error" => "boom",
          "exception" => "com.arcadedb.query.CommandException"
        })
      end)

      assert_raise Arcadic.Error, fn ->
        Function.delete!(conn(), "l.f")
      end
    end
  end
end
