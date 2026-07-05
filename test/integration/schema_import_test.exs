defmodule Arcadic.Integration.SchemaImportTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Conn, Import, Schema, Server}

  # Server-local directory ArcadeDB writes EXPORT DATABASE artifacts to. Verified live at
  # /home/arcadedb/exports for the qor-arcadedb container; override for other setups.
  @export_dir System.get_env("ARCADIC_TEST_EXPORT_DIR", "/home/arcadedb/exports")

  setup_all do
    url =
      System.get_env("ARCADIC_TEST_URL") ||
        flunk("set ARCADIC_TEST_URL to a live ArcadeDB base url")

    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    db = "si_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, db, auth: {"root", pass})

    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)

    Arcadic.command!(conn, "CREATE VERTEX TYPE Person", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY Person.name STRING", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY Person.age INTEGER", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE INDEX ON Person (name) UNIQUE", %{}, language: "sql")
    Arcadic.command!(conn, "INSERT INTO Person SET name = 'Ann', age = 30", %{}, language: "sql")

    {:ok, conn: conn, url: url, pass: pass}
  end

  defp assert_no_props(%{} = m) do
    refute Map.has_key?(m, "@props")
    Enum.each(m, fn {_k, v} -> assert_no_props(v) end)
  end

  defp assert_no_props(list) when is_list(list), do: Enum.each(list, &assert_no_props/1)
  defp assert_no_props(_), do: :ok

  test "types/1 reflects the type with nested properties + indexes, @props-free", %{conn: conn} do
    assert {:ok, rows} = Schema.types(conn)
    person = Enum.find(rows, &(&1["name"] == "Person"))
    assert person["type"] == "vertex"
    prop_names = person["properties"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert prop_names == ["age", "name"]
    assert Enum.any?(person["indexes"], &(&1["name"] == "Person[name]"))
    assert_no_props(person)
  end

  test "properties/2 returns the type's properties, un-nested and @props-free", %{conn: conn} do
    assert {:ok, props} = Schema.properties(conn, "Person")
    assert props |> Enum.map(& &1["name"]) |> Enum.sort() == ["age", "name"]
    assert_no_props(props)
    assert {:ok, []} = Schema.properties(conn, "NoSuchType")
  end

  test "indexes/2 includes the logical index; :type filters to it", %{conn: conn} do
    assert {:ok, all} = Schema.indexes(conn)
    assert Enum.any?(all, &(&1["name"] == "Person[name]"))
    assert {:ok, filtered} = Schema.indexes(conn, type: "Person")
    assert Enum.all?(filtered, &(&1["typeName"] == "Person"))
    assert_no_props(all)
  end

  test "buckets/1 lists the type's primary bucket", %{conn: conn} do
    assert {:ok, buckets} = Schema.buckets(conn)
    assert Enum.any?(buckets, &(&1["name"] == "Person_0"))
    assert_no_props(buckets)
  end

  test "import happy path: EXPORT then IMPORT file:// round-trips to result OK", %{
    conn: conn,
    url: url,
    pass: pass
  } do
    name = "si_exp_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    # EXPORT writes to the server's export dir (raw command — EXPORT is not public surface).
    Arcadic.command!(conn, "EXPORT DATABASE file://#{name} WITH overwrite = true", %{},
      language: "sql"
    )

    dst_name = "si_dst_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    dst = Conn.new(url, dst_name, auth: {"root", pass})
    _ = Server.drop_database(dst, dst_name)
    :ok = Server.create_database!(dst, dst_name)
    on_exit(fn -> Server.drop_database(dst, dst_name) end)

    assert {:ok, rows} = Import.database(dst, "file://#{@export_dir}/#{name}")
    assert Enum.any?(rows, &(&1["result"] == "OK"))
  end

  test "import blocked/unreachable host reflects the server error (SSRF guard)", %{conn: conn} do
    assert {:error, %Arcadic.Error{reason: :unauthorized} = err} =
             Import.database(conn, "http://127.0.0.1:9/x.jsonl")

    # distinguishable from an auth failure via the exception FQN
    assert err.exception == "java.lang.SecurityException"
  end

  test "adversarial: an injection-shaped URL is rejected client-side and the DB is unharmed", %{
    conn: conn
  } do
    err = assert_raise ArgumentError, fn -> Import.database(conn, "http://evil'--/x") end
    refute err.message =~ "evil"
    # never reached the wire → schema still intact
    assert {:ok, rows} = Schema.types(conn)
    assert Enum.any?(rows, &(&1["name"] == "Person"))
  end
end
