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
  shaping, all params-only and value-free. `fuse/3` fuses heterogeneous dense,
  sparse, **and full-text** neighbor specs into one ranked result set.
- **Full-text search** — `Arcadic.FullText` builds `FULL_TEXT` (Lucene) index DDL
  and `SEARCH_INDEX`/`SEARCH_FIELDS` query builders (BM25 `$score` on request);
  a `FULL_TEXT` index retro-indexes rows that already exist.
- **Bulk ingest & typed params** — `Arcadic.Bulk.ingest/3` bulk-creates vertices
  and edges in one atomic NDJSON POST to ArcadeDB's `/batch` endpoint (edges wire
  by a structural `"@id"` temp key, resolved to real RIDs in the response);
  `Arcadic.Param.int8/1` / `bytes/1` wrap efficient `$int8`/`$bytes` typed param
  values for compact embedding/byte-array ingest.
- **Schema, import & export** — read-only schema introspection (`Arcadic.Schema` —
  types / properties / indexes / buckets / database engine-config, `@props`-stripped),
  server-side bulk load (`Arcadic.Import.database/3`, `IMPORT DATABASE`) behind a
  positive-allowlist URL validator that closes the interpolated-URL injection surface, and
  symmetric server-side export (`Arcadic.Export.database/3`, `EXPORT DATABASE`) with a
  path-safe name.
- **Batteries included** — server, security, and backup admin (`Arcadic.Server`,
  `Arcadic.Security`, `Arcadic.Backup`), a migration runner, vector search,
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

Every dynamic value reaches ArcadeDB **only as a bound parameter** (`$name` here is
Cypher; SQL uses `:name` — see [Parameter binding by language](#parameter-binding-by-language)).
`query/4` hits the idempotent read endpoint; `command/4` hits the write endpoint.
Both return `{:ok, rows}` or `{:error, %Arcadic.Error{} | %Arcadic.TransportError{}}`;
`query!/4` and `command!/4` return the rows or raise. `command_async/4` submits a
fire-and-forget write, returning `:ok` once ArcadeDB accepts it for processing
(HTTP 202). The default language is `"cypher"`; pass `language: "sql"` (or
`gremlin`/`graphql`/`mongo`/`sqlscript`) to switch.

`Arcadic.transaction/3` opens an ArcadeDB session, runs the fun with a
session-scoped conn, and commits on normal return. An exception rolls back and
reraises; `Arcadic.rollback/2` aborts intentionally and yields `{:error, reason}`.

## Parameter binding by language

Every dynamic value is a bound parameter, never string interpolation — but the
placeholder syntax is language-specific: **SQL binds `:name`; Cypher binds `$name`**.
The two fail differently if swapped: a `$name` placeholder in a `language: "sql"`
statement binds to **null** (ArcadeDB does not error — a silent mis-bind), while a
`:name` placeholder in Cypher (or any default-language call) is a **parse error**.

```elixir
# SQL — :name
{:ok, rows} =
  Arcadic.query(conn, "SELECT FROM User WHERE name = :name", %{"name" => "Jo"}, language: "sql")

# Cypher (the default language) — $name
{:ok, rows} =
  Arcadic.query(conn, "MATCH (u:User {name: $name}) RETURN u", %{"name" => "Jo"})
```

## EXPLAIN & PROFILE

`Arcadic.explain/4` returns a statement's execution plan **without running it** —
plan-only and side-effect-free, so it is safe to call on a write statement.
`Arcadic.profile/4` **executes** the statement — a write mutates — and annotates the
plan with real runtime metrics. Both prepend `EXPLAIN `/`PROFILE ` to the statement and
return `{:ok, %{plan: String.t(), plan_tree: map(), rows: [map()]}}`: `plan` is the
portable, human-readable plan string; `plan_tree` is the raw, transport-defined plan
structure (its shape differs between HTTP and Bolt); `rows` is `[]` for `explain/4` and
the executed rows for `profile/4`. Both accept only `:language` (default `"cypher"`) and
`:timeout` — `:retries`/`:limit`/`:serializer` are rejected value-free (a plan is not a
retried, paged, or serialized row set). Bolt support is Cypher-only, same as everywhere
else in arcadic.

```elixir
{:ok, plan} = Arcadic.explain(conn, "MATCH (u:User) RETURN u")
plan.rows #=> []

{:ok, profiled} =
  Arcadic.profile(conn, "CREATE (u:User {name: $name}) RETURN u", %{"name" => "Jo"})
profiled.rows #=> [%{"u" => %{...}}]  # the write ran
```

Calling `query/4`, `command/4`, or `query_stream/4` on a statement that already carries
an `EXPLAIN`/`PROFILE` prefix now returns `{:error, %Arcadic.Error{reason: :use_explain}}`
(previously a silent `{:ok, []}`) — use `explain/4`/`profile/4` instead.

## Options reference

Which options each function accepts (an unknown key is rejected value-free):

| opt | `query/4` | `command/4` / `command_async/4` | `query_stream/4` | `explain/4` / `profile/4` |
|---|---|---|---|---|
| `:language` | yes | yes | yes | yes |
| `:limit` | yes | yes | no | no |
| `:serializer` | yes | yes | no | no |
| `:retries` | no | yes | no | no |
| `:auto_commit` | no | yes | no | no |
| `:timeout` | yes | yes | yes | yes |
| `:chunk_size` | no | no | yes | no |
| `:order_key` | no | no | yes (Cypher only) | no |

## Errors

Non-bang calls return `{:ok, rows}` or `{:error, %Arcadic.Error{} | %Arcadic.TransportError{}}`.
`Arcadic.Error.reason` is one of:

- `:not_idempotent` — a write submitted to the read endpoint (`query/4`)
- `:parse_error` — a statement syntax error
- `:unauthorized` — an ArcadeDB `SecurityException` (an auth failure, or a blocked
  private/loopback import URL — see [Schema introspection and bulk import](#schema-introspection-and-bulk-import))
- `:database_not_found`
- `:transaction_error` — a server transaction fault, or a client-side session misuse
  (nesting, or a commit/rollback with no active session)
- `:concurrent_modification` — an optimistic-concurrency or retry-needed conflict
- `:duplicate_key`
- `:timeout` — a server-side statement timeout (distinct from
  `%Arcadic.TransportError{reason: :timeout}`, the client-side connection timeout)
- `:invalid_begin_body` — an invalid `:isolation` value on `transaction/3`
- `:server_error` — the generic fallback for an unmatched or absent ArcadeDB exception
- `:use_explain` — `query/4`/`command/4`/`query_stream/4` called on a statement that
  already carries an `EXPLAIN`/`PROFILE` prefix; call `explain/4`/`profile/4` instead
- `:not_supported` — the active transport doesn't implement the called capability
  (e.g. `explain/4` on a transport without it, HTTP streaming inside a transaction,
  Bolt database admin) or the statement/opts fail a streaming-eligibility check

`Arcadic.TransportError.reason` is a connection-level failure with no HTTP response —
the underlying transport's own atom, not a fixed enum: for HTTP, whatever Mint/Finch
reports (e.g. `:timeout`, `:closed`, `:econnrefused`); for Bolt, `:timeout` (a RUN/PULL
receive timeout), `:bolt_protocol_error`, `:transaction_error`, `:cursor_open` /
`:cursor_already_open` (the stream-interleaving guard), a `boltx` error code, or
`:unknown` as a last-resort fallback.

A separate, non-`Arcadic.Error` convention: an invalid identifier (e.g. a bad type name
to `Arcadic.Schema.properties/2`) returns the bare `{:error, :invalid_identifier}`, never
echoing the offending string. The admin surface follows the same convention:
`Arcadic.Server.set_server_setting/3` / `set_database_setting/3` return
`{:error, :invalid_setting_key}` / `{:error, :invalid_setting_value}`,
`Arcadic.Backup.backup/2` / `restore/3` return `{:error, :invalid_url}`, and
`Arcadic.Security.create_user/2` returns `{:error, :invalid_user_spec}` for an unencodable
user spec (e.g. a non-UTF-8 password) — all value-free.

## Telemetry

arcadic emits value-free `:telemetry.span/3` spans — metadata is validated against a
fixed allowlist (`Arcadic.Telemetry.allowed_meta_keys/0`): `:language`, `:mode`,
`:http_status`, `:reason`, `:row_count`, `:in_transaction?`, `:isolation`, `:async?`,
`:operation`. No statement, params, values, or database name ever rides telemetry.

- `[:arcadic, :query, :start | :stop | :exception]` — `query/4`. Metadata: `:language`,
  `:mode` (`:read`), plus `:http_status`/`:reason`/`:row_count` on `:stop`.
- `[:arcadic, :command, :start | :stop | :exception]` — both `command/4` and
  `command_async/4`. Shared metadata: `:language`, `:mode` (`:write`), plus `:reason`
  on `:stop`. `command/4` also carries `:in_transaction?` (start) and
  `:http_status`/`:row_count` (on its success case); `command_async/4` instead carries
  `:async? true` and, being fire-and-forget, has no rows to count.
- `[:arcadic, :explain, :start | :stop | :exception]` — both `explain/4` (`:mode`
  `:read`) and `profile/4` (`:mode` `:write`, carries `:in_transaction?`, since PROFILE
  executes). Otherwise mirrors `:query`/`:command`; `:row_count` is `0` for a bare
  EXPLAIN.
- `[:arcadic, :query_stream, :start]` / `[:arcadic, :query_stream, :stop]` — every HTTP
  and Bolt stream path (manual `:telemetry.execute/3` events, not a span — no
  `:exception` variant). `:start` metadata is `%{mode: :read}`; `:stop` carries
  `%{mode: :read, reason: :ok | :halted}` (`:ok` drained, `:halted` stopped early) plus a
  `:row_count` measurement.

arcadic also emits `[:arcadic, :transaction, :start | :stop | :exception]`
(`transaction/3`, metadata carrying `:isolation`) and the standalone
`[:arcadic, :vector, :sparse_index_preexisting]` event (see
[Vector search](#vector-search)) under the same allowlist.

- `[:arcadic, :admin, :start | :stop | :exception]` — every `Arcadic.Server`,
  `Arcadic.Security`, and `Arcadic.Backup` call. Metadata: `:operation` (the
  atom naming the call, e.g. `:set_server_setting`, `:login`, `:backup`) on
  `:start`, plus `:reason` (`:ok`, or the error's `reason`/tag) on `:stop`.
  Value-free — no database name, setting key/value, URL, or credential ever
  rides this span.

`:start` measurements are `:telemetry.span/3`'s standard `:system_time`/`:monotonic_time`;
`:stop` and `:exception` carry `:duration`/`:monotonic_time`. An `:exception` event's
metadata is the span's *start* metadata (not the `:stop`-only additions like `:reason`)
plus `:kind`/`:reason`/`:stacktrace`, added by `:telemetry` itself.

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

## Administration & operations

Three modules cover ArcadeDB's server admin surface — all HTTP-only, tenant-blind,
and (like the rest of arcadic) never delegated from the `Arcadic` facade, so
destructive/privileged calls stay namespaced under `Arcadic.Server`,
`Arcadic.Security`, and `Arcadic.Backup`. Every identifier, setting key/value, and
URL they take is allowlist-validated **before** it reaches the wire.

### `Arcadic.Server`

Database lifecycle: `create_database/2` (+ `!`), `drop_database/2` (+ `!`),
`database_exists?/2`, `list_databases/1`, `open_database/2`, `close_database/2`,
`ready?/1`. Server introspection and control: `info/2` (opts `mode: :basic |
:default | :cluster` — `:default`/`:cluster` add metrics/settings),
`metrics/1` (the `"metrics"` map out of `info(conn, mode: :default)`),
`health?/1` (liveness probe), `events/1` (the server event log),
`set_server_setting/3` / `set_database_setting/3` (key/value both validated
value-free — a bad key or value returns `{:error, :invalid_setting_key |
:invalid_setting_value}`, never echoing the offending string),
`check_database/2` (`fix: true` runs `CHECK DATABASE FIX`; returns the
integrity report map), and `profiler/2` (`action` ∈ `:results | :start | :stop
| :reset`).

```elixir
{:ok, info}    = Arcadic.Server.info(conn, mode: :default)
{:ok, metrics} = Arcadic.Server.metrics(conn)
:ok            = Arcadic.Server.set_database_setting(conn, "arcadedb.dateFormat", "yyyy-MM-dd")
{:ok, report}  = Arcadic.Server.check_database(conn, fix: true)
```

`align_database/2` re-syncs a database across a cluster — **cluster-only**: on a
single-server node it returns a server error
(`{:error, %Arcadic.Error{reason: :server_error}}`), since ArcadeDB has nothing
to align against. `shutdown/1` halts the server; because the server stops
responding mid-request, a **successful** shutdown typically surfaces as
`{:error, %Arcadic.TransportError{reason: :closed}}` rather than `:ok` — treat a
transport-closed error from `shutdown/1` as success, not a fault to retry.

### `Arcadic.Security`

Session and identity admin. `login/1` mints a session token from the conn's
credentials (`POST /api/v1/login`); pair it with `Arcadic.Conn.with_bearer/2` to
derive a Bearer-authenticated conn for subsequent calls:

```elixir
{:ok, token} = Arcadic.Security.login(conn)
bearer_conn  = Arcadic.Conn.with_bearer(conn, token)
:ok          = Arcadic.Security.logout(bearer_conn)
```

`with_bearer/2` raises `ArgumentError` on a Bolt conn — Bearer auth is
**HTTP-only** (Bolt authenticates from `transport_options`, never `conn.auth`).
`sessions/1`, `users/1`, `groups/1`, and `api_tokens/1` list the corresponding
server admin resources. `create_user/2` takes `%{name:, password:, databases:
%{db => [roles]}}` (`databases` optional); the password is JSON-encoded into
the server command and **never echoed** back in an error, log, or telemetry
line — an unencodable spec (e.g. a non-UTF-8 password) is rejected value-free
as `{:error, :invalid_user_spec}` before any wire call. `drop_user/2` removes a
user by name.

### `Arcadic.Backup`

`backup/2` runs `BACKUP DATABASE` on `conn.database`, with an optional `:to`
target URL overriding the server's default backup directory; `list/1` lists
backups for `conn.database`; `restore/3` runs `restore database <name> <url>`.
Both a `:to` target and a `restore/3` URL are validated with
`Arcadic.Identifier.validate_url/1` before interpolation (a URL cannot be a
bound parameter in these commands) — a bad one returns `{:error, :invalid_url}`
value-free.

```elixir
{:ok, _}  = Arcadic.Backup.backup(conn, to: "file:///backups/mydb.zip")
{:ok, ls} = Arcadic.Backup.list(conn)
{:ok, _}  = Arcadic.Backup.restore(conn, "mydb_restored", "file:///backups/mydb.zip")
```

**SSRF note:** whether the server itself blocks a private/loopback restore
source is server-config-dependent — `restore/3`'s URL is trusted operator
input, not attacker-controlled data; do not pass it caller-supplied values.

### `:auto_commit`

`Arcadic.command/4` (and `command_async/4`) accept an `:auto_commit` boolean
opt, forwarded as-is to ArcadeDB's `autoCommit` request field — a faithful
passthrough, not arcadic-interpreted. `auto_commit: false` outside an explicit
`transaction/3` means the write is not auto-committed (ArcadeDB's own
semantic).

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

## GraphRAG quickstart

`Arcadic.Bulk`, `Arcadic.FullText`, and `Vector.fuse/3`'s heterogeneous specs combine into a
small graphRAG pipeline — bulk-load a graph, index it for full-text, then hybrid-retrieve
across a dense embedding arm and a full-text arm in one fused, ranked result set:

```elixir
# 1. Bulk-create vertices + edges in one atomic POST — vertices carry a temporary "@id"
#    that edges reference via "@from"/"@to"; the response maps each "@id" to its real RID.
{:ok, counts} =
  Arcadic.Bulk.ingest(conn, [
    %{"@type" => "vertex", "@class" => "Doc", "@id" => "d1", "title" => "Graph databases 101"},
    %{"@type" => "vertex", "@class" => "Doc", "@id" => "d2", "title" => "Vector search primer"},
    %{"@type" => "edge", "@class" => "RELATED", "@from" => "d1", "@to" => "d2"}
  ])

counts.id_mapping #=> %{"d1" => "#12:0", "d2" => "#12:1"}

# 2. Full-text index (retro-indexes the rows just created) + search
:ok = Arcadic.FullText.create_index(conn, "Doc", "title")
{:ok, hits} = Arcadic.FullText.search(conn, "Doc", "title", "graph", with_score: true)

# 3. Hybrid fusion — a dense vector arm plus a full-text arm, fused by reciprocal-rank fusion
{:ok, fused} =
  Arcadic.Vector.fuse(conn, [
    {"Doc", "embedding", query_vector, 10},
    {:fulltext, "Doc", "title", "graph", 10}
  ])
```

The [`notebooks/graphrag.livemd`](notebooks/graphrag.livemd) notebook walks the full
surface end to end — bulk graph ingest, idempotent `UNWIND` upsert, dense + sparse vector
indexes, full-text search, hybrid fusion, INT8-quantized vectors (`Arcadic.Param.int8/1`),
and a Cypher multi-hop traversal.

## Schema introspection and bulk import

`Arcadic.Schema` reflects the live schema, tenant-blind and `@props`-stripped. Every
query is arcadic's own fixed `SELECT FROM schema:*` literal, SQL-only (see
[Parameter binding by language](#parameter-binding-by-language)); a caller type name
binds as a SQL `:name` parameter (never interpolated) and is identifier-shape-guarded.

```elixir
{:ok, types}   = Arcadic.Schema.types(conn)
{:ok, props}   = Arcadic.Schema.properties(conn, "User")
{:ok, indexes} = Arcadic.Schema.indexes(conn, type: "User")
{:ok, buckets} = Arcadic.Schema.buckets(conn)
{:ok, cfg}     = Arcadic.Schema.database(conn)   # engine config (schema:database), @props-stripped
{:ok, stats}   = Arcadic.Schema.stats(conn)      # per-database operation counters (schema:stats)
{:ok, dict}    = Arcadic.Schema.dictionary(conn) # the record dictionary (schema:dictionary)
{:ok, views}   = Arcadic.Schema.materialized_views(conn) # schema:materializedviews
```

`indexes/2` returns both logical and physical per-bucket rows (filter on the absence of
`fileId` for logical-only). `stats/1` and `dictionary/1` return a single map (not a row list);
`materialized_views/1` returns a list (empty on a database with none).

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

Over HTTP, arcadic pages the statement itself behind the scenes — the statement must NOT carry
its own `ORDER BY`/`SKIP`/`LIMIT`, or a comment (`--`/`/*` for SQL, `//` for Cypher, which would
neutralize the appended suffix), each rejected value-free. A WHERE-less **SQL** statement pages
by an O(n) arcadic-owned `@rid` keyset cursor; a statement with its own `WHERE` falls back to
`ORDER BY @rid SKIP/LIMIT` offset (O(n²) server-side — prefer a Bolt cursor for very large
exports in that case). **Cypher** streams via a caller-supplied `order_key: "id(v)"` (restricted
to `id(<identifier>)`, the only total, unique order), offset-paged with Cypher `$name`
placeholders:

```elixir
Arcadic.query_stream(conn, "MATCH (v:Person) RETURN v", %{}, language: "cypher", order_key: "id(v)")
```

Either way, paging is a stable order, not a snapshot — a concurrent delete can skip a row across
pages. HTTP streaming refuses inside a transaction; **in-transaction streaming is Bolt-only**,
running over the transaction's own connection (so it sees the transaction's own uncommitted
writes) and guarded against interleaving a `command`/`query` on the same socket while a cursor is
open. Consume an in-transaction stream **inside** the `transaction/3` body — it is bound to the
transaction's connection.

> **ArcadeDB `parallelScanAbandonedTimeout` caveat.** ArcadeDB aborts a server-side scan cursor
> left idle for roughly 10 minutes. A Bolt `query_stream/4` consumer that pauses between `PULL`s
> longer than that (slow per-row processing, backpressure) can have its cursor abandoned
> server-side mid-stream — keep pulling, or move per-row processing off the enumeration path so
> the stream itself isn't the bottleneck.

Bolt can also run over TLS: `Arcadic.Transport.Bolt.setup(scheme: "bolt+s", ...)` is **secure by
default** (verifies the server certificate against the OS trust store); pass
`ssl_opts: [verify: :verify_none]` to opt out (documents the MITM exposure — only for a trusted
network path, e.g. local dev).

> **Operator note — upstream ArcadeDB Bolt-TLS hazard (fixed upstream 2026-07-08; ships in
> 26.7.2).** On ArcadeDB builds predating the fix, the Bolt-TLS listener performed every TLS
> handshake on its single shared accept thread, so one bad handshake could deny Bolt to all
> clients: an early-closed connection sent the accept thread into a tight loop (~100% CPU), and a
> stalled or untrusted-cert handshake blocked every subsequent client (no ServerHello) until
> ArcadeDB was restarted. This is an ArcadeDB **server** defect, not an arcadic one — arcadic's
> client-side TLS (secure-by-default `verify_peer`, fail-closed on an untrusted cert) is
> unaffected. Root-caused and fixed upstream on `main` 2026-07-08 (per-connection handshake
> threads + read timeout) — see
> [ArcadeData/arcadedb#5106](https://github.com/ArcadeData/arcadedb/issues/5106). If your server
> build predates the fix (including `26.8.1-SNAPSHOT` images built before 2026-07-08), treat the
> hazard as present and upgrade: the wedge is condition-dependent (early-close/stalled handshakes
> trigger it; a cleanly-delivered `unknown_ca` alert does not), so a clean probe on a pre-fix
> build proves nothing.

## Bolt transport (optional)

The query hot path can run over Bolt via the optional
[`boltx`](https://hex.pm/packages/boltx) dependency. Add `{:boltx, "~> 0.0.6"}`, then
build the connection with `Arcadic.Transport.Bolt.setup/1` (it pins Bolt v4 —
`versions: [4.4, 4.3, 4.2, 4.1]` — and the non-TLS `bolt` scheme, which ArcadeDB uses,
and takes `username`/`password`). `setup/1` starts the pool AND returns the
`transport_options` for `Arcadic.connect/3` in one call, carrying both `:bolt` (the pool,
used by `execute`/`transaction`/`ready?`) and `:bolt_opts` (the resolved per-stream
connect opts, used by `query_stream/4`) — pass its whole return value straight through
as `transport_options`. A bare `transport_options: [bolt: pool]` (skipping `setup/1`)
omits `:bolt_opts` and makes `query_stream/4` return `{:error, %Arcadic.Error{reason:
:not_supported}}`.

```elixir
{:ok, transport_options} =
  Arcadic.Transport.Bolt.setup(
    hostname: "localhost", port: 7687, username: "root", password: pass
  )

conn =
  Arcadic.connect("http://localhost:2480", "mydb",
    auth: {"root", pass},
    transport: Arcadic.Transport.Bolt,
    transport_options: transport_options
  )
```

For paging large result sets, `Arcadic.query_stream/4` returns a lazy `Stream.t()`
of rows over Bolt, chunked via `PULL`.

Bolt **raises** if a `BOLT_USER`, `BOLT_PWD`, `BOLT_HOST`, or `BOLT_TCP_PORT`
environment variable is set — at pool setup (`start_link/1`/`setup/1`) and on every
connect/reconnect: boltx reads those with precedence over arcadic's explicit config and
re-reads them at connect time, so a var set after startup would otherwise silently
override the connection or its credentials; the connect-time reject closes that window.
Unset the variable and pass `:scheme`/`:hostname`/`:port`/`:username`/`:password`
explicitly.

Vector search is **HTTP-only** — `Arcadic.Vector` (`LSM_VECTOR` / `LSM_SPARSE_VECTOR`)
runs SQL, and Bolt is Cypher-only (a `SELECT` over Bolt is a syntax error; the Bolt
`RUN` carries no SQL-language selector), so run vector queries over the HTTP transport.

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
    {:arcadic, "~> 0.4"},
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
