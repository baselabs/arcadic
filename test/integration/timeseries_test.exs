defmodule Arcadic.Integration.TimeSeriesTest do
  use ExUnit.Case, async: false
  @moduletag :integration_ts

  alias Arcadic.{Conn, Server, TimeSeries}

  # Java Long.MAX_VALUE — the line-protocol `…i` int64 boundary (pinned live probe: the
  # T4 builder emits bignums unbounded and the server silently skips unparseable lines).
  @int64_max 9_223_372_036_854_775_807

  # Requires ArcadeDB >= 26.7.2 (the /api/v1/ts routes). Deliberately NO skip-on-404: with the
  # env set, an absent /ts surface FAILS the suite loudly (a skip would be a vacuous gate).
  setup_all do
    url =
      System.get_env("ARCADIC_TS_TEST_URL") ||
        flunk("set ARCADIC_TS_TEST_URL (ArcadeDB >= 26.7.2)")

    pass = System.get_env("ARCADIC_TS_TEST_PASSWORD") || flunk("set ARCADIC_TS_TEST_PASSWORD")
    db = "ts_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, db, auth: {"root", pass})
    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)
    on_exit(fn -> Server.drop_database(conn, db) end)

    # `big` (LONG) carries the int64-boundary round-trip probe — INTEGER (`n`) is 32-bit,
    # so the boundary needs a 64-bit column to be a fair conformance question.
    :ok =
      TimeSeries.create_type!(conn, "cpu", "ts",
        fields: [usage: "DOUBLE", n: "INTEGER", msg: "STRING", ok: "BOOLEAN", big: "LONG"],
        tags: [host: "STRING", region: "STRING"],
        # :millisecond here vs :ms on write/3 is NOT an alias choice — the lib has two distinct
        # precision grammars (DDL @ddl_precisions vs the wire's @precisions); each side takes
        # only its own tokens.
        precision: :millisecond,
        shards: 2,
        retention: {90, :days},
        compaction_interval: {1, :hours}
      )

    {:ok, conn: conn, db: db}
  end

  defp now_ms, do: System.system_time(:millisecond)

  test "write -> query -> latest round-trip with typed fields and escaped values", %{conn: conn} do
    # 24 h back: inside retention, disjoint from every other test's ~now write window, so the
    # unfiltered count below cannot see their "cpu" points regardless of ExUnit seed order.
    t0 = now_ms() - 86_400_000

    # Pinned live probes riding this round-trip (T4 builder conformance):
    #   (a) e-notation float — to_string(-0.00005) emits "-5.0e-5"; a server that rejects it
    #       silently DROPS the line (count: 2 below reds → the T4 builder needs decimal
    #       normalization; surface, don't paper over).
    #   (b) int64 boundary — `#{@int64_max}i` into the LONG column; value asserted back EXACT.
    :ok =
      TimeSeries.write(
        conn,
        [
          %{
            type: "cpu",
            tags: %{"host" => "srv1", "region" => "us"},
            fields: %{
              "usage" => 12.5,
              "n" => 42,
              "msg" => ~S(quote " and \ slash),
              "ok" => true,
              "big" => @int64_max
            },
            timestamp: t0 - 60_000
          },
          %{
            type: "cpu",
            tags: %{"host" => "my srv,prod", "region" => "eu"},
            fields: %{
              "usage" => -0.00005,
              "n" => 7,
              "msg" => "plain",
              "ok" => false,
              "big" => 1
            },
            timestamp: t0
          }
        ],
        precision: :ms
      )

    assert {:ok, %{columns: columns, rows: rows, count: 2}} =
             TimeSeries.query(conn, "cpu", from: t0 - 3_600_000, to: t0 + 3_600_000)

    assert "usage" in columns and "host" in columns

    # Named-field asserts via column↔value zip: flat membership would be blind to the
    # misalignment defect class this server already exhibits on fields-projection, so every
    # value is asserted BY NAME against its column.
    assert Enum.all?(rows, &(length(&1) == length(columns)))
    row_maps = Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)

    srv1 = Enum.find(row_maps, &(&1["host"] == "srv1"))
    assert srv1, "no row with host=srv1"
    # Escaping round-trip: the quoted/escaped string field comes back EXACT.
    assert srv1["msg"] == ~S(quote " and \ slash)
    assert srv1["usage"] == 12.5
    assert srv1["n"] == 42
    assert srv1["ok"] == true
    # Probe (b): the int64 boundary round-trips exactly (a float-serialized long would corrupt).
    assert srv1["big"] == @int64_max

    # Escaping round-trip: the space/comma-bearing tag value comes back EXACT.
    other = Enum.find(row_maps, &(&1["host"] == "my srv,prod"))
    assert other, "no row with the escaped tag value host=my srv,prod"
    assert other["region"] == "eu"
    # Probe (a): the e-notation double round-trips as the same float.
    assert other["usage"] == -0.00005
    assert other["ok"] == false

    # tags-map AND semantics (probed contract): both tags must match.
    assert {:ok, %{count: 1}} =
             TimeSeries.query(conn, "cpu",
               from: t0 - 3_600_000,
               to: t0 + 3_600_000,
               tags: %{"host" => "srv1", "region" => "us"}
             )

    # Single-tag latest.
    assert {:ok, %{columns: lcols, latest: latest}} =
             TimeSeries.latest(conn, "cpu", tag: {"host", "srv1"})

    assert length(lcols) == length(latest)
    assert 12.5 in latest
  end

  test "aggregated query buckets an AVG", %{conn: conn} do
    # Bucket-interior pin: both points land mid-hour, so t0 - 1_000 cannot straddle an
    # hourly bucket boundary (the ~0.03% flake window).
    t0 = div(now_ms(), 3_600_000) * 3_600_000 + 1_800_000

    :ok =
      TimeSeries.write(
        conn,
        [
          %{
            type: "cpu",
            tags: %{"host" => "agg", "region" => "x"},
            fields: %{"usage" => 10.0, "n" => 1, "msg" => "a", "ok" => true},
            timestamp: t0 - 1_000
          },
          %{
            type: "cpu",
            tags: %{"host" => "agg", "region" => "x"},
            fields: %{"usage" => 20.0, "n" => 1, "msg" => "b", "ok" => true},
            timestamp: t0
          }
        ],
        precision: :ms
      )

    assert {:ok, %{aggregations: ["usage_avg"], buckets: buckets, count: count}} =
             TimeSeries.query(conn, "cpu",
               from: t0 - 3_600_000,
               to: t0 + 3_600_000,
               tags: %{"host" => "agg"},
               aggregation: [%{field: "usage", type: :avg}],
               bucket_interval: {1, :hours}
             )

    assert count >= 1
    # match?/2 keeps the predicate total: a bucket-shape change fails this assert readably
    # instead of FunctionClauseError-ing inside the anonymous function.
    assert Enum.any?(buckets, &match?(%{values: [15.0]}, &1))

    # Pinned live probe (c): an UN-ALIASED two-request aggregation on ONE field — the server's
    # default output names must incorporate the type (field_type). assert_unique_outputs! keys
    # on `alias || {field, type}` on exactly this assumption; a field-only default name would
    # mean that check must tighten to `alias || field` (surface as a finding).
    assert {:ok, %{aggregations: aggs, buckets: [_ | _]}} =
             TimeSeries.query(conn, "cpu",
               from: t0 - 3_600_000,
               to: t0 + 3_600_000,
               tags: %{"host" => "agg"},
               aggregation: [%{field: "usage", type: :avg}, %{field: "usage", type: :max}],
               bucket_interval: {1, :hours}
             )

    assert Enum.sort(aggs) == ["usage_avg", "usage_max"]
  end

  test "append-only: the identical point written twice is TWO rows (naive retry duplicates)",
       %{conn: conn} do
    t0 = now_ms()

    point = %{
      type: "cpu",
      tags: %{"host" => "dup", "region" => "x"},
      fields: %{"usage" => 1.0, "n" => 1, "msg" => "d", "ok" => true},
      timestamp: t0
    }

    :ok = TimeSeries.write(conn, [point], precision: :ms)
    :ok = TimeSeries.write(conn, [point], precision: :ms)

    assert {:ok, %{count: 2}} =
             TimeSeries.query(conn, "cpu",
               from: t0 - 1_000,
               to: t0 + 1_000,
               tags: %{"host" => "dup"}
             )
  end

  # CHARACTERIZATION (shape-only — documents the substrate's silent-swallow class, probed
  # 2026-07-11 on 26.7.2; see docs/superpowers/external/arcadedb-ts-docs-divergence.md).
  # Assertions pin the RESPONSE SHAPE arcadic must tolerate, never the buggy values: a
  # value-correcting upstream fix does not red this suite; a reject-style fix (e.g. the server
  # starts 400-ing swallowed lines) WILL red it, deliberately — that contract change must be
  # seen, not absorbed.
  test "mixed-body write with an unknown type returns :ok and silently drops that line",
       %{conn: conn} do
    t0 = now_ms()

    # write_lines (raw) carries the mixed body; the KNOWN line lands, the unknown-type line vanishes.
    :ok =
      TimeSeries.write_lines(
        conn,
        "cpu,host=mix,region=x usage=1.0,n=1i,msg=\"m\",ok=true #{t0}\nnosuchtype v=1.0 #{t0}",
        precision: :ms
      )

    assert {:ok, %{count: 1}} =
             TimeSeries.query(conn, "cpu",
               from: t0 - 1_000,
               to: t0 + 1_000,
               tags: %{"host" => "mix"}
             )

    # The dropped type never materializes.
    assert {:error, _} = TimeSeries.query(conn, "nosuchtype", from: t0 - 1_000, to: t0 + 1_000)
  end

  test "unknown FIELD writes a zero-filled row (shape-only characterization)", %{conn: conn} do
    t0 = now_ms()

    :ok =
      TimeSeries.write_lines(conn, "cpu,host=zf,region=x nosuchfield=9.9 #{t0}", precision: :ms)

    assert {:ok, %{count: 1, columns: cols, rows: [row]}} =
             TimeSeries.query(conn, "cpu",
               from: t0 - 1_000,
               to: t0 + 1_000,
               tags: %{"host" => "zf"}
             )

    # Shape only: the row EXISTS (the zero-fill defect) at full column width; no assertion
    # on the zeroed values.
    assert length(row) == length(cols)
  end

  test "fields projection answers 200 (shape-only — server-side projection defect)", %{conn: conn} do
    t0 = now_ms()

    :ok =
      TimeSeries.write(
        conn,
        [
          %{
            type: "cpu",
            tags: %{"host" => "proj", "region" => "x"},
            fields: %{"usage" => 5.0, "n" => 1, "msg" => "p", "ok" => true},
            timestamp: t0
          }
        ],
        precision: :ms
      )

    # 26.7.2 returns misaligned values under a wrong-width header for a fields projection
    # (probed; external issue draft). Pin only that the call SUCCEEDS with a columns list —
    # value assertions land when upstream fixes.
    assert {:ok, %{columns: cols}} =
             TimeSeries.query(conn, "cpu",
               from: t0 - 1_000,
               to: t0 + 1_000,
               fields: ["usage"],
               tags: %{"host" => "proj"}
             )

    assert is_list(cols)
  end

  test "PromQL family: instant, range, labels, label values, series", %{conn: conn} do
    t0 = now_ms()

    :ok =
      TimeSeries.write(
        conn,
        [
          %{
            type: "cpu",
            tags: %{"host" => "prom", "region" => "x"},
            fields: %{"usage" => 3.0, "n" => 1, "msg" => "q", "ok" => true},
            timestamp: t0
          }
        ],
        precision: :ms
      )

    # +1: div/2 FLOORS, putting the eval instant up to 999 ms BEFORE the ms-timestamped sample,
    # and Prometheus instant-query semantics exclude samples after the eval time (probed live:
    # eval at floor(s) -> empty vector; eval at floor(s)+1 -> the sample returns).
    now_s = div(t0, 1000) + 1

    assert {:ok, %{"resultType" => "vector", "result" => result}} =
             TimeSeries.prom_query(conn, ~S(cpu{host="prom"}), time: now_s)

    assert [%{"metric" => %{"__name__" => "cpu", "host" => "prom"}, "value" => [_, _]} | _] =
             result

    assert {:ok, %{"resultType" => "matrix", "result" => [_ | _]}} =
             TimeSeries.prom_query_range(conn, ~S(cpu{host="prom"}), now_s - 3600, now_s + 60, 60)

    assert {:ok, labels} = TimeSeries.prom_labels(conn)
    assert "host" in labels

    assert {:ok, names} = TimeSeries.prom_label_values(conn, "__name__")
    assert "cpu" in names

    assert {:ok, series} = TimeSeries.prom_series(conn, ["cpu"])
    assert Enum.any?(series, &(&1["__name__"] == "cpu"))
  end

  test "downsampling policy add/drop and continuous aggregate lifecycle", %{conn: conn} do
    assert :ok =
             TimeSeries.add_downsampling(conn, "cpu",
               after: {7, :days},
               granularity: {1, :hours}
             )

    assert :ok = TimeSeries.drop_downsampling(conn, "cpu")

    t0 = now_ms()

    :ok =
      TimeSeries.write(
        conn,
        [
          %{
            type: "cpu",
            tags: %{"host" => "ca", "region" => "x"},
            fields: %{"usage" => 8.0, "n" => 1, "msg" => "c", "ok" => true},
            timestamp: t0
          }
        ],
        precision: :ms
      )

    assert :ok =
             TimeSeries.create_aggregate(
               conn,
               "hourly_cpu",
               "SELECT ts.timeBucket('1h', ts) AS hour, host, avg(usage) AS avg_usage " <>
                 "FROM cpu GROUP BY hour, host"
             )

    assert :ok = TimeSeries.refresh_aggregate(conn, "hourly_cpu")

    # The CA materializes as a document type readable through the normal query surface.
    assert {:ok, rows} = Arcadic.query(conn, "SELECT FROM hourly_cpu", %{}, language: "sql")
    assert Enum.any?(rows, &(&1["host"] == "ca"))

    assert :ok = TimeSeries.drop_aggregate(conn, "hourly_cpu")
  end

  test "DDL lifecycle: a second type creates, introspects via schema:types, drops", %{conn: conn} do
    assert :ok = TimeSeries.create_type!(conn, "ev2", "t", fields: [v: "DOUBLE"])

    assert {:ok, types} = Arcadic.Schema.types(conn)
    assert Enum.any?(types, &(&1["name"] == "ev2"))

    assert :ok = TimeSeries.drop_type(conn, "ev2")
  end
end
