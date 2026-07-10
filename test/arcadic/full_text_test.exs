defmodule Arcadic.FullTextTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, FullText}

  @secret "S3CR3T-ft-query-must-stay-in-params"

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
    test "emits CREATE INDEX IF NOT EXISTS … FULL_TEXT (single property, default)" do
      capture()
      assert :ok = FullText.create_index(conn(), "Article", "body")
      assert_received {:body, %{"command" => cmd, "language" => "sql"}}
      assert cmd == "CREATE INDEX IF NOT EXISTS ON Article (body) FULL_TEXT"
    end

    test "multi-property index" do
      capture()
      assert :ok = FullText.create_index(conn(), "Article", ["title", "body"])
      assert_received {:body, %{"command" => cmd}}
      assert cmd == "CREATE INDEX IF NOT EXISTS ON Article (title, body) FULL_TEXT"
    end

    test ":if_not_exists false drops the guard" do
      capture()
      assert :ok = FullText.create_index(conn(), "Article", "body", if_not_exists: false)
      assert_received {:body, %{"command" => cmd}}
      assert cmd == "CREATE INDEX ON Article (body) FULL_TEXT"
    end

    test "analyzer atom maps to its FQCN" do
      capture()
      assert :ok = FullText.create_index(conn(), "Article", "body", analyzer: :english)
      assert_received {:body, %{"command" => cmd}}

      assert cmd =~
               "FULL_TEXT METADATA {analyzer:'org.apache.lucene.analysis.en.EnglishAnalyzer'}"
    end

    test "analyzer FQCN string is accepted (validated dotted allowlist)" do
      capture()
      fqcn = "org.apache.lucene.analysis.core.SimpleAnalyzer"
      assert :ok = FullText.create_index(conn(), "Article", "body", analyzer: fqcn)
      assert_received {:body, %{"command" => cmd}}
      assert cmd =~ "METADATA {analyzer:'#{fqcn}'}"
    end

    test "an injection-shaped analyzer string is rejected value-free" do
      err =
        assert_raise ArgumentError, fn ->
          FullText.create_index(conn(), "Article", "body", analyzer: "x'; DROP")
        end

      refute err.message =~ "DROP"
    end

    test "an unknown analyzer atom is rejected value-free" do
      assert_raise ArgumentError, fn ->
        FullText.create_index(conn(), "Article", "body", analyzer: :nope)
      end
    end

    test "an invalid type/property identifier returns {:error, :invalid_identifier} value-free" do
      assert {:error, :invalid_identifier} = FullText.create_index(conn(), "1Bad", "body")
      assert {:error, :invalid_identifier} = FullText.create_index(conn(), "Article", "bad prop")
    end

    test "an unknown opt key is rejected value-free" do
      assert_raise ArgumentError, fn ->
        FullText.create_index(conn(), "Article", "body", nope: 1)
      end
    end
  end

  describe "drop_index/3" do
    test "emits DROP INDEX `T[p]` IF EXISTS" do
      capture()
      assert :ok = FullText.drop_index(conn(), "Article", "body")
      assert_received {:body, %{"command" => cmd}}
      assert cmd == "DROP INDEX `Article[body]` IF EXISTS"
    end
  end

  describe "search/5" do
    test "emits SEARCH_INDEX with the query bound as :q (bare, no score)" do
      capture()
      assert {:ok, []} = FullText.search(conn(), "Article", "body", "fraud")
      assert_received {:body, %{"command" => cmd, "params" => params}}
      assert cmd == "SELECT FROM Article WHERE SEARCH_INDEX('Article[body]', :q) = true"
      assert params == %{"q" => "fraud"}
    end

    test ":with_score uses {metadata:true} + projects $score (no ORDER BY / no alias column)" do
      capture()
      assert {:ok, []} = FullText.search(conn(), "Article", "body", "graph", with_score: true)
      assert_received {:body, %{"command" => cmd}}

      assert cmd ==
               "SELECT *, $score AS score FROM Article WHERE SEARCH_INDEX('Article[body]', :q, {metadata:true}) = true"
    end

    test ":limit binds :k → LIMIT :k" do
      capture()
      assert {:ok, []} = FullText.search(conn(), "Article", "body", "graph", limit: 5)
      assert_received {:body, %{"command" => cmd, "params" => params}}
      assert cmd =~ "LIMIT :k"
      assert params["k"] == 5
    end

    test "Rule 1: the query value stays in params and never enters the statement" do
      capture()
      FullText.search(conn(), "Article", "body", @secret)
      assert_received {:body, %{"command" => cmd, "params" => params}}
      refute cmd =~ @secret
      assert params["q"] == @secret
    end

    test "an invalid identifier returns {:error, :invalid_identifier}" do
      assert {:error, :invalid_identifier} = FullText.search(conn(), "1Bad", "body", "q")
      assert {:error, :invalid_identifier} = FullText.search(conn(), "Article", "bad prop", "q")
    end

    test "a non-positive limit raises value-free" do
      assert_raise ArgumentError, fn ->
        FullText.search(conn(), "Article", "body", "q", limit: 0)
      end
    end
  end

  describe "search_fields/5" do
    test "emits SEARCH_FIELDS(['p'…], :q) with the query bound" do
      capture()
      assert {:ok, []} = FullText.search_fields(conn(), "Article", ["title", "body"], "graph")
      assert_received {:body, %{"command" => cmd, "params" => params}}
      assert cmd == "SELECT FROM Article WHERE SEARCH_FIELDS(['title', 'body'], :q) = true"
      assert params["q"] == "graph"
    end

    test "non-list properties raises value-free (query never echoed)" do
      err =
        assert_raise ArgumentError, fn ->
          FullText.search_fields(conn(), "Article", "body", "SEKRIT-ft-query-xyz")
        end

      refute err.message =~ "SEKRIT-ft-query-xyz"
    end
  end
end
