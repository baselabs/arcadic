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

  # A fresh throwaway destination db (mirrors the inline pattern at :83-87; DRY across the new
  # round-trip tests). `on_exit` runs in the test process — valid from a helper.
  defp new_db(url, pass) do
    name = "s4_dst_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, name, auth: {"root", pass})
    _ = Server.drop_database(conn, name)
    :ok = Server.create_database!(conn, name)
    on_exit(fn -> Server.drop_database(conn, name) end)
    conn
  end

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

  test "Schema.database/1 returns the live engine config, @props-free", %{conn: conn} do
    assert {:ok, cfg} = Arcadic.Schema.database(conn)
    assert is_binary(cfg["name"])
    assert is_list(cfg["settings"])
    refute Map.has_key?(cfg, "@props")
    refute Enum.any?(cfg["settings"], &Map.has_key?(&1, "@props"))
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

  test "import with: settings PARSES + RUNS against live ArcadeDB (the parens grammar bug regression)",
       %{conn: conn, url: url, pass: pass} do
    # Round-trip a throwaway db through EXPORT → IMPORT WITH a real setting. The OLD `WITH (parens)`
    # grammar parse-errors on ArcadeDB 26.8.1, so this test is RED on the pre-fix code — it is the
    # live peer-conformance gate the unit stub could never be (arcadic is tenant-blind about a
    # setting's SEMANTICS; this proves the clause GRAMMAR the server actually accepts).
    name = "s4_with_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE W", %{}, language: "sql")
    for i <- 1..3, do: Arcadic.command!(conn, "INSERT INTO W SET n = #{i}", %{}, language: "sql")

    Arcadic.command!(conn, "EXPORT DATABASE file://#{name} WITH overwrite = true", %{},
      language: "sql"
    )

    dst = new_db(url, pass)

    # The load-bearing peer-conformance signal: the no-parens `WITH commitEvery = 1, wal = false`
    # clause PARSES and the import RUNS to `result == "OK"`. On the pre-fix `WITH (parens)` form the
    # server rejects this with `reason: :parse_error`
    # (`com.arcadedb.exception.CommandSQLParsingException`) — probed live 2026-07-06 — so this
    # assertion is RED on the shipped bug and GREEN on the fix. The unit stub can never catch this
    # (it echoes whatever bytes it is sent); only a live bind proves the GRAMMAR the server accepts.
    assert {:ok, rows} =
             Arcadic.Import.database(dst, "file://#{@export_dir}/#{name}",
               with: [commitEvery: 1, wal: false]
             )

    assert Enum.any?(rows, &(&1["result"] == "OK"))
  end

  test "Arcadic.Export.database round-trips: export then import via the public surface", %{
    conn: conn,
    url: url,
    pass: pass
  } do
    name = "s4_exp_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE E", %{}, language: "sql")
    for i <- 1..4, do: Arcadic.command!(conn, "INSERT INTO E SET n = #{i}", %{}, language: "sql")

    assert {:ok, rows} = Arcadic.Export.database(conn, name, with: [overwrite: true])
    assert Enum.any?(rows, &(&1["result"] == "OK"))
    refute Enum.any?(rows, &Map.has_key?(&1, "@props"))
    # [AMENDED 2026-07-06] Data-effect proof that SURVIVES this substrate: the EXPORT result row's
    # source-side record count reflects at least the 4 rows this test created (orchestrator live probe
    # 2026-07-06: `totalRecords` is present + accurate on the export row). `conn` is the shared
    # setup_all db (also holds Person + any sibling-test types), so assert a FLOOR (`>= 4`), not an
    # exact count. The plan's original post-import `SELECT count(*) FROM E` is UNSATISFIABLE: ArcadeDB's
    # JSONL file:// round-trip drops the custom document type E (imported rows land under generic
    # `Document`, and even that count is unreliable) — proven live, same defect as Task 1's `FROM W`.
    assert Enum.any?(rows, &(is_integer(&1["totalRecords"]) and &1["totalRecords"] >= 4))

    dst = new_db(url, pass)
    assert {:ok, _} = Arcadic.Import.database(dst, "file://#{@export_dir}/#{name}")
  end

  test "a string with: setting carrying a loopback URL opens no new SSRF door (B9 boundary)", %{
    conn: conn
  } do
    # A string `mapping` setting URL must NOT be an independent server-side fetch vector. The gate is
    # a DISCRIMINATOR, not a bare `{:error, _}`: a loopback `mapping` must produce the IDENTICAL
    # source-error signature as the same nonexistent source with NO mapping — proving the mapping URL
    # was never fetched. If ArcadeDB ever DID fetch it, `importBlockLocalNetworks` would block the
    # loopback and surface the SSRF-block signature (`reason: :unauthorized` /
    # `exception: "java.lang.SecurityException"` — the signature a loopback *source* produces),
    # flipping BOTH assertions below RED. Probed live 2026-07-06:
    #   loopback mapping AND no-mapping -> reason :server_error / com.arcadedb…CommandExecutionException
    #   loopback SOURCE (real SSRF block) -> reason :unauthorized / java.lang.SecurityException
    baseline = Arcadic.Import.database(conn, "file:///tmp/arcadic_none.jsonl", with: [])

    with_mapping =
      Arcadic.Import.database(conn, "file:///tmp/arcadic_none.jsonl",
        with: [mapping: "http://127.0.0.1:9/x"]
      )

    assert {:error, %Arcadic.Error{reason: base_reason, exception: base_exc}} = baseline
    assert {:error, %Arcadic.Error{reason: map_reason, exception: map_exc}} = with_mapping

    # The mapping changes NOTHING about the error — it was not fetched.
    assert {map_reason, map_exc} == {base_reason, base_exc}

    # And explicitly: it is NOT the SSRF-block signature a fetched-and-blocked loopback would raise.
    refute map_reason == :unauthorized
    refute map_exc == "java.lang.SecurityException"
  end

  test "with: settings are PROCESSED not ignored — a bad commitEvery errors on the SETTING (B9 direct effect)",
       %{conn: conn, url: url, pass: pass} do
    name = "s7_b9_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    # Distinct type name — the shared setup_all db is reused across tests, and the sibling
    # "import with: settings PARSES + RUNS" test already creates type `W` (schema_import_test.exs:137);
    # a duplicate CREATE raises. IF NOT EXISTS is belt-and-suspenders.
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE Wb9 IF NOT EXISTS", %{}, language: "sql")
    Arcadic.command!(conn, "INSERT INTO Wb9 SET n = 1", %{}, language: "sql")

    Arcadic.command!(conn, "EXPORT DATABASE file://#{name} WITH overwrite = true", %{},
      language: "sql"
    )

    dst = new_db(url, pass)

    # Same valid path the happy-path sibling imports OK; only commitEvery changes to a charset-clean
    # NON-numeric string. The server PARSES the WITH clause and rejects the value ("For input string"),
    # so the setting is demonstrably processed, not silently dropped. `reason` is :server_error
    # (CommandExecutionException is unmapped → fallback); the setting-specific signal is `detail`.
    assert {:error, %Arcadic.Error{reason: :server_error} = e} =
             Arcadic.Import.database(dst, "file://#{@export_dir}/#{name}",
               with: [commitEvery: "notanumber"]
             )

    assert e.detail =~ "For input string"
  end
end
