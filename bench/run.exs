# ArcadeDB benchmark scaffold — run with:
#
#   ARCADIC_BENCH_URL=http://127.0.0.1:2480 ARCADIC_BENCH_PASSWORD=... mix run bench/run.exs
#
# Knobs (env): ARCADIC_BENCH_{NODES,DEGREE,MAX_DEPTH,BATCH,SEEDS,PARALLEL,TIME,SEED}
# See bench/README.md for methodology + honesty caveats. ArcadeDB-only (no neo4j baseline).

Code.require_file("support/bench_graph.exs", __DIR__)
alias Arcadic.Bench.Graph

cfg = Graph.config()
{conn, db} = Graph.setup(cfg)

try do
  Graph.print_header(cfg, db)

  # 1) INGEST — one-shot bulk load, wall-clock timed (not a Benchee repeatable op).
  {load_us, {nodes, edges}} = :timer.tc(fn -> Graph.load(conn, cfg) end)
  Graph.report_ingest(load_us, nodes, edges)

  seeds = Graph.seed_uids(cfg)
  rids = Graph.sample_rids(conn, cfg)

  # Shape metric: how many nodes each depth actually reaches (publish beside latency).
  Graph.report_fanout(Graph.fanout_profile(conn, cfg, seeds))

  # 2) TRAVERSAL — k-hop latency by depth (the neo4j-vs-X differentiator).
  IO.puts(" TRAVERSAL LATENCY by depth\n")

  for(
    d <- 1..cfg.max_depth,
    into: %{},
    do: {"k-hop depth=#{d}", fn -> Graph.khop(conn, Enum.random(seeds), d) end}
  )
  |> Benchee.run(
    warmup: 2,
    time: cfg.time,
    parallel: cfg.parallel,
    print: [configuration: false],
    percentiles: [50, 95, 99]
  )

  # 3) POINT LOOKUPS — indexed property vs @rid identity.
  IO.puts("\n POINT LOOKUPS\n")

  %{
    "lookup by indexed uid" => fn -> Graph.lookup_by_uid(conn, Enum.random(seeds)) end,
    "lookup by @rid" => fn -> Graph.lookup_by_rid(conn, Enum.random(rids)) end
  }
  |> Benchee.run(
    warmup: 2,
    time: cfg.time,
    parallel: cfg.parallel,
    print: [configuration: false],
    percentiles: [50, 95, 99]
  )
after
  Graph.teardown(conn, db)
  IO.puts("\n(dropped throwaway #{db})")
end
