defmodule Arcadic.BoundaryRedactionTest do
  @moduledoc """
  The HTTP boundary's value-free contract on UNENCODABLE caller data (Rule 3): a param or
  statement that cannot become JSON must surface a typed, value-free error — never a
  Jason/Protocol raise whose message ECHOES the offending value.
  """
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Import, Server, Vector}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  describe "unencodable params/statements never echo (Rule 3)" do
    test "an invalid-UTF-8 param value returns a typed error, never a Jason echo" do
      bad = <<0xFF, 0xFE, "secret-ish"::binary>>

      assert {:error, %Arcadic.Error{reason: :invalid_params}} =
               Arcadic.query(conn(), "RETURN $x", %{"x" => bad})
    end

    test "a tuple param value returns a typed error, never a Protocol echo" do
      assert {:error, %Arcadic.Error{reason: :invalid_params}} =
               Arcadic.command(conn(), "CREATE (n {v:$v})", %{"v" => {:atom, 99}})
    end

    test "a non-binary statement is rejected value-free at the facade" do
      err = assert_raise ArgumentError, fn -> Arcadic.query(conn(), :not_a_statement, %{}) end
      assert Exception.message(err) =~ "statement must be a string"
    end

    test "a non-binary statement is rejected on command/async/bookmarked too" do
      assert_raise ArgumentError, fn -> Arcadic.command(conn(), 99, %{}) end
      assert_raise ArgumentError, fn -> Arcadic.command_async(conn(), {:oops}, %{}) end
      assert_raise ArgumentError, fn -> Arcadic.query_bookmarked(conn(), [:x], %{}) end
      assert_raise ArgumentError, fn -> Arcadic.command_bookmarked(conn(), %{bad: 1}, %{}) end
    end
  end

  describe "facade value guards on bound caller data" do
    test "Vector.require_list! rejects a non-number element value-free" do
      err =
        assert_raise ArgumentError, fn ->
          Vector.sparse_neighbors(conn(), "Doc", "tokens", "weights", [1, {:oops}], [0.5, 0.5], 3)
        end

      assert Exception.message(err) =~ "must be a list of numbers"
    end

    test "FullText.search rejects a non-binary query value-free" do
      # Dynamic delivery keeps the atom's type out of the call site (a literal would trip the
      # success-typing warning; the guard must still catch it at runtime).
      query = Map.get(%{}, :missing, :not_a_query)

      err =
        assert_raise ArgumentError, fn ->
          Arcadic.FullText.search(conn(), "Doc", "body", query)
        end

      assert Exception.message(err) =~ "query must be a string"
    end
  end

  describe "Import result envelope fails closed on FAIL rows" do
    test "a 2xx row reporting result FAIL is a typed error, not a silent success" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{
          "result" => [
            %{"operation" => "import database", "fromUrl" => "file:///x", "result" => "FAIL"}
          ]
        })
      end)

      assert {:error, %Arcadic.Error{reason: :import_failed}} =
               Import.database(conn(), "file:///x")
    end

    test "a successful import row still returns {:ok, rows}" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{
          "result" => [
            %{"operation" => "import database", "result" => "OK", "parsedRecords" => 5}
          ]
        })
      end)

      assert {:ok, [row]} = Import.database(conn(), "file:///x")
      assert row["parsedRecords"] == 5
    end
  end

  describe "list_databases fails closed off-contract" do
    test "a 2xx body without a result list is an error, never a silent empty list" do
      Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"unexpected" => true}) end)

      assert {:error, %Arcadic.Error{reason: :unexpected_response}} =
               Server.list_databases(conn())
    end

    test "database_exists? no longer answers false on protocol drift" do
      Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"nope" => 1}) end)

      assert {:error, %Arcadic.Error{reason: :unexpected_response}} =
               Server.database_exists?(conn(), "mydb")
    end
  end

  describe "value-free opt validation" do
    test "transaction isolation rejects an unknown level without echoing it" do
      err =
        assert_raise ArgumentError, fn ->
          Arcadic.transaction(conn(), fn _tx -> :ok end, isolation: :bogus_level)
        end

      assert Exception.message(err) =~ "unknown isolation"
      refute Exception.message(err) =~ "bogus_level"
    end

    test "check_database rejects a non-boolean :fix value-free" do
      err = assert_raise ArgumentError, fn -> Server.check_database(conn(), fix: "true") end
      assert Exception.message(err) =~ "fix must be a boolean"
    end
  end

  describe "streaming opts" do
    test "query_stream accepts a per-call :request_timeout and still pages" do
      Req.Test.stub(__MODULE__, fn c ->
        # A keyset page row must carry the @rid cursor (the stream guard refuses otherwise).
        Req.Test.json(c, %{"result" => [%{"n" => 1, "@rid" => "#1:0"}]})
      end)

      assert {:ok, stream} =
               Arcadic.query_stream(conn(), "SELECT FROM V", %{},
                 language: "sql",
                 request_timeout: 500
               )

      # Acceptance + one real enumerated page (the option value itself is a Req option,
      # not visible through the plug — the plumbing is code-reviewed, the opt-in is tested).
      assert [%{"n" => 1}] = Enum.to_list(stream)
    end
  end
end
