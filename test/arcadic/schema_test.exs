defmodule Arcadic.SchemaTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Schema}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

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
end
