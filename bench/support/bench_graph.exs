defmodule Arcadic.Bench.Graph do
  @moduledoc """
  Shared harness for the ArcadeDB benchmark scaffold.

  ArcadeDB-ONLY (no neo4j baseline yet). Everything runs against a **throwaway**
  database named `bench_<rand>`, created at start and dropped on exit — this harness
  NEVER touches a pre-existing database. It generates a synthetic `Person`/`KNOWS`
  graph (LDBC-SNB-flavoured social shape) and exposes the query builders the bench
  scripts time. Values are synthetic (integer `uid`s + generated names), so ingest
  statements interpolate them directly for batch throughput — this is bench-only code,
  not the library's params-only path.

  Honest scope: these numbers characterise **ArcadeDB (the engine) reached over the
  arcadic HTTP driver** — ingest throughput folds in batched-HTTP + server write; k-hop
  latency folds in the round-trip + the engine's traversal. arcadic's own cost is
  µs-level statement building. Record the printed environment header with any results.
  """
  alias Arcadic.{Conn, Server}

  # --- config (env-driven; sensible small-ish defaults so a first run finishes fast) ---

  def config do
    %{
      url: System.get_env("ARCADIC_BENCH_URL", "http://127.0.0.1:2480"),
      password: System.get_env("ARCADIC_BENCH_PASSWORD") || raise("set ARCADIC_BENCH_PASSWORD"),
      nodes: env_int("ARCADIC_BENCH_NODES", 5_000),
      degree: env_int("ARCADIC_BENCH_DEGREE", 10),
      max_depth: env_int("ARCADIC_BENCH_MAX_DEPTH", 4),
      batch: env_int("ARCADIC_BENCH_BATCH", 500),
      seeds: env_int("ARCADIC_BENCH_SEEDS", 50),
      parallel: env_int("ARCADIC_BENCH_PARALLEL", 1),
      time: env_int("ARCADIC_BENCH_TIME", 5),
      seed: env_int("ARCADIC_BENCH_SEED", 42)
    }
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      val -> String.to_integer(val)
    end
  end

  # --- lifecycle (throwaway DB; never a pre-existing one) ---

  def setup(cfg) do
    db = "bench_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(cfg.url, db, auth: {"root", cfg.password})
    _ = Server.drop_database(conn, db)
    :ok = Server.create_database!(conn, db)

    Arcadic.command!(conn, "CREATE VERTEX TYPE Person", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE PROPERTY Person.uid INTEGER", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE INDEX ON Person (uid) UNIQUE", %{}, language: "sql")
    Arcadic.command!(conn, "CREATE EDGE TYPE KNOWS", %{}, language: "sql")

    {conn, db}
  end

  def teardown(conn, db), do: Server.drop_database(conn, db)

  # --- synthetic load (one-shot, timed by the caller) ---

  @doc "Loads `nodes` Person vertices + `nodes * degree` random KNOWS edges. Returns {node_count, edge_count}."
  def load(conn, cfg) do
    :rand.seed(:exsss, {cfg.seed, cfg.seed, cfg.seed})
    load_persons(conn, cfg)
    edge_count = load_edges(conn, cfg)
    {cfg.nodes, edge_count}
  end

  defp load_persons(conn, cfg) do
    0..(cfg.nodes - 1)
    |> Enum.chunk_every(cfg.batch)
    |> Enum.each(fn chunk ->
      script =
        Enum.map_join(chunk, ";\n", fn uid ->
          "INSERT INTO Person SET uid = #{uid}, name = 'p_#{uid}'"
        end)

      Arcadic.command!(conn, script, %{}, language: "sqlscript")
    end)
  end

  defp load_edges(conn, cfg) do
    edges =
      for uid <- 0..(cfg.nodes - 1), _ <- 1..cfg.degree do
        {uid, :rand.uniform(cfg.nodes) - 1}
      end

    edges
    |> Enum.chunk_every(cfg.batch)
    |> Enum.each(fn chunk ->
      script =
        Enum.map_join(chunk, ";\n", fn {a, b} ->
          "CREATE EDGE KNOWS " <>
            "FROM (SELECT FROM Person WHERE uid = #{a}) TO (SELECT FROM Person WHERE uid = #{b})"
        end)

      Arcadic.command!(conn, script, %{}, language: "sqlscript")
    end)

    length(edges)
  end

  # --- the timed queries ---

  @doc "k-hop reachable-node count from a seed uid (SQL TRAVERSE, MAXDEPTH bound)."
  def khop(conn, seed_uid, depth) do
    sql =
      "SELECT count(*) AS reached FROM " <>
        "(TRAVERSE out('KNOWS') FROM (SELECT FROM Person WHERE uid = :s) MAXDEPTH #{depth})"

    {:ok, rows} = Arcadic.query(conn, sql, %{"s" => seed_uid}, language: "sql")
    rows |> List.first(%{}) |> Map.get("reached", 0)
  end

  @doc "Point lookup by the indexed `uid` property."
  def lookup_by_uid(conn, uid) do
    Arcadic.query(conn, "SELECT FROM Person WHERE uid = :u", %{"u" => uid}, language: "sql")
  end

  @doc "Point lookup by @rid (record identity)."
  def lookup_by_rid(conn, rid) do
    Arcadic.query(conn, "SELECT FROM #{rid}", %{}, language: "sql")
  end

  # --- sampling helpers (rotate over a seed set so a bench isn't hammering one hot node) ---

  def seed_uids(cfg), do: for(_ <- 1..cfg.seeds, do: :rand.uniform(cfg.nodes) - 1)

  def sample_rids(conn, cfg) do
    {:ok, rows} =
      Arcadic.query(conn, "SELECT @rid AS rid FROM Person LIMIT #{cfg.seeds}", %{},
        language: "sql"
      )

    Enum.map(rows, & &1["rid"])
  end

  @doc "Average fan-out (reachable nodes) per depth — a shape metric to publish alongside latency."
  def fanout_profile(conn, cfg, seeds) do
    for depth <- 1..cfg.max_depth do
      counts = Enum.map(seeds, &khop(conn, &1, depth))
      {depth, div(Enum.sum(counts), max(length(counts), 1))}
    end
  end

  # --- environment header (attribution — print this with any published number) ---

  def print_header(cfg, db) do
    version =
      case Req.get(cfg.url <> "/api/v1/databases", auth: {:basic, "root:" <> cfg.password}) do
        {:ok, %{body: %{"version" => v}}} -> v
        _ -> "unknown"
      end

    IO.puts("""

    ==============================================================================
     arcadic graph benchmark -- ArcadeDB only (no neo4j baseline)
    ------------------------------------------------------------------------------
     ArcadeDB   : #{version}
     Endpoint   : #{cfg.url}   (HTTP, arcadic driver)
     Throwaway  : #{db}
     Dataset    : #{cfg.nodes} Person, ~#{cfg.nodes * cfg.degree} KNOWS (degree #{cfg.degree}), rng-seed #{cfg.seed}
     Depths     : 1..#{cfg.max_depth}   Seeds: #{cfg.seeds}   Parallel: #{cfg.parallel}   Time/job: #{cfg.time}s
     Host       : <RECORD YOUR HARDWARE HERE> -- single-node; engine+round-trip, not a comparison
    ==============================================================================
    """)
  end

  def report_ingest(load_us, nodes, edges) do
    secs = load_us / 1_000_000

    IO.puts("""
     INGEST (batched sqlscript over HTTP)
       total          : #{Float.round(secs, 3)} s  for #{nodes} nodes + #{edges} edges
       nodes/sec      : #{round(nodes / secs)}
       edges/sec      : #{round(edges / secs)}
       (folds in batched-HTTP round-trips + server write; not a pure engine ingest number)
    """)
  end

  def report_fanout(profile) do
    IO.puts(" TRAVERSAL FAN-OUT (avg reachable nodes per depth)")
    Enum.each(profile, fn {d, avg} -> IO.puts("   depth #{d} : ~#{avg} nodes") end)
    IO.puts("")
  end
end
