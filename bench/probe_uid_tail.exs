# Investigation: why is indexed-`uid` point lookup slower + heavier-tailed than `@rid`?
# Fast-loads the graph, then characterises the full latency distribution (not just p50/p99)
# for three access patterns to separate a cache-miss tail from a structural one:
#   - uid COLD : a fresh random uid every call (cache-hostile, spread across buckets)
#   - uid WARM : rotate a small fixed set (hot cache)
#   - @rid WARM: rotate sampled @rids (direct record identity, the baseline)
#
#   ARCADIC_BENCH_URL=.. ARCADIC_BENCH_PASSWORD=.. ARCADIC_BENCH_NODES=100000 mix run bench/probe_uid_tail.exs

Code.require_file("support/bench_graph.exs", __DIR__)
alias Arcadic.Bench.Graph

cfg = Graph.config()
{conn, db} = Graph.setup(cfg)

pctl = fn sorted, p ->
  idx = min(length(sorted) - 1, trunc(p / 100 * length(sorted)))
  ms = Enum.at(sorted, idx) / 1000
  Float.round(ms, 2)
end

measure = fn label, n, next ->
  samples =
    for _ <- 1..n do
      arg = next.()
      {t, _} = :timer.tc(fn -> arg.() end)
      t
    end

  s = Enum.sort(samples)

  IO.puts(
    "  #{String.pad_trailing(label, 12)} n=#{n}  " <>
      "p50=#{pctl.(s, 50)}ms  p90=#{pctl.(s, 90)}ms  p99=#{pctl.(s, 99)}ms  " <>
      "p99.9=#{pctl.(s, 99.9)}ms  max=#{Float.round(List.last(s) / 1000, 2)}ms"
  )
end

try do
  {load_us, {n, e}} = :timer.tc(fn -> Graph.load(conn, cfg) end)
  secs = load_us / 1_000_000

  IO.puts("\n== FAST INGEST (#{cfg.ingest}) ==")

  IO.puts(
    "  #{Float.round(secs, 2)} s for #{n} nodes + #{e} edges " <>
      "(#{round(n / secs)} nodes/s, #{round(e / secs)} edges/s)"
  )

  IO.puts("\n== INDEX METADATA (Person.uid) ==")
  {:ok, idx} = Arcadic.query(conn, "SELECT FROM schema:indexes", %{}, language: "sql")

  idx
  |> Enum.map(&Map.drop(&1, ["@rid", "@type", "@cat"]))
  |> Enum.each(&IO.inspect(&1, label: "  index"))

  # sample real @rids to rotate over (avoid re-deriving them from uid)
  {:ok, rid_rows} =
    Arcadic.query(conn, "SELECT @rid AS rid FROM Person LIMIT 2000", %{}, language: "sql")

  rids = Enum.map(rid_rows, & &1["rid"])
  warm_uids = for _ <- 1..50, do: :rand.uniform(cfg.nodes) - 1

  IO.puts("\n== POINT-LOOKUP LATENCY DISTRIBUTION ==")

  # warm up the connection/JIT a touch before measuring
  for _ <- 1..200, do: Graph.lookup_by_uid(conn, :rand.uniform(cfg.nodes) - 1)

  measure.("uid COLD", 3000, fn ->
    u = :rand.uniform(cfg.nodes) - 1
    fn -> Graph.lookup_by_uid(conn, u) end
  end)

  measure.("uid WARM", 3000, fn ->
    u = Enum.random(warm_uids)
    fn -> Graph.lookup_by_uid(conn, u) end
  end)

  measure.("@rid WARM", 3000, fn ->
    r = Enum.random(rids)
    fn -> Graph.lookup_by_rid(conn, r) end
  end)
after
  Graph.teardown(conn, db)
  IO.puts("\n(dropped throwaway #{db})")
end
