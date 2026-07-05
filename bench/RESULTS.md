# ArcadeDB benchmark results — 100k graph

Produced by `bench/run.exs` (see [README.md](README.md)). **ArcadeDB-only, single-node, no
neo4j/AGE baseline** — this is a *profile*, not a comparison. Numbers are ArcadeDB (the engine)
reached over the arcadic HTTP driver; arcadic's own cost is µs-level statement building.

## Reproduce

```bash
ARCADIC_BENCH_URL=<url> ARCADIC_BENCH_PASSWORD=<pw> \
ARCADIC_BENCH_NODES=100000 ARCADIC_BENCH_DEGREE=10 ARCADIC_BENCH_MAX_DEPTH=4 \
ARCADIC_BENCH_BATCH=1000 ARCADIC_BENCH_SEEDS=50 ARCADIC_BENCH_TIME=5 \
mix run bench/run.exs
```

## Environment (2026-07-05)

| | |
|---|---|
| ArcadeDB | 26.8.1-SNAPSHOT |
| Transport | HTTP (`Arcadic.query`/`command`), arcadic 0.2.0 |
| Server | Docker container, **2 GB memory limit**, JVM heap `-Xms2G -Xmx2G`, no CPU cap |
| Host | Apple M4 (10 cores), 16 GB, macOS 15.4.1 |
| Dataset | 100,000 `Person` vertices, ~1,000,000 `KNOWS` edges (random, avg degree 10, rng-seed 42) |
| Method | localhost HTTP; single client (`PARALLEL=1`); Benchee 2 s warmup + 5 s/job, 50 rotating seed nodes |

## Ingest

| metric | value |
|---|---|
| total load | **539.1 s** (100k nodes + 1M edges) |
| nodes/sec | 185 |
| edges/sec | 1,855 |

⚠️ **This is not ArcadeDB's max ingest rate.** It is dominated by the harness's edge-creation
pattern — `CREATE EDGE … FROM (SELECT … WHERE uid=a) TO (SELECT … WHERE uid=b)` does two indexed
lookups per edge, batched 1,000/`sqlscript` over HTTP. A bulk-import path (ArcadeDB's importer,
or RID-addressed edge creation) would be far faster. Treat this as a *client-driven incremental
write* number, not a bulk-load benchmark.

## Traversal latency by depth (k-hop reachable-count)

`SELECT count(*) FROM (TRAVERSE out('KNOWS') FROM <seed> MAXDEPTH d)` — single client.

| depth | avg fan-out (nodes reached) | p50 | p99 | avg | throughput |
|---|---|---|---|---|---|
| 1 | ~11 | 2.00 ms | 15.1 ms | 2.72 ms | 368 q/s |
| 2 | ~110 | 2.58 ms | 11.9 ms | 3.20 ms | 313 q/s |
| 3 | ~1,099 | 10.2 ms | 45.0 ms | 12.1 ms | 83 q/s |
| 4 | ~9,643 | 19.4 ms | 206 ms | 36.6 ms | 27 q/s |

Latency tracks the reachable set (~10× per hop in this degree-10 random graph). Sub-25 ms p50
out to depth 4 (touching ~10k nodes) on a 2 GB-capped single node.

## Point lookups

| query | p50 | p99 | avg | throughput |
|---|---|---|---|---|
| by `@rid` (record identity) | 0.33 ms | 3.60 ms | 0.55 ms | 1,820 q/s |
| by indexed `uid` (UNIQUE index) | 1.76 ms | 57.0 ms | 5.44 ms | 184 q/s |

**Notable:** `@rid` direct access is ~9.9× faster than the indexed-property lookup at this scale,
and the `uid`-index path has a heavy tail (p99 57 ms, high variance). If your access pattern can
carry `@rid`s, prefer them. (The index-lookup tail is worth a follow-up — index type/config or
warm-cache effects.)

## Caveats

- Single-node, 2 GB-capped container, **localhost** HTTP (no network latency, no replication).
- Synthetic uniform-random graph; real workloads (skewed degree, communities) differ.
- **No baseline.** A "neo4j replacement" claim needs neo4j and/or Apache AGE run on this exact
  generator + hardware. See README "next steps".
- Concurrency not exercised here (`PARALLEL=1`); set `ARCADIC_BENCH_PARALLEL=N` for throughput
  under load.
