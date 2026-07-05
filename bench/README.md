# arcadic benchmarks (ArcadeDB-only)

A scaffold for load-profiling ArcadeDB **through the arcadic driver**. Not shipped in the
hex package (excluded by `mix.exs` `package.files`). No neo4j baseline yet — this measures
one engine, single-node.

## Run

```bash
# defaults: 5,000 nodes, degree 10, depths 1..4
ARCADIC_BENCH_URL=http://127.0.0.1:2480 ARCADIC_BENCH_PASSWORD=<root-pw> mix run bench/run.exs
```

Knobs (env vars):

| var | default | meaning |
|-----|---------|---------|
| `ARCADIC_BENCH_URL` | `http://127.0.0.1:2480` | ArcadeDB HTTP endpoint |
| `ARCADIC_BENCH_PASSWORD` | *(required)* | `root` password |
| `ARCADIC_BENCH_NODES` | `5000` | Person vertices |
| `ARCADIC_BENCH_DEGREE` | `10` | avg out-degree (edges = nodes × degree) |
| `ARCADIC_BENCH_MAX_DEPTH` | `4` | max k-hop traversal depth |
| `ARCADIC_BENCH_INGEST` | `rid` | `rid` = @rid-addressed bulk write; `subquery` = naive uid-lookup `CREATE EDGE` |
| `ARCADIC_BENCH_BATCH` | `500` | statements per `sqlscript` ingest request |
| `ARCADIC_BENCH_SEEDS` | `50` | random seed nodes the timed queries rotate over |
| `ARCADIC_BENCH_PARALLEL` | `1` | concurrent Benchee workers per job (the "load" dimension) |
| `ARCADIC_BENCH_TIME` | `5` | seconds per Benchee job |
| `ARCADIC_BENCH_SEED` | `42` | RNG seed (reproducible graph) |

Every run uses a throwaway `bench_<rand>` DB, dropped on exit. It **never** touches a
pre-existing database.

## What it measures

1. **Ingest throughput** — wall-clock to load N nodes + N×degree edges; reports nodes/sec +
   edges/sec. `rid` mode (default) captures each vertex's `@rid` and creates edges by identity;
   `subquery` mode is the naive uid-lookup path. Both are per-statement *client writes*, not a
   bulk-load — for real bulk loading see [Bulk loading](RESULTS.md#bulk-loading) in RESULTS.md.
2. **k-hop traversal latency by depth** — `SELECT count(*) FROM (TRAVERSE out('KNOWS') …
   MAXDEPTH d)` from random seeds, depths 1..max; Benchee p50/p95/p99. Plus an average
   **fan-out per depth** shape metric.
3. **Point lookups** — by indexed `uid` vs by `@rid`; p50/p95/p99.
4. **Concurrency** — set `ARCADIC_BENCH_PARALLEL=N` to run each job under N concurrent
   workers (throughput under load).

## Honesty caveats (read before publishing anything)

- **These are ArcadeDB engine + HTTP round-trip numbers, reached through arcadic.** arcadic's
  own cost is µs-level statement building — do not label these "arcadic benchmarks" without
  that framing. Ingest folds in batched-HTTP + server write; it is not a pure engine ingest rate.
- **Single-node, synthetic random graph.** Real workloads (skewed degree, community structure,
  larger scale) will differ. Record the printed environment header (ArcadeDB version, dataset,
  hardware) with every number, or it's not reproducible.
- **No baseline = a profile, not a comparison.** A "neo4j replacement" claim needs neo4j (and/or
  AGE) run on the *same* dataset + hardware.

## Documented next steps (not in this scaffold)

- neo4j / Apache-AGE baselines on the same generator for a real comparison.
- LDBC SNB / Graphalytics datasets + workloads for standardized, citable numbers.
- ANN recall@k-vs-latency for the `Arcadic.Vector` `LSM_VECTOR` path (vector-specific).
- Bolt-vs-HTTP transport comparison (arcadic supports both).
