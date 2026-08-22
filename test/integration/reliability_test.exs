defmodule Arcadic.Integration.ReliabilityTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Conn, Server}

  setup_all do
    url = System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL")
    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    db = "rel_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, db, auth: {"root", pass})
    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)
    {:ok, conn: conn}
  end

  test "read_your_writes on a single server is a harmless no-op; bookmark stays nil", %{
    conn: conn
  } do
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE T", %{}, language: "sql")
    rw = Conn.with_consistency(conn, :read_your_writes)

    {:ok, _rows, conn2} =
      Arcadic.command_bookmarked(rw, "INSERT INTO T SET n = 1", %{}, language: "sql")

    # single-server: X-ArcadeDB-Commit-Index absent → bookmark unchanged (nil)
    assert conn2.read_after == nil

    assert {:ok, [%{"c" => 1}]} =
             Arcadic.query(conn2, "SELECT count(*) AS c FROM T", %{}, language: "sql")
  end

  test "managed retry survives a real MVCC conflict on the same record", %{conn: conn} do
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE Ctr", %{}, language: "sql")
    Arcadic.command!(conn, "INSERT INTO Ctr SET id = 'x', v = 0", %{}, language: "sql")

    task =
      Task.async(fn ->
        Arcadic.transaction(
          conn,
          fn tx ->
            Arcadic.command!(tx, "UPDATE Ctr SET v = v + 1 WHERE id = 'x'", %{}, language: "sql")
          end,
          retry: [max_attempts: 10, base_backoff_ms: 5, max_backoff_ms: 50]
        )
      end)

    other =
      Arcadic.transaction(
        conn,
        fn tx ->
          Arcadic.command!(tx, "UPDATE Ctr SET v = v + 1 WHERE id = 'x'", %{}, language: "sql")
        end,
        retry: [max_attempts: 10, base_backoff_ms: 5, max_backoff_ms: 50]
      )

    assert {:ok, _} = Task.await(task, 30_000)
    assert {:ok, _} = other

    assert {:ok, [%{"v" => 2}]} =
             Arcadic.query(conn, "SELECT v FROM Ctr WHERE id = 'x'", %{}, language: "sql")
  end

  test "server-side :retries converges concurrent same-type autocommit writes (MVCC statement retry)",
       %{conn: conn} do
    # Concurrent CREATEs to ONE vertex type contend on the type's buckets — on a DEFAULT-bucket
    # type, 100 creates @ 16-wide throw ~85 ConcurrentModificationException without retries
    # (probed 2026-07-15). The server-side `retries:` body param re-executes the STATEMENT on the
    # conflict; an autocommit statement is all-or-nothing (nothing applied on conflict), so the
    # retry is idempotency-safe by construction. RED-capable: drop `retries: 10` below → conflicts
    # return and the count assertions fail. (Inside a SESSION the param is a no-op — conflicts
    # surface at commit; use `transaction/3` with `:retry` for that, the test above.)
    Arcadic.command!(conn, "CREATE VERTEX TYPE Cw", %{}, language: "sql")

    creates =
      1..100
      |> Task.async_stream(
        fn i ->
          Arcadic.command(conn, "CREATE (x:Cw {id: $id})", %{"id" => "r#{i}"}, retries: 10)
        end,
        max_concurrency: 16,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(creates, &match?({:ok, _}, &1))
    assert {:ok, [%{"c" => 100}]} = Arcadic.query(conn, "MATCH (x:Cw) RETURN count(x) AS c")

    # The UNWIND-batch form (a bulk writer's shape) converges the same way.
    batches =
      1..10
      |> Task.async_stream(
        fn b ->
          rows = for i <- 1..8, do: %{"id" => "b#{b}r#{i}"}

          Arcadic.command(
            conn,
            "UNWIND $rows AS row CREATE (n:Cw) SET n += row",
            %{"rows" => rows},
            retries: 10
          )
        end,
        max_concurrency: 8,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(batches, &match?({:ok, _}, &1))
    assert {:ok, [%{"c" => 180}]} = Arcadic.query(conn, "MATCH (x:Cw) RETURN count(x) AS c")
  end
end
