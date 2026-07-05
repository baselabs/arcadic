defmodule Arcadic.Integration.VectorTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Conn, Server, Vector}

  setup_all do
    url =
      System.get_env("ARCADIC_TEST_URL") ||
        flunk("set ARCADIC_TEST_URL to a live ArcadeDB base url")

    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    db = "vec_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    admin = Conn.new(url, db, auth: {"root", pass})

    _ = Server.drop_database(admin, db)
    :ok = Server.create_database!(admin, db)
    on_exit(fn -> Server.drop_database(admin, db) end)

    # schema + data + index (never touch commercegraph — this is a throwaway DB)
    Arcadic.command!(admin, "CREATE VERTEX TYPE Doc", %{}, language: "sql")
    Arcadic.command!(admin, "CREATE PROPERTY Doc.embedding ARRAY_OF_FLOATS", %{}, language: "sql")
    Arcadic.command!(admin, "CREATE PROPERTY Doc.title STRING", %{}, language: "sql")
    Arcadic.command!(admin, "CREATE PROPERTY Doc.category STRING", %{}, language: "sql")

    for {t, e} <- [{"cat", "[1.0,0.0,0.0]"}, {"dog", "[0.9,0.1,0.0]"}, {"car", "[0.0,0.0,1.0]"}] do
      Arcadic.command!(admin, "INSERT INTO Doc SET title='#{t}', embedding=#{e}", %{},
        language: "sql"
      )
    end

    :ok = Vector.create_dense_index!(admin, "Doc", "embedding", 3, similarity: :cosine)
    {:ok, conn: admin}
  end

  test "neighbors ranks by ascending distance", %{conn: conn} do
    assert {:ok, rows} = Vector.neighbors(conn, "Doc", "embedding", [1.0, 0.0, 0.0], 3)
    titles = Enum.map(rows, & &1["title"])
    assert titles == ["cat", "dog", "car"]
    assert hd(rows)["distance"] == 0.0
    # distances are non-decreasing
    distances = Enum.map(rows, & &1["distance"])
    assert distances == Enum.sort(distances)
  end

  test "max_distance excludes far rows even under k", %{conn: conn} do
    assert {:ok, rows} =
             Vector.neighbors(conn, "Doc", "embedding", [1.0, 0.0, 0.0], 5, max_distance: 0.01)

    titles = Enum.map(rows, & &1["title"])
    assert "cat" in titles
    refute "car" in titles
  end

  test "fuse over two dense subqueries returns a fused ranked list", %{conn: conn} do
    assert {:ok, rows} =
             Vector.fuse(conn, [
               {"Doc", "embedding", [1.0, 0.0, 0.0], 3},
               {"Doc", "embedding", [0.0, 0.0, 1.0], 3}
             ])

    assert rows != []
  end

  test "create_dense_index is idempotent (IF NOT EXISTS re-run) and drop is idempotent", %{
    conn: conn
  } do
    assert :ok = Vector.create_dense_index(conn, "Doc", "embedding", 3, similarity: :cosine)
    assert :ok = Vector.drop_dense_index(conn, "Doc", "embedding")
    assert :ok = Vector.drop_dense_index(conn, "Doc", "embedding")
    # re-create so setup_all teardown state is unaffected for any following test
    assert :ok = Vector.create_dense_index(conn, "Doc", "embedding", 3, similarity: :cosine)
  end

  test "sparse_neighbors ranks by descending score with create-before-load", %{conn: conn} do
    t = "Sp" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    Arcadic.command!(conn, "CREATE VERTEX TYPE #{t}", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY #{t}.tokens ARRAY_OF_INTEGERS", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY #{t}.weights ARRAY_OF_FLOATS", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY #{t}.title STRING", %{}, language: "sql")
    # index BEFORE load
    :ok = Vector.create_sparse_index(conn, t, "tokens", "weights")

    for {title, tk, w} <- [{"a", "[1,2,3]", "[0.9,0.5,0.2]"}, {"b", "[1,2,4]", "[0.4,0.5,0.6]"}] do
      Arcadic.command!(
        conn,
        "INSERT INTO #{t} SET title='#{title}', tokens=#{tk}, weights=#{w}",
        %{},
        language: "sql"
      )
    end

    assert {:ok, rows} =
             Vector.sparse_neighbors(conn, t, "tokens", "weights", [1, 2, 3], [0.9, 0.5, 0.2], 10)

    assert rows != []
    scores = Enum.map(rows, & &1["score"])
    assert scores == Enum.sort(scores, :desc)
    refute Enum.any?(rows, &Map.has_key?(&1, "distance"))
  end

  test "retro-index quirk: pre-existing rows are uncovered AND the telemetry signal fires live",
       %{
         conn: conn
       } do
    t = "Sp" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    Arcadic.command!(conn, "CREATE VERTEX TYPE #{t}", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY #{t}.tokens ARRAY_OF_INTEGERS", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY #{t}.weights ARRAY_OF_FLOATS", %{}, language: "sql")
    # rows FIRST, index AFTER (exactly one pre-existing row → totalIndexed == 1)
    Arcadic.command!(conn, "INSERT INTO #{t} SET tokens=[1,2,3], weights=[0.5,0.5,0.5]", %{},
      language: "sql"
    )

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:arcadic, :vector, :sparse_index_preexisting]
      ])

    :ok = Vector.create_sparse_index(conn, t, "tokens", "weights")

    # The retro-index footgun signal fires against the LIVE DDL response's `totalIndexed`
    # shape (not just the stub the unit suite drives), value-free (a count, empty meta).
    # Red-capable: if the guard ever silently no-ops on a server-shape change, no message
    # arrives and this assert_received fails.
    assert_received {[:arcadic, :vector, :sparse_index_preexisting], ^ref, %{count: 1}, %{}}
    :telemetry.detach(ref)

    # documented behavior: pre-existing rows are NOT searchable
    assert {:ok, []} =
             Vector.sparse_neighbors(conn, t, "tokens", "weights", [1, 2, 3], [0.5, 0.5, 0.5], 10)
  end

  test "filter restricts neighbors to a candidate RID set; group_by collapses to top-N per group",
       %{conn: conn} do
    {:ok, all} = Arcadic.query(conn, "SELECT @rid AS rid, title FROM Doc", %{}, language: "sql")
    rids = Enum.map(all, & &1["rid"])

    assert {:ok, filtered} =
             Vector.neighbors(conn, "Doc", "embedding", [1.0, 0.0, 0.0], 10,
               filter: Enum.take(rids, 1)
             )

    assert length(filtered) == 1

    # set categories, then group
    Arcadic.command!(conn, "UPDATE Doc SET category='animal' WHERE title IN ['cat','dog']", %{},
      language: "sql"
    )

    Arcadic.command!(conn, "UPDATE Doc SET category='vehicle' WHERE title='car'", %{},
      language: "sql"
    )

    assert {:ok, grouped} =
             Vector.neighbors(conn, "Doc", "embedding", [1.0, 0.0, 0.0], 10,
               group_by: "category",
               group_size: 1
             )

    cats = grouped |> Enum.map(& &1["category"]) |> Enum.uniq()
    assert length(grouped) == length(cats)
  end

  test "fuse with a shared filter restricts the fused result", %{conn: conn} do
    {:ok, all} = Arcadic.query(conn, "SELECT @rid AS rid FROM Doc", %{}, language: "sql")
    subset = all |> Enum.map(& &1["rid"]) |> Enum.take(2)

    assert {:ok, rows} =
             Vector.fuse(
               conn,
               [
                 {"Doc", "embedding", [1.0, 0.0, 0.0], 3},
                 {"Doc", "embedding", [0.0, 0.0, 1.0], 3}
               ],
               filter: subset
             )

    assert length(rows) == 2
  end
end
