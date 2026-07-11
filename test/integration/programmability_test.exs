defmodule Arcadic.Integration.ProgrammabilityTest do
  @moduledoc """
  Live S11 DDL proofs against the running `qor-arcadedb` container — the first
  exercise of `Arcadic.Geo`/`Function`/`Trigger`/`MaterializedView` against real
  ArcadeDB (unit tests stub the wire).

  Substrate facts verified live 2026-07-11 (ArcadeDB 26.8.1-SNAPSHOT) while
  writing these tests:

    * GEOSPATIAL indexes are created on a **STRING property holding WKT** (there
      is no `POINT` schema type here; `ST_*` functions are absent). The index
      retro-indexes existing rows. `distance(point(x,y), point(x,y))` returns a
      great-circle distance in metres; `distance(<wkt-column>, point(...))` works.
    * `DEFINE FUNCTION lib.fn "body" PARAMETERS [..] LANGUAGE js` compiles the JS
      body at define time; a broken body is a `FunctionExecutionException`.
    * `DROP TRIGGER name` / `DROP MATERIALIZED VIEW name` take NO `ON type` /
      `IF EXISTS` clause (matching the module's emitted SQL).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Conn, Function, Geo, MaterializedView, Server, Trigger}

  setup_all do
    url = System.get_env("ARCADIC_TEST_URL") || flunk("set ARCADIC_TEST_URL")
    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    db = "progr_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, db, auth: {"root", pass})
    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)
    {:ok, conn: conn}
  end

  test "Geo: a GEOSPATIAL index retro-indexes a WKT row + a distance(point,point) query", %{
    conn: conn
  } do
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE Loc", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY Loc.wkt STRING", %{}, language: "sql")
    Arcadic.command!(conn, "INSERT INTO Loc SET wkt = 'POINT (1 1)'", %{}, language: "sql")

    # Retro-index the pre-existing WKT row (the index build indexes the row that is
    # already there — a create-then-index ordering the unit tests can't prove).
    assert :ok = Geo.create_index(conn, "Loc", "wkt")

    # distance(point, point) returns a number (great-circle metres between (0,0) and (3,4)).
    assert {:ok, [%{"d" => d}]} =
             Arcadic.query(conn, "SELECT distance(point(0.0, 0.0), point(3.0, 4.0)) AS d", %{},
               language: "sql"
             )

    assert is_number(d) and d > 0

    # The indexed WKT row's self-distance is 0.0 — proves the stored "POINT (1 1)" round-tripped
    # through the geo parser (the index really covers a geometry, not opaque text).
    assert {:ok, [%{"d" => self_d}]} =
             Arcadic.query(conn, "SELECT distance(wkt, point(1.0, 1.0)) AS d FROM Loc", %{},
               language: "sql"
             )

    assert self_d == 0.0

    assert :ok = Geo.drop_index(conn, "Loc", "wkt")
  end

  test "Function: define + call; a \"-body rejects pre-wire; a ;DROP body does not break out", %{
    conn: conn
  } do
    lib = "it_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    # Single-quoted, single-line JS body with PARAMETERS; callable via the backtick idiom.
    assert :ok =
             Function.define(conn, "#{lib}.add", "return a + b", params: [:a, :b], language: :js)

    assert {:ok, [%{"total" => 3}]} =
             Arcadic.query(conn, "SELECT `#{lib}.add`(:a, :b) AS total", %{"a" => 1, "b" => 2},
               language: "sql"
             )

    # A body carrying the sole breakout byte (") is rejected VALUE-FREE by the client's
    # reject-not-escape guard BEFORE any wire call — the bare `:unencodable_body` atom (never an
    # %Arcadic.Error{} from the server) is the proof this never reached ArcadeDB.
    assert {:error, :unencodable_body} = Function.define(conn, "#{lib}.q", "return \"x\"")

    # A ;DROP body is NON-breakout: the `;` sits inside the "..." DDL literal, so it cannot
    # terminate the DEFINE and start a second DROP statement. ArcadeDB rejects it as invalid JS at
    # define time (a function-definition error, not a parse-split), and the Victim type survives.
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE Victim", %{}, language: "sql")

    assert {:error, %Arcadic.Error{}} = Function.define(conn, "#{lib}.evil", ";DROP TYPE Victim")

    assert {:ok, [%{"c" => 1}]} =
             Arcadic.query(
               conn,
               "SELECT count(*) AS c FROM schema:types WHERE name = 'Victim'",
               %{},
               language: "sql"
             )

    assert :ok = Function.delete(conn, "#{lib}.add")
  end

  test "Trigger: create + drop (DROP TRIGGER takes no ON/IF EXISTS clause)", %{conn: conn} do
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE Audited", %{}, language: "sql")
    tg = "tg_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    assert :ok =
             Trigger.create(conn, tg, "Audited",
               timing: :before,
               event: :create,
               execute: {:sql, "return"}
             )

    assert :ok = Trigger.drop(conn, tg)
  end

  test "MaterializedView: create + drop (DROP MATERIALIZED VIEW takes no IF EXISTS clause)", %{
    conn: conn
  } do
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE Src", %{}, language: "sql")
    Arcadic.command!(conn, "INSERT INTO Src SET n = 1", %{}, language: "sql")
    mv = "mv_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    assert :ok = MaterializedView.create(conn, mv, "SELECT FROM Src")
    assert :ok = MaterializedView.drop(conn, mv)
  end

  test "MaterializedView: a ;DROP embedded in the SELECT is non-breakout (single-statement backstop)",
       %{conn: conn} do
    # The MV SELECT is raw trailing SQL (deliberately NOT char-restricted); its ONLY injection
    # defense is ArcadeDB's live-verified single-statement backstop — a `;`-separated second
    # statement parse-errors the whole command. This exercises that backstop red-capably: if
    # `/command` ever accepted the second statement, MvVictim would be dropped and this goes RED.
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE Src2", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE DOCUMENT TYPE MvVictim", %{}, language: "sql")

    assert {:error, %Arcadic.Error{}} =
             MaterializedView.create(conn, "mvevil", "SELECT FROM Src2; DROP TYPE MvVictim")

    assert {:ok, [%{"c" => 1}]} =
             Arcadic.query(
               conn,
               "SELECT count(*) AS c FROM schema:types WHERE name = 'MvVictim'",
               %{},
               language: "sql"
             )
  end
end
