defmodule Arcadic.ExportTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Export}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  defp stub do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:body, Jason.decode!(Req.Test.raw_body(c))})

      Req.Test.json(c, %{
        "result" => [%{"operation" => "export database", "result" => "OK", "@props" => "x:1"}]
      })
    end)
  end

  defp no_wire, do: Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)

  test "database/3 emits EXPORT DATABASE file://<name>, language sql, @props-stripped" do
    stub()
    assert {:ok, [row]} = Export.database(conn(), "backup_2026")
    assert row == %{"operation" => "export database", "result" => "OK"}
    assert_received {:body, body}
    assert body["command"] == "EXPORT DATABASE file://backup_2026"
    assert body["language"] == "sql"
  end

  test "database/3 emits a no-parens WITH clause reusing the import settings grammar" do
    stub()
    assert {:ok, _} = Export.database(conn(), "b", with: [format: "jsonl", overwrite: true])
    assert_received {:body, body}
    assert body["command"] == "EXPORT DATABASE file://b WITH format = 'jsonl', overwrite = true"
  end

  test "database/3 rejects a name with a path/traversal char value-free (no wire, no echo)" do
    no_wire()

    for bad <- ["../etc/passwd", "a/b", "a'b", "a\\b"] do
      err = assert_raise ArgumentError, fn -> Export.database(conn(), bad) end
      assert err.message =~ "export name"
      refute err.message =~ bad
    end
  end

  test "database/3 rejects a non-string name value-free (no wire) — symmetric to Import" do
    no_wire()
    err = assert_raise ArgumentError, fn -> Export.database(conn(), :not_a_string) end
    assert err.message =~ "export name must be a string"
  end

  test "database/3 rejects an empty name value-free (charset branch, no wire)" do
    no_wire()
    err = assert_raise ArgumentError, fn -> Export.database(conn(), "") end
    assert err.message =~ "allowed set"
  end

  test "database!/3 returns the rows or raises" do
    stub()
    assert [%{"result" => "OK"}] = Export.database!(conn(), "b")
  end
end
