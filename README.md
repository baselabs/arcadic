# Arcadic

[![Hex.pm](https://img.shields.io/hexpm/v/arcadic.svg)](https://hex.pm/packages/arcadic)
[![Hexdocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/arcadic)
[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fbaselabs%2Farcadic%2Fmain%2Fnotebooks%2Fgetting_started.livemd)

A lean, framework-agnostic Elixir client for [ArcadeDB](https://arcadedb.com)
over the **HTTP Cypher command API**, with an optional Bolt transport for the
query hot path.

Arcadic is the "`postgrex` of ArcadeDB" — it ships Cypher/SQL to ArcadeDB and
manages connections, sessions, and transactions, and nothing more. It is
deliberately **tenant-blind and framework-agnostic**: no Ash, no multitenancy,
no data classification. Those belong one layer up, in
[`ash_arcadic`](https://github.com/baselabs/ash_arcadic) (the "`ash_postgres` of
ArcadeDB").

## Highlights

- **Cypher-first, multi-language** — the default language is `"cypher"`; opt into
  `sql`, `gremlin`, `graphql`, `mongo`, or `sqlscript` per call.
- **Parameters only** — every dynamic value reaches ArcadeDB as a bound parameter
  (`$name`), never string interpolation, so the injection surface stays closed.
- **Typed errors with boundary redaction** — `Arcadic.Error` carries a typed
  `reason`, HTTP status, and error class; raw parameter values and response rows
  never enter an error message, log line, or `inspect/1` output.
- **Session transactions** — `transaction/3` opens an ArcadeDB session and commits
  on normal return, rolls back and reraises on exception (postgrex semantics).
- **Pluggable transport** — HTTP (Req/Finch) by default, with an optional Bolt v4
  transport for the query hot path and lazy result streaming.
- **Vector search** — dense (`LSM_VECTOR`) and sparse (`LSM_SPARSE_VECTOR`) index
  DDL plus nearest-neighbour, sparse, and hybrid-fusion query builders
  (`Arcadic.Vector`) with a candidate-set `filter` and `group_by`/`group_size`
  shaping, all params-only and value-free.
- **Schema, import & export** — read-only schema introspection (`Arcadic.Schema` —
  types / properties / indexes / buckets / database engine-config, `@props`-stripped),
  server-side bulk load (`Arcadic.Import.database/3`, `IMPORT DATABASE`) behind a
  positive-allowlist URL validator that closes the interpolated-URL injection surface, and
  symmetric server-side export (`Arcadic.Export.database/3`, `EXPORT DATABASE`) with a
  path-safe name.
- **Batteries included** — server admin, a migration runner, vector search,
  schema introspection, bulk import, allowlist-validated identifiers, and
  value-free telemetry spans.

## Quickstart

```elixir
conn = Arcadic.connect("http://localhost:2480", "mydb", auth: {"root", pass})

{:ok, rows} = Arcadic.query(conn, "MATCH (n:User) RETURN n LIMIT $lim", %{"lim" => 10})

{:ok, [user]} =
  Arcadic.command(conn, "CREATE (u:User {name:$n}) RETURN u", %{"n" => "Jo"})

{:ok, result} =
  Arcadic.transaction(conn, fn tx ->
    Arcadic.command!(tx, "MERGE (u:User {id:$id})", %{"id" => "u1"})
  end)
```

Every dynamic value reaches ArcadeDB **only as a bound parameter** (`$name`).
`query/4` hits the idempotent read endpoint; `command/4` hits the write endpoint.
Both return `{:ok, rows}` or `{:error, %Arcadic.Error{} | %Arcadic.TransportError{}}`;
`query!/4` and `command!/4` return the rows or raise. `command_async/4` submits a
fire-and-forget write, returning `:ok` once ArcadeDB accepts it for processing
(HTTP 202). The default language is `"cypher"`; pass `language: "sql"` (or
`gremlin`/`graphql`/`mongo`/`sqlscript`) to switch.

`Arcadic.transaction/3` opens an ArcadeDB session, runs the fun with a
session-scoped conn, and commits on normal return. An exception rolls back and
reraises; `Arcadic.rollback/2` aborts intentionally and yields `{:error, reason}`.

## Production pool

The HTTP transport runs on Req/Finch. In production, give Arcadic a dedicated
Finch pool in your supervision tree rather than the default shared one:

```elixir
# lib/my_app/application.ex
children = [
  {Finch, name: MyApp.ArcadicFinch},
  # ...
]

# then point connections at it
conn =
  Arcadic.connect("http://localhost:2480", "mydb",
    auth: {"root", pass},
    transport_options: [finch: MyApp.ArcadicFinch]
  )
```

## Server admin

`Arcadic.Server` covers server-level operations: `create_database/2` (+ `!`),
`drop_database/2` (+ `!`), `database_exists?/2`, `list_databases/1`, and
`ready?/1`. Every database identifier is allowlist-validated before it reaches
the wire.

## Migrations

`Arcadic.Migrator` runs `Arcadic.Migration`s in order and tracks applied
versions in the `_arcadic_migrations` type. Declare a migration
(`version/0`, `up/1`, `down/1`), register the ordered list with
`use Arcadic.MigrationRegistry` + `migrations [...]`, then run
`Arcadic.Migrator.migrate/2` / `status/2` / `rollback/3` / `reset/2`.

```elixir
defmodule MyApp.Migrations.V1 do
  @behaviour Arcadic.Migration
  @impl true
  def version, do: 1
  @impl true
  def up(conn), do: Arcadic.command!(conn, "CREATE VERTEX TYPE User", %{}, language: "sql") && :ok
  @impl true
  def down(conn), do: Arcadic.command!(conn, "DROP TYPE User IF EXISTS", %{}, language: "sql") && :ok
end

defmodule MyApp.Migrations do
  use Arcadic.MigrationRegistry
  migrations [MyApp.Migrations.V1]
end

{:ok, _count} = Arcadic.Migrator.migrate(conn, MyApp.Migrations)
```

## Vector search

`Arcadic.Vector` builds ArcadeDB dense **and sparse** vector index DDL plus
nearest-neighbour, sparse, and hybrid-fusion queries. Create an `LSM_VECTOR` index
(idempotent — `IF NOT EXISTS`), then search. The query vector, `k`, and options bind
as parameters; the index reference is identifier-validated before it reaches the
statement.

```elixir
:ok =
  Arcadic.Vector.create_dense_index(conn, "Doc", "embedding", 1536, similarity: :cosine)

{:ok, rows} =
  Arcadic.Vector.neighbors(conn, "Doc", "embedding", query_vector, 10, max_distance: 0.3)

# hybrid fusion over multiple dense subqueries
{:ok, fused} =
  Arcadic.Vector.fuse(
    conn,
    [{"Doc", "embedding", dense_a, 20}, {"Doc", "embedding", dense_b, 20}],
    fusion: :rrf
  )
```

Sparse retrieval (learned-sparse / BM25-style) runs over an `LSM_SPARSE_VECTOR` index
on a `(tokens, weights)` property pair, ranked by a top-level `score`. **Create the
index before loading rows** — a sparse index does not cover pre-existing rows (a
`[:arcadic, :vector, :sparse_index_preexisting]` telemetry event fires if you create
it over existing data).

```elixir
:ok = Arcadic.Vector.create_sparse_index(conn, "Doc", "tokens", "weights", modifier: :idf)

{:ok, hits} =
  Arcadic.Vector.sparse_neighbors(conn, "Doc", "tokens", "weights", tokens, weights, 10)
```

All three builders (`neighbors/6`, `sparse_neighbors/8`, `fuse/3`) also accept a
candidate-set `filter` (a non-empty list of `#bucket:pos` RID strings) and
`group_by` / `group_size` result shaping — all param-bound.

`neighbors/6` rows carry a `distance` whose scale depends on the index `similarity`
(COSINE `0..1` ascending, so smaller is nearer; DOT_PRODUCT is negative, so a small
positive `max_distance` filters nothing — choose thresholds per similarity). `fuse/3`
rows are ranked by `score` (higher is better); `sparse_neighbors/8` rows carry `score`
and no `distance`. The Ash-native data-layer surface remains a non-goal (owned by the
sibling `ash_arcadic`).

## Schema introspection & bulk import

`Arcadic.Schema` reflects the live schema, tenant-blind and `@props`-stripped. Every
query is arcadic's own fixed `SELECT FROM schema:*` literal; a caller type name binds as
a `$param` (never interpolated) and is identifier-shape-guarded.

```elixir
{:ok, types}   = Arcadic.Schema.types(conn)
{:ok, props}   = Arcadic.Schema.properties(conn, "User")
{:ok, indexes} = Arcadic.Schema.indexes(conn, type: "User")
{:ok, buckets} = Arcadic.Schema.buckets(conn)
{:ok, cfg}     = Arcadic.Schema.database(conn)   # engine config (schema:database), @props-stripped
```

`indexes/2` returns both logical and physical per-bucket rows (filter on the absence of
`fileId` for logical-only).

`Arcadic.Import.database/3` bulk-loads a database export server-side via `IMPORT DATABASE`.
The source URL cannot be a bound parameter (ArcadeDB rejects it), so it is interpolated
behind a **positive character allowlist** (RFC 3986 minus the single quote and backslash —
which closes the SQL-literal injection surface, since ArcadeDB honours backslash-escapes)
plus a scheme allowlist (`http` / `https` / `file`). Rejections are value-free.

```elixir
{:ok, _} = Arcadic.Import.database(conn, "https://host/export.jsonl.tgz")
{:ok, _} = Arcadic.Import.database(conn, "file:///srv/exports/dump", with: [commitEvery: 10_000])
```

The server must be able to reach the URL — ArcadeDB blocks private/loopback hosts by
default (surfaced as `%Arcadic.Error{reason: :unauthorized, exception: "java.lang.SecurityException"}`,
distinct from an auth failure), so use a public URL or a server-local `file://` path. `with:` settings
accept number, boolean, and charset-allowlisted string values (e.g. `mapping: "map.json"`), emitted as
ArcadeDB's no-parens `WITH k = v` grammar.

`Arcadic.Export.database/3` is the symmetric server-side export — `EXPORT DATABASE file://<name>` to
ArcadeDB's exports directory. The bare name is path-traversal-guarded (value-free); `with:` settings
reuse `Arcadic.Import`'s grammar.

```elixir
{:ok, _} = Arcadic.Export.database(conn, "nightly_backup", with: [format: "jsonl", overwrite: true])
```

## Streaming & secure transport

`Arcadic.query_stream/4` lazily streams a large read as raw row maps — over the default HTTP
transport or over Bolt.

```elixir
{:ok, stream} =
  Arcadic.query_stream(conn, "SELECT FROM User", %{}, language: "sql", chunk_size: 500)

stream |> Stream.each(&IO.inspect/1) |> Stream.run()
```

Over HTTP, arcadic pages the statement itself with a param-bound `ORDER BY @rid SKIP/LIMIT`
suffix (`@rid` is a total order, so paging is stable) — the statement must be `language: "sql"`
and must NOT carry its own `ORDER BY`/`SKIP`/`LIMIT` (rejected value-free). Each page is a fresh
offset re-scan, so a very deep stream costs O(n²) server-side — prefer a Bolt cursor for very
large exports. `@rid` gives a stable order, not a snapshot — a concurrent delete can skip a row
across pages. HTTP streaming refuses inside a transaction; **in-transaction streaming is
Bolt-only**, running over the transaction's own connection (so it sees the transaction's own
uncommitted writes) and guarded against interleaving a `command`/`query` on the same socket
while a cursor is open. Consume an in-transaction stream **inside** the `transaction/3` body — it
is bound to the transaction's connection.

Bolt can also run over TLS: `Arcadic.Transport.Bolt.setup(scheme: "bolt+s", ...)` is **secure by
default** (verifies the server certificate against the OS trust store); pass
`ssl_opts: [verify: :verify_none]` to opt out (documents the MITM exposure — only for a trusted
network path, e.g. local dev).

## Bolt transport (optional)

The query hot path can run over Bolt via the optional
[`boltx`](https://hex.pm/packages/boltx) dependency. Add `{:boltx, "~> 0.0.6"}`,
start a Bolt connection with `Arcadic.Transport.Bolt.start_link/1` (it pins Bolt
v4 — `versions: [4.4, 4.3, 4.2, 4.1]` — and the non-TLS `bolt` scheme, which
ArcadeDB uses, and takes `username`/`password`), then pass the connection
reference. Server admin runs over HTTP; use an HTTP conn for it even when queries
go over Bolt.

```elixir
{:ok, bolt} =
  Arcadic.Transport.Bolt.start_link(
    hostname: "localhost", port: 7687, username: "root", password: pass
  )

conn =
  Arcadic.connect("http://localhost:2480", "mydb",
    auth: {"root", pass},
    transport: Arcadic.Transport.Bolt,
    transport_options: [bolt: bolt]
  )
```

For paging large result sets, `Arcadic.query_stream/4` returns a lazy `Stream.t()`
of rows over Bolt, chunked via `PULL`.

## Layering

```
Ash core            (multitenancy DSL, policies, the tenant concept)
   │  passes tenant / builds queries
ash_arcadic         (Ash.DataLayer — set_tenant/3, sensitive-attr verifiers, traversal)
   │  calls
Arcadic  ← this lib (HTTP Cypher transport, sessions/transactions — tenant-blind)
   │  POST /api/v1/command/<db>  {"language":"cypher", ...}
ArcadeDB            (native OpenCypher engine)
```

## Installation

Add `arcadic` from [Hex](https://hex.pm/packages/arcadic):

```elixir
def deps do
  [
    {:arcadic, "~> 0.2"},
    # optional, for the Bolt transport:
    {:boltx, "~> 0.0.6"}
  ]
end
```

Arcadic is co-developed with its Ash data layer
[`ash_arcadic`](https://github.com/baselabs/ash_arcadic); to hack on both together, point at
a local checkout instead — `{:arcadic, path: "../arcadic"}`.

## Development

```bash
mix deps.get
mix test
mix quality   # format --check-formatted + credo --strict + dialyzer
```

To explore the full surface interactively against a local ArcadeDB, open the
[getting-started notebook](notebooks/getting_started.livemd) (the **Run in
Livebook** badge at the top launches it directly).

Contributor and agent working rules — including the params-only, redaction, and
tenant-blind invariants — live in
[`AGENTS.md`](https://github.com/baselabs/arcadic/blob/main/AGENTS.md).

## Benchmarks

A load/traversal benchmark harness for ArcadeDB lives under
[`bench/`](https://github.com/baselabs/arcadic/tree/main/bench) (not shipped in the package),
driven by Benchee against a throwaway database:

```bash
ARCADIC_BENCH_URL=<url> ARCADIC_BENCH_PASSWORD=<pw> mix run bench/run.exs
```

It profiles ingest throughput, k-hop traversal latency by depth, point lookups, and
throughput-under-concurrency. Methodology, knobs, and a full 100k-node result set are in
[bench/README.md](https://github.com/baselabs/arcadic/blob/main/bench/README.md) and
[bench/RESULTS.md](https://github.com/baselabs/arcadic/blob/main/bench/RESULTS.md). Headline
figures — 100k `Person` / 1M `KNOWS`, single 2 GB-capped node, ArcadeDB 26.8.1, localhost, single
client (a *profile*, not a neo4j comparison):

| metric | figure |
|---|---|
| k-hop traversal p50 | 0.7 ms (1-hop) → 49 ms (4-hop, ~10k nodes reached) |
| point lookup p50 | ~0.6 ms (`@rid` and indexed `uid` within ~6% once settled) |
| client-write ingest | ~4.2k edges/s (RID-addressed; ~2.3× the naive uid-subquery path) |

### Bulk loading

The ingest figure above is per-statement *client writes*. To load a large dataset, use
ArcadeDB's bulk facilities — far faster than any `INSERT`/`CREATE EDGE` loop:

- `Arcadic.Import.database/3` — `Arcadic.Import.database(conn, "https://…/data.csv.tgz")` imports
  CSV / JSON / GraphML / Neo4j / OrientDB / ArcadeDB exports server-side. The URL is validated
  (positive character + scheme allowlist, value-free) rather than hand-interpolated, and must be
  reachable by the server (private/loopback hosts are blocked; use a public URL or a `file://` path).
  Optional `with:` number/boolean/string settings tune the load (e.g. `with: [commitEvery: 10_000]`).
- for an **index-deferred incremental** load, order it yourself — create the type, bulk-load the
  rows (a `command/4` loop or one `Arcadic.transaction/3`), then create the index. A `LSM_TREE` or
  dense `LSM_VECTOR` index retro-indexes existing rows, but an `LSM_SPARSE_VECTOR` index must be
  created **before** the load (see [Vector search](#vector-search)); the correct ordering is
  index-type-specific, so arcadic ships no generic index-deferral helper.
- for batched incremental writes, wrap them in `Arcadic.transaction/3` (one commit for many
  statements) instead of auto-committing each.

## Credits

- [**ArcadeDB**](https://arcadedb.com) — the multi-model database Arcadic speaks to.
- [**arcadex**](https://hex.pm/packages/arcadex) — prior-art ArcadeDB client that
  served as a reference for the HTTP command-API request/response shapes.
- [**boltx**](https://hex.pm/packages/boltx) — the Bolt protocol driver behind the
  optional Bolt transport.
- [**Req**](https://hex.pm/packages/req) / [**Finch**](https://hex.pm/packages/finch)
  — the HTTP client and pool behind the default transport.
- [**DBConnection**](https://hex.pm/packages/db_connection) — connection pooling for
  the Bolt transport.

The `postgrex`/`ash_postgres` split that inspired Arcadic and `ash_arcadic` is the
work of the Elixir Ecto and Ash communities.

## License

MIT — see [LICENSE](LICENSE).
