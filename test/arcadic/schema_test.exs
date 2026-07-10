defmodule Arcadic.SchemaTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Schema}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  # Stub the transport with a per-request handler function.
  defp stub(fun) when is_function(fun, 1), do: Req.Test.stub(__MODULE__, fun)

  # Stub the transport: capture the request body, reply with `result`.
  defp stub(result) do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:body, Jason.decode!(Req.Test.raw_body(c))})
      Req.Test.json(c, %{"result" => result})
    end)
  end

  test "types/1 sends the schema:types SQL and deep-strips @props at every depth" do
    stub([
      %{
        "name" => "Person",
        "type" => "vertex",
        "@props" => "records:3,properties:9",
        "properties" => [%{"name" => "age", "type" => "INTEGER", "@props" => "custom:10"}],
        "indexes" => [%{"name" => "Person[age]", "@props" => "properties:9"}],
        "custom" => %{"@props" => "k:1", "kept" => true}
      }
    ])

    assert {:ok, [row]} = Schema.types(conn())
    assert_received {:body, body}
    assert body["command"] == "SELECT FROM schema:types"
    assert body["language"] == "sql"
    refute Map.has_key?(row, "@props")
    refute Map.has_key?(hd(row["properties"]), "@props")
    refute Map.has_key?(hd(row["indexes"]), "@props")
    refute Map.has_key?(row["custom"], "@props")
    assert row["custom"]["kept"] == true
    assert row["name"] == "Person"
    assert hd(row["properties"])["name"] == "age"
  end

  test "buckets/1 sends the schema:buckets SQL and deep-strips @props" do
    stub([%{"name" => "Person_0", "records" => 1, "@props" => "records:3"}])
    assert {:ok, [row]} = Schema.buckets(conn())
    assert_received {:body, body}
    assert body["command"] == "SELECT FROM schema:buckets"
    refute Map.has_key?(row, "@props")
    assert row["name"] == "Person_0"
  end

  test "types!/1 returns the rows" do
    stub([%{"name" => "Person", "type" => "vertex"}])
    assert [%{"name" => "Person"}] = Schema.types!(conn())
  end

  @secret_type "Secret_pii_type_name_must_never_enter_the_statement"

  test "properties/2 binds the type as a param (never in the statement) and un-nests to a bare list" do
    stub([
      %{
        "properties" => [%{"name" => "name", "type" => "STRING", "@props" => "custom:10"}],
        "@props" => "properties:9"
      }
    ])

    assert {:ok, [prop]} = Schema.properties(conn(), @secret_type)
    assert_received {:body, body}
    assert body["command"] == "SELECT properties FROM schema:types WHERE name = :t"
    refute body["command"] =~ @secret_type
    assert body["params"] == %{"t" => @secret_type}
    assert prop == %{"name" => "name", "type" => "STRING"}
  end

  test "properties/2 returns {:ok, []} for an absent (valid-shape) type" do
    stub([])
    assert {:ok, []} = Schema.properties(conn(), "NoSuchType")
  end

  test "properties/2 rejects a bad-shape type name value-free (no wire, no echo)" do
    Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)
    assert {:error, :invalid_identifier} = Schema.properties(conn(), "bad name!")
    refute_received {:body, _}
  end

  test "properties!/2 raises the invalid_identifier value-free" do
    assert_raise ArgumentError, fn -> Schema.properties!(conn(), "bad name!") end
  end

  test "indexes/2 with no opts sends schema:indexes and deep-strips @props" do
    stub([%{"name" => "Person[name]", "typeName" => "Person", "@props" => "properties:9"}])
    assert {:ok, [row]} = Schema.indexes(conn())
    assert_received {:body, body}
    assert body["command"] == "SELECT FROM schema:indexes"
    refute Map.has_key?(body, "params")
    refute Map.has_key?(row, "@props")
  end

  test "indexes/2 with :type binds typeName as a param (never in the statement)" do
    stub([%{"name" => "Person[name]", "typeName" => "Person"}])
    assert {:ok, [_]} = Schema.indexes(conn(), type: @secret_type)
    assert_received {:body, body}
    assert body["command"] == "SELECT FROM schema:indexes WHERE typeName = :t"
    refute body["command"] =~ @secret_type
    assert body["params"] == %{"t" => @secret_type}
  end

  test "indexes/2 rejects a bad-shape :type value-free (no wire)" do
    Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)
    assert {:error, :invalid_identifier} = Schema.indexes(conn(), type: "bad name!")
    refute_received {:body, _}
  end

  test "indexes/2 rejects an unknown opt key value-free (no wire)" do
    Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)
    assert_raise ArgumentError, fn -> Schema.indexes(conn(), typ: "Person") end
    refute_received {:body, _}
  end

  test "indexes/2 rejects non-keyword opts value-free" do
    assert_raise ArgumentError, fn -> Schema.indexes(conn(), %{type: "Person"}) end
  end

  test "database/1 sends SELECT FROM schema:database and deep-strips @props" do
    stub([
      %{
        "name" => "db",
        "encoding" => "UTF-8",
        "@props" => "x:1",
        "settings" => [%{"key" => "k", "value" => 1, "@props" => "y:1"}]
      }
    ])

    assert {:ok, row} = Arcadic.Schema.database(conn())

    assert row == %{
             "name" => "db",
             "encoding" => "UTF-8",
             "settings" => [%{"key" => "k", "value" => 1}]
           }

    assert_received {:body, body}
    assert body["command"] == "SELECT FROM schema:database"
    assert body["language"] == "sql"
  end

  test "database!/1 unwraps to the config map" do
    stub([%{"name" => "db"}])
    assert %{"name" => "db"} = Arcadic.Schema.database!(conn())
  end

  test "stats/1 & dictionary/1 return a single @props-stripped map; materialized_views/1 a list" do
    stub(fn c ->
      cmd = Jason.decode!(Req.Test.raw_body(c))["command"]

      body =
        cond do
          cmd == "SELECT FROM schema:stats" ->
            [%{"writeTx" => 1, "@props" => "writeTx:3"}]

          cmd == "SELECT FROM schema:dictionary" ->
            [%{"totalEntries" => 0, "entries" => %{}, "@props" => "entries:10"}]

          cmd == "SELECT FROM schema:materializedviews" ->
            []
        end

      Req.Test.json(c, %{"result" => body})
    end)

    assert {:ok, %{"writeTx" => 1} = s} = Schema.stats(conn())
    refute Map.has_key?(s, "@props")
    assert {:ok, %{"totalEntries" => 0} = d} = Schema.dictionary(conn())
    refute Map.has_key?(d, "@props")
    assert {:ok, []} = Schema.materialized_views(conn())
  end

  test "stats/1 returns {:ok, %{}} when schema:stats yields no row" do
    stub([])
    assert {:ok, %{}} = Schema.stats(conn())
  end

  test "dictionary/1 returns {:ok, %{}} when schema:dictionary yields no row" do
    stub([])
    assert {:ok, %{}} = Schema.dictionary(conn())
  end

  test "stats!/1 returns the bare stats map" do
    stub([%{"writeTx" => 1, "@props" => "writeTx:3"}])
    assert %{"writeTx" => 1} = Schema.stats!(conn())
  end

  test "dictionary!/1 returns the bare dictionary map" do
    stub([%{"totalEntries" => 0, "@props" => "entries:10"}])
    assert %{"totalEntries" => 0} = Schema.dictionary!(conn())
  end

  test "materialized_views!/1 returns the bare list" do
    stub([%{"name" => "mv1", "@props" => "x:1"}])
    assert [%{"name" => "mv1"}] = Schema.materialized_views!(conn())
  end
end
