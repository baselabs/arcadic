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
end
