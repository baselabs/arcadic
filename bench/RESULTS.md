# ArcadeDB benchmark results — 100k graph

Produced by `bench/run.exs` + `bench/probe_uid_tail.exs` (see [README.md](README.md)).
**ArcadeDB-only, single-node, no neo4j/AGE baseline** — a *profile*, not a comparison. Numbers
are ArcadeDB (the engine) reached over the arcadic HTTP driver; arcadic's own cost is µs-level
statement building.

## Reproduce

```bash
ARCADIC_BENCH_URL=<url> ARCADIC_BENCH_PASSWORD=<pw> \
ARCADIC_BENCH_NODES=100000 ARCADIC_BENCH_DEGREE=10 ARCADIC_BENCH_MAX_DEPTH=4 \
ARCADIC_BENCH_BATCH=1000 ARCADIC_BENCH_INGEST=rid \
mix run bench/run.exs
```

## Environment (2026-07-05)

| | |
|---|---|
| ArcadeDB | 26.8.1-SNAPSHOT |
| Transport | HTTP (`Arcadic.query`/`command`), arcadic 0.2.x |
| Server | Docker container, **2 GB memory limit**, JVM heap `-Xms2G -Xmx2G`, no CPU cap |
| Host | Apple M4 (10 cores), 16 GB, macOS 15.4.1 |
| Dataset | 100,000 `Person`, ~1,000,000 `KNOWS` (random, avg degree 10, rng-seed 42) |
| Method | localhost HTTP; single client (`PARALLEL=1`); Benchee 2 s warmup + 5 s/job, 50 rotating seeds |

## Ingest — client write path (not bulk-load)

| path | total | nodes/s | edges/s |
|---|---|---|---|
| `rid` (RID-addressed: multi-row INSERT + `CREATE EDGE FROM #rid TO #rid`) | **239 s** | 418 | **4,184** |
| `subquery` (naive `CREATE EDGE FROM (SELECT WHERE uid=..)`) | 539 s | 185 | 1,855 |

RID-addressing (no per-edge index lookup) is **~2.3× faster**, but *both* are dominated by
per-statement `CREATE EDGE` over HTTP — this is an **incremental client-write** rate, **not** a
bulk-load benchmark. For real bulk loading use ArcadeDB's index-deferred importer — see
[Bulk loading](#bulk-loading) below; it is far faster than any per-statement path.

## Traversal latency by depth (k-hop reachable-count, single client)

`SELECT count(*) FROM (TRAVERSE out('KNOWS') FROM <seed> MAXDEPTH d)`

| depth | avg fan-out | p50 | p99 | throughput |
|---|---|---|---|---|
| 1 | ~11 | 0.72 ms | 7.2 ms | 894 q/s |
| 2 | ~110 | 1.03 ms | 9.5 ms | 601 q/s |
| 3 | ~1,099 | 6.0 ms | 35.7 ms | 124 q/s |
| 4 | ~9,643 | 48.6 ms | 154 ms | 18 q/s |

Latency tracks the reachable set (~10× per hop in this degree-10 random graph). Depth-4 touches
~10% of the graph. The far tail is GC-sensitive (single 2 GB heap) — expect run-to-run variance
at depth 4; reproduce rather than cite absolute points.

## Point lookups (settled)

| query | p50 | p99 | throughput |
|---|---|---|---|
| by `@rid` (record identity) | 0.63 ms | 4.2 ms | 1,130 q/s |
| by indexed `uid` (UNIQUE `LSM_TREE`) | 0.59 ms | 5.0 ms | 1,070 q/s |

**On a settled index, `@rid` and indexed `uid` are within ~6%** — `@rid` holds a marginally
tighter far tail (no index pages), but the indexed lookup is not a bottleneck. See the tail
investigation for why an earlier cold run looked far worse.

## Tail investigation — the indexed-`uid` tail is *cold-state*, not structural

An early run measured indexed `uid` at **p99 57 ms, ~9.9× slower than `@rid`**. Chasing it
(`bench/probe_uid_tail.exs`):

- **Index:** `Person.uid` is a `LSM_TREE`, `UNIQUE`, **per-bucket** index (`Person[uid]` +
  per-bucket sub-indexes). No misconfiguration.
- **Warm vs cold (distribution over 3,000 lookups):** `uid` COLD (a fresh random uid each call,
  cache-hostile) p99 **6.4 ms** → `uid` WARM (hot working set) p99 **3.4 ms** — the tail roughly
  halves once the LSM index pages are cached. `@rid` WARM p99 2.7 ms (tightest).
- **Conclusion:** the 57 ms tail was **cold / unsettled** state — the early run measured lookups
  immediately after a 539 s naive bulk-ingest with the index still compacting under the 2 GB
  heap. Once settled (fast ingest + warmup), indexed `uid` ≈ `@rid` (above). Residual rare
  outliers (p99.9 ~20–32 ms, an occasional ~490 ms max) are consistent with JVM GC / LSM
  compaction pauses, not per-lookup index cost.
- **Takeaways:** give the index a warmup pass (or more heap) before latency-sensitive reads;
  prefer `@rid` when the access pattern can carry it, for the tightest tail — but don't avoid the
  `uid` index, it performs fine warm.

## Bulk loading

The ingest numbers above are per-statement *client writes*. For loading a large dataset, use
ArcadeDB's bulk facilities — **index-deferred** (indexes built after the load), far faster than
any `INSERT`/`CREATE EDGE` loop:

- **`IMPORT DATABASE '<url>'`** — a server-side import, **issuable directly through arcadic**:
  `Arcadic.command(conn, "IMPORT DATABASE 'https://…/data.csv'", %{}, language: "sql")`. ArcadeDB
  imports CSV / JSON / GraphML / GraphSON / RDF / Neo4j / OrientDB exports; the source URL must be
  reachable and permitted by the server. (Verified 2026-07-05: the command is recognized by the
  server via the HTTP command API.)
- **ArcadeDB Importer** (CLI / settings) for file-based pipelines with column mapping.
- For batched *incremental* writes through the driver, wrap them in `Arcadic.transaction/3` (one
  commit for many statements) rather than auto-committing each.

## Caveats

- Single-node, 2 GB-capped container, **localhost** HTTP (no network latency, no replication).
- Synthetic uniform-random graph; real workloads (skewed degree, communities) differ.
- Single-client (`PARALLEL=1`); set `ARCADIC_BENCH_PARALLEL=N` for throughput under load.
- **No baseline.** A "neo4j replacement" claim needs neo4j and/or Apache AGE on this exact
  generator + hardware. See README "next steps".
