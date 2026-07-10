defmodule Arcadic.Integration.GraphRAGTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Bulk, Conn, FullText, Param, Server, Vector}

  setup_all do
    url =
      System.get_env("ARCADIC_TEST_URL") ||
        flunk("set ARCADIC_TEST_URL to a live ArcadeDB base url")

    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    db = "gr_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, db, auth: {"root", pass})

    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)

    {:ok, conn: conn}
  end

  test "Bulk.ingest wires edges via @id temp keys, injection-inert, surfaces id_mapping",
       %{conn: conn} do
    Arcadic.command!(conn, "CREATE VERTEX TYPE Person", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE EDGE TYPE Knows", %{}, language: "sql")

    assert {:ok, %{vertices_created: 2, edges_created: 1, id_mapping: mapping}} =
             Bulk.ingest(conn, [
               %{
                 "@type" => "vertex",
                 "@class" => "Person",
                 "@id" => "t1",
                 "name" => "O'Brien\"; DROP"
               },
               %{"@type" => "vertex", "@class" => "Person", "@id" => "t2", "name" => "Bob"},
               %{"@type" => "edge", "@class" => "Knows", "@from" => "t1", "@to" => "t2"}
             ])

    # idMapping maps each temp @id to its real RID — 2 vertices → 2 entries.
    assert map_size(mapping) == 2
    assert Enum.sort(Map.keys(mapping)) == ["t1", "t2"]
    assert Enum.all?(Map.values(mapping), &(&1 =~ ~r/\A#\d+:\d+\z/))

    # The quote/semicolon-bearing name is stored verbatim (structured ingest, not statement text).
    assert {:ok, [%{"name" => "O'Brien\"; DROP"}]} =
             Arcadic.query(
               conn,
               "SELECT name FROM Person WHERE name = :n",
               %{"n" => "O'Brien\"; DROP"},
               language: "sql"
             )

    # The edge actually connects the two vertices.
    assert {:ok, [%{"c" => 1}]} =
             Arcadic.query(conn, "SELECT count(*) AS c FROM Knows", %{}, language: "sql")
  end

  test "FULL_TEXT retro-indexes existing rows and search ranks by score", %{conn: conn} do
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE Article", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY Article.body STRING", %{}, language: "sql")

    for b <- ["graph database engine", "fraud ring graph traversal", "vector graph search"] do
      Arcadic.command!(conn, "INSERT INTO Article SET body = :b", %{"b" => b}, language: "sql")
    end

    :ok = FullText.create_index(conn, "Article", "body")

    assert {:ok, rows} =
             FullText.search(conn, "Article", "body", "fraud", with_score: true, limit: 5)

    assert Enum.any?(rows, &(&1["body"] =~ "fraud"))
    assert Enum.all?(rows, &is_number(&1["score"]))
    scores = Enum.map(rows, & &1["score"])
    assert scores == Enum.sort(scores, :desc)
  end

  test "hybrid fuse combines a dense arm and a full-text arm into one ranked list", %{conn: conn} do
    # Self-contained: provisions its own type / properties / rows / indexes so the suite is
    # order-independent (no dependency on any other test's schema).
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE Hybrid", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY Hybrid.body STRING", %{}, language: "sql")

    Arcadic.command!(conn, "CREATE PROPERTY Hybrid.embedding ARRAY_OF_FLOATS", %{},
      language: "sql"
    )

    for {b, e} <- [
          {"graph database engine", "[1.0,0.0,0.0]"},
          {"vector graph search", "[0.0,0.0,1.0]"},
          {"fraud ring graph traversal", "[0.9,0.1,0.0]"}
        ] do
      Arcadic.command!(conn, "INSERT INTO Hybrid SET body = :b, embedding = #{e}", %{"b" => b},
        language: "sql"
      )
    end

    :ok = FullText.create_index(conn, "Hybrid", "body")
    :ok = Vector.create_dense_index!(conn, "Hybrid", "embedding", 3, similarity: :cosine)

    assert {:ok, rows} =
             Vector.fuse(conn, [
               {"Hybrid", "embedding", [1.0, 0.0, 0.0], 3},
               {:fulltext, "Hybrid", "body", "graph", 5}
             ])

    assert rows != []

    # Membership (not rank) — order-independent: the exact-vector-match doc (its embedding IS the
    # dense query [1,0,0], and it is also a "graph" full-text hit) must surface in the fused list.
    assert Enum.any?(rows, &(&1["body"] == "graph database engine"))
  end

  test "$int8 / $bytes typed params round-trip into a BINARY vector property", %{conn: conn} do
    Arcadic.command!(conn, "CREATE VERTEX TYPE Emb", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY Emb.v BINARY", %{}, language: "sql")

    assert {:ok, _} =
             Arcadic.command(
               conn,
               "INSERT INTO Emb SET v = :e",
               %{"e" => Param.int8([0, 64, 127, -1, -128])},
               language: "sql"
             )

    assert {:ok, [%{"etype" => "BINARY"}]} =
             Arcadic.query(conn, "SELECT v.type() AS etype FROM Emb", %{}, language: "sql")

    # Full round-trip: the BINARY property reads back as the exact signed-int8 sequence sent,
    # proving the `$int8` marker decoded server-side into the right bytes (not just some BINARY).
    assert {:ok, [%{"v" => [0, 64, 127, -1, -128]}]} =
             Arcadic.query(conn, "SELECT v FROM Emb", %{}, language: "sql")
  end

  test "UNWIND $rows idiom upserts a batch idempotently via command/4 (G19 documented pattern)",
       %{conn: conn} do
    rows = [
      %{"id" => 1, "props" => %{"name" => "one"}},
      %{"id" => 2, "props" => %{"name" => "two"}}
    ]

    merge = "UNWIND $rows AS r MERGE (n:Node {id: r.id}) SET n += r.props RETURN count(n) AS c"

    assert {:ok, [%{"c" => 2}]} = Arcadic.command(conn, merge, %{"rows" => rows})

    # Replay the identical batch — an idempotent MERGE must MATCH the existing nodes, not CREATE.
    assert {:ok, [%{"c" => 2}]} = Arcadic.command(conn, merge, %{"rows" => rows})

    # Aggregation-independent proof of idempotency: `RETURN count(n)` above counts the 2 unwound
    # rows regardless of persisted state (returns 2 even if the MERGE had duplicated), so it cannot
    # catch a broken upsert. This MATCH over ALL Node vertices does — it is 2, not 4, after replay.
    assert {:ok, [%{"total" => 2}]} =
             Arcadic.command(conn, "MATCH (n:Node) RETURN count(*) AS total", %{})
  end
end
