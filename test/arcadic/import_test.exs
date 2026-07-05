defmodule Arcadic.ImportTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Import}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  defp stub_ok do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:body, Jason.decode!(Req.Test.raw_body(c))})
      Req.Test.json(c, %{"result" => [%{"operation" => "import database", "result" => "OK"}]})
    end)
  end

  defp no_wire, do: Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)

  test "database/3 interpolates the validated URL single-quoted, language sql" do
    stub_ok()
    assert {:ok, [%{"result" => "OK"}]} = Import.database(conn(), "https://host/dump.jsonl.tgz")
    assert_received {:body, body}
    assert body["command"] == "IMPORT DATABASE 'https://host/dump.jsonl.tgz'"
    assert body["language"] == "sql"
    refute Map.has_key?(body, "params")
  end

  test "database/3 emits a WITH clause for number/boolean settings" do
    stub_ok()

    assert {:ok, _} =
             Import.database(conn(), "file:///home/arcadedb/exports/x",
               with: [commitEvery: 100, wal: false]
             )

    assert_received {:body, body}

    assert body["command"] ==
             "IMPORT DATABASE 'file:///home/arcadedb/exports/x' WITH (commitEvery = 100, wal = false)"
  end

  test "database/3 with an empty with: emits no WITH clause" do
    stub_ok()
    assert {:ok, _} = Import.database(conn(), "https://host/x", with: [])
    assert_received {:body, body}
    assert body["command"] == "IMPORT DATABASE 'https://host/x'"
  end

  for {label, url} <- [
        {"single quote", "http://a'b"},
        {"backslash", "http://a\\b"},
        {"space", "http://a b"},
        {"control char", "http://a\ab"},
        {"ftp scheme", "ftp://host/x"},
        {"javascript scheme", "javascript:alert(1)"},
        {"scheme-less", "not-a-url"},
        {"empty", ""},
        {"whitespace only", "   "}
      ] do
    test "database/3 rejects a #{label} URL, without touching the wire" do
      no_wire()
      assert_raise ArgumentError, fn -> Import.database(conn(), unquote(url)) end
    end
  end

  test "URL rejection is value-free — the offending URL is never echoed in the message" do
    no_wire()
    err = assert_raise ArgumentError, fn -> Import.database(conn(), "http://secret-host'--/x") end
    refute err.message =~ "secret-host"
  end

  test "database/3 rejects a non-binary URL value-free" do
    no_wire()
    assert_raise ArgumentError, fn -> Import.database(conn(), :not_a_string) end
  end

  test "database/3 rejects an over-length URL value-free" do
    no_wire()
    long = "http://host/" <> String.duplicate("a", 2100)
    assert_raise ArgumentError, fn -> Import.database(conn(), long) end
  end

  test "database/3 rejects an unknown top-level opt key value-free (no wire, no value echo)" do
    no_wire()

    err =
      assert_raise ArgumentError, fn ->
        Import.database(conn(), "https://host/x", wtih: [secretSetting: "SENTINEL_VALUE_9f3a"])
      end

    refute err.message =~ "SENTINEL_VALUE_9f3a"
    refute_received {:body, _}
  end

  test "database/3 rejects non-keyword opts value-free (no wire)" do
    no_wire()
    assert_raise ArgumentError, fn -> Import.database(conn(), "https://host/x", %{with: []}) end
    refute_received {:body, _}
  end

  test "with: rejects a string value and a bad-shape name value-free" do
    no_wire()

    assert_raise ArgumentError, fn ->
      Import.database(conn(), "http://h/x", with: [mapping: "file.json"])
    end

    assert_raise ArgumentError, fn ->
      Import.database(conn(), "http://h/x", with: [{:"bad name", 1}])
    end
  end

  test "database!/3 returns rows or raises the server error" do
    stub_ok()
    assert [%{"result" => "OK"}] = Import.database!(conn(), "https://host/x")
  end
end
