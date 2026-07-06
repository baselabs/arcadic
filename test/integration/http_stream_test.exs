defmodule Arcadic.Integration.HTTPStreamTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Conn, Server}

  setup_all do
    url =
      System.get_env("ARCADIC_TEST_URL") ||
        flunk("set ARCADIC_TEST_URL to a live ArcadeDB base url")

    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    db = "http_stream_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, db, auth: {"root", pass})

    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)

    # 25 rows in a document type (SQL keyset/offset) and 25 in a vertex type (Cypher stream).
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE Doc", %{}, language: "sql")

    for i <- 1..25,
        do: Arcadic.command!(conn, "INSERT INTO Doc SET i = #{i}", %{}, language: "sql")

    Arcadic.command!(conn, "CREATE VERTEX TYPE Vtx", %{}, language: "sql")

    for i <- 1..25,
        do: Arcadic.command!(conn, "INSERT INTO Vtx SET i = #{i}", %{}, language: "sql")

    {:ok, conn: conn}
  end

  test "SQL WHERE-less drains ALL rows @rid-ordered via the keyset path (chunk < total)", %{
    conn: conn
  } do
    {:ok, stream} =
      Arcadic.query_stream(conn, "SELECT FROM Doc", %{}, language: "sql", chunk_size: 10)

    rows = Enum.to_list(stream)
    # every row emitted exactly once, @rid-ascending, no offset-shift loss.
    assert length(rows) == 25
    rids = Enum.map(rows, & &1["@rid"])
    assert rids == Enum.sort(rids, &rid_leq/2)
    assert Enum.map(rows, & &1["i"]) |> Enum.sort() == Enum.to_list(1..25)
  end

  test "SQL WHERE-present drains ALL matching rows via the offset fallback", %{conn: conn} do
    {:ok, stream} =
      Arcadic.query_stream(conn, "SELECT FROM Doc WHERE i > 20", %{},
        language: "sql",
        chunk_size: 2
      )

    assert Enum.map(Enum.to_list(stream), & &1["i"]) |> Enum.sort() == [21, 22, 23, 24, 25]
  end

  # Cypher streaming (:order_key) lands in Task 2; skip until then (un-skip in Task 2 Step 5).
  # `:skip` (built-in) holds under EVERY filter, including `--only integration` — an unregistered
  # tag like `:s5_cypher_pending` would NOT, since `--only`'s include wins over a tag exclude.
  @tag :skip
  test "Cypher drains a vertex graph in id(v) order via :order_key (chunk < total)", %{conn: conn} do
    {:ok, stream} =
      Arcadic.query_stream(conn, "MATCH (v:Vtx) RETURN v", %{},
        language: "cypher",
        order_key: "id(v)",
        chunk_size: 10
      )

    rows = Enum.to_list(stream)
    assert length(rows) == 25
    assert Enum.map(rows, & &1["i"]) |> Enum.sort() == Enum.to_list(1..25)
  end

  # @rid string "#c:p" ordering: compare (cluster, position) numerically.
  defp rid_leq(a, b), do: rid_tuple(a) <= rid_tuple(b)

  defp rid_tuple("#" <> rest) do
    [c, p] = String.split(rest, ":")
    {String.to_integer(c), String.to_integer(p)}
  end
end
