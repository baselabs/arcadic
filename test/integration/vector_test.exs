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
end
