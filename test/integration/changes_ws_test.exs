defmodule Arcadic.Integration.ChangesWsTest do
  @moduledoc """
  Live write-then-observe proofs for `Arcadic.Changes` — arcadic's `/ws`
  change-events GenServer — against the running `qor-arcadedb` container. The
  unit suite (`test/arcadic/changes_test.exs`) drives a FAKE `WsEchoServer`;
  this is the first exercise against real ArcadeDB, so it verifies the actual
  `/ws` frame populates `%Changes.Event{}` correctly.

  ## Real `/ws` frame shape (verified live 2026-07-11, ArcadeDB 26.8.1-SNAPSHOT)

  A change is pushed as:

      {"changeType":"create",
       "record":{"@rid":"#1:0","@type":"Widget","@cat":"v","@props":"..","name":".."},
       "database":"<db>"}

  So, mapped onto `%Changes.Event{}`:

    * `change_type` ← `changeType` (`create`/`update`/`delete`).
    * `database`    ← top-level `database` — real ArcadeDB DOES carry it, so
      `Changes.match_subscription/2` demuxes by database (the lone-subscription
      fallback is only for the fake harness).
    * `rid`         ← `record["@rid"]`.
    * `record`      ← the full record map (`@rid`/`@type`/`@cat`/`@props` + props).
    * `type`        ← there is **no top-level `type` key**, so `event.type` is the
      SUBSCRIPTION's `:type` filter (or `nil`); the record's own class is in
      `event.record["@type"]`. Test 1 asserts this fallback explicitly.

  A type-scoped subscribe (`"type":"Widget"`) is honored server-side (a foreign
  type yields no frames), and a `changeTypes` subscription is additionally
  filtered client-side by `Changes.allowed?/2`.

  ## Bearer `/ws` (resolves the plan-write-inconclusive probe)

  VERIFIED live 2026-07-11: ArcadeDB's `/ws` handshake ACCEPTS `Authorization:
  Bearer <token>` (upgrade → HTTP 101). So a `{:bearer, token}` conn connects and
  receives changes; the terminal `{:arcadic_change_error, :unauthorized}` marker
  does NOT fire (test 4).
  """
  use ExUnit.Case, async: false
  @moduletag :integration_ws

  alias Arcadic.{Changes, Conn, Security, Server}
  alias Arcadic.Changes.Event

  setup do
    url = System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL")
    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    db = "changes_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, db, auth: {"root", pass})
    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)
    Arcadic.command!(conn, "CREATE VERTEX TYPE Widget", %{}, language: "sql")
    on_exit(fn -> Server.drop_database(conn, db) end)
    {:ok, conn: conn, db: db}
  end

  test "write-then-observe: a CREATE over a separate conn delivers the exact %Event{}", %{
    conn: conn,
    db: db
  } do
    changes = start_and_open(conn)
    # type-scoped subscription — proves `event.type` carries the subscription filter
    # (the frame has no top-level `type`) and that a type-scoped subscribe is honored.
    :ok = Changes.subscribe(changes, db, type: "Widget")
    settle()

    # The write rides a SEPARATE conn on the HTTP command path — not the ws process.
    Arcadic.command!(writer(conn), "INSERT INTO Widget SET name = 'alpha'", %{}, language: "sql")

    assert_receive {:arcadic_change,
                    %Event{
                      database: ^db,
                      change_type: :create,
                      type: "Widget",
                      rid: rid,
                      record: %{"name" => "alpha", "@type" => "Widget"}
                    }},
                   5000

    assert rid =~ ~r/\A#\d+:\d+\z/
  end

  test "unsubscribe stops delivery: a later CREATE does not arrive", %{conn: conn, db: db} do
    changes = start_and_open(conn)
    :ok = Changes.subscribe(changes, db)
    settle()

    Arcadic.command!(writer(conn), "INSERT INTO Widget SET name = 'first'", %{}, language: "sql")
    # Non-vacuity: the feed is proven live before we unsubscribe.
    assert_receive {:arcadic_change, %Event{change_type: :create, record: %{"name" => "first"}}},
                   5000

    :ok = Changes.unsubscribe(changes, db)
    settle()

    Arcadic.command!(writer(conn), "INSERT INTO Widget SET name = 'second'", %{}, language: "sql")
    refute_receive {:arcadic_change, _}, 1500
  end

  test "change_types: [:create] delivers a create but filters an update", %{conn: conn, db: db} do
    changes = start_and_open(conn)
    :ok = Changes.subscribe(changes, db, change_types: [:create])
    settle()

    w = writer(conn)
    Arcadic.command!(w, "INSERT INTO Widget SET name = 'x'", %{}, language: "sql")

    assert_receive {:arcadic_change, %Event{change_type: :create, record: %{"name" => "x"}}}, 5000

    # ArcadeDB honors `changeTypes` server-side (the subscribe frame requests only `create`), and
    # the client `allowed?` guard is belt-and-suspenders — either way no `:update` event is
    # delivered. The `count: 1` on the UPDATE proves the write actually happened server-side, so
    # the refute is non-vacuous (the update ran; it simply never reaches this subscriber).
    assert {:ok, [%{"count" => 1}]} =
             Arcadic.command(w, "UPDATE Widget SET name = 'y' WHERE name = 'x'", %{},
               language: "sql"
             )

    refute_receive {:arcadic_change, %Event{change_type: :update}}, 1500
  end

  test "bearer /ws: a {:bearer, token} conn subscribes and receives a change (bearer supported)",
       %{conn: conn, db: db} do
    assert {:ok, token} = Security.login(conn)
    assert is_binary(token)
    bearer = Conn.with_bearer(conn, token)

    changes = start_and_open(bearer)
    :ok = Changes.subscribe(changes, db)
    settle()

    Arcadic.command!(writer(conn), "INSERT INTO Widget SET name = 'b'", %{}, language: "sql")

    # RESOLVED PROBE: ArcadeDB /ws accepts Bearer auth (upgrade → 101), so the event arrives...
    assert_receive {:arcadic_change, %Event{change_type: :create, record: %{"name" => "b"}}}, 5000
    # ...and the fail-closed terminal-401 marker never fired.
    refute_received {:arcadic_change_error, :unauthorized}
  end

  test "demux: with TWO subscribed dbs a write to db_a routes to db_a only (top-level-database branch)",
       %{conn: conn, db: db_a} do
    # A SECOND real throwaway db so one Changes process holds TWO subscriptions. With
    # `map_size(subscriptions) == 2`, `Changes.match_subscription/2`'s lone-subscription fallback
    # (guarded on `map_size == 1`, changes.ex:492) is DISABLED — so the frame can ONLY be routed by
    # the top-level-`database` branch (changes.ex:485). This pins the load-bearing claim that real
    # ArcadeDB frames carry a top-level `database` key (my raw Mint.WebSocket probe verified one
    # socket delivers two dbs' changes, each tagged with its originating database).
    db_b = "changes_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn_b = Conn.new(conn.base_url, db_b, auth: conn.auth)
    _ = Server.drop_database(conn_b, db_b)
    :ok = Server.create_database!(conn_b, db_b)
    Arcadic.command!(conn_b, "CREATE VERTEX TYPE Widget", %{}, language: "sql")
    on_exit(fn -> Server.drop_database(conn_b, db_b) end)

    changes = start_and_open(conn)
    :ok = Changes.subscribe(changes, db_a)
    :ok = Changes.subscribe(changes, db_b)
    settle()

    # Write into db_a ONLY, over a separate conn.
    Arcadic.command!(writer(conn), "INSERT INTO Widget SET name = 'in_a'", %{}, language: "sql")

    # The event is tagged with its ORIGINATING db (top-level `database` in the real frame) —
    # proving the top-level-`database` branch routed it (the lone fallback is disabled at map_size 2).
    assert_receive {:arcadic_change,
                    %Event{database: ^db_a, change_type: :create, record: %{"name" => "in_a"}}},
                   5000

    # Nothing was written into db_b → no event ever tagged db_b (rules out mis-routing/cross-talk).
    refute_receive {:arcadic_change, %Event{database: ^db_b}}, 1500
  end

  # --- helpers ---------------------------------------------------------------

  # A distinct handle for the write path (the task's "separate Conn"), reusing the
  # setup conn's Basic credential — the write rides the HTTP command path, independent
  # of the ws process.
  defp writer(%Conn{} = conn),
    do: Conn.new(conn.base_url, conn.database, auth: conn.auth)

  # Start a Changes process and BLOCK until its `/ws` socket is open, using the
  # one-shot `[:arcadic, :changes, :start]` telemetry event — deterministic, no
  # sleep-until-connected race. The subscriber defaults to this (test) pid.
  defp start_and_open(%Conn{} = conn) do
    ref = make_ref()
    test = self()
    handler = "changes-open-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:arcadic, :changes, :start],
      fn _event, _measurements, _meta, _ -> send(test, {:changes_open, ref}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, changes} = Changes.start_link(conn: conn)
    on_exit(fn -> if Process.alive?(changes), do: GenServer.stop(changes) end)

    assert_receive {:changes_open, ^ref}, 5000
    changes
  end

  # Small settle after a subscribe/unsubscribe frame is sent: the frame is in flight
  # on localhost and the server registers/clears the subscription in sub-ms; this margin
  # closes the tiny send→register window before the write that must (not) be observed.
  defp settle, do: Process.sleep(300)
end
