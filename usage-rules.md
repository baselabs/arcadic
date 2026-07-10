# arcadic usage rules

_A framework-agnostic Elixir client for ArcadeDB over the HTTP Cypher command API._

## What arcadic is (and is not)

- **Is:** a thin transport. Sends Cypher/SQL to ArcadeDB's HTTP command API,
  manages connections and session transactions, normalizes responses.
- **Is not:** Ash-aware, tenant-aware, or classification-aware. Never put
  multitenancy or sensitive-data logic here — that is `ash_arcadic`'s job.

## Public surface

- **`Arcadic`** — `connect/3`, `with_database/2`; `query/4` + `query!/4`
  (idempotent read endpoint), `command/4` + `command!/4` (write endpoint —
  accepts an `:auto_commit` boolean opt, forwarded as-is to ArcadeDB's
  `autoCommit` body param, not arcadic-interpreted; `auto_commit: false`
  outside `transaction/3` means ArcadeDB itself does not auto-commit the
  write),
  `command_async/4` (fire-and-forget, returns `:ok` on 202); `explain/4` + `explain!/4`
  (execution plan, **does NOT run** the statement) and `profile/4` + `profile!/4`
  (**EXECUTES** the statement — a write mutates — plan annotated with runtime
  metrics), both returning `{:ok, %{plan: String.t(), plan_tree: map(), rows:
  [map()]}}` (`plan` the portable human string, `plan_tree` the raw
  transport-defined structure, `rows` empty for `explain/4`); `transaction/3` and
  `rollback/2` for session transactions. Non-bang calls return `{:ok, rows}` or
  `{:error, %Arcadic.Error{} | %Arcadic.TransportError{}}`. Default language is
  `"cypher"`; opt into `sql`/`gremlin`/`graphql`/`mongo`/`sqlscript` per call.
  `query/4`/`command/4`/`query_stream/4` on a statement already carrying an
  `EXPLAIN`/`PROFILE` prefix return `{:error, %Arcadic.Error{reason: :use_explain}}`
  — call `explain/4`/`profile/4` instead.
- **`Arcadic.Conn`** — a pure-data connection handle (no process). Its `Inspect`
  redacts auth and session id. `with_database/2` derives a same-pool handle on
  another database (clears the session); `with_bearer/2` derives a
  Bearer-authenticated handle from a Basic one (typically fed
  `Arcadic.Security.login/1`'s token) — **HTTP-only**, raises `ArgumentError`
  on a Bolt conn (Bolt authenticates from `transport_options`, never
  `conn.auth`).
- **`Arcadic.Server`** — server/database admin, HTTP-only, not delegated from
  the `Arcadic` facade: `create_database/2` (+ `!`), `drop_database/2` (+ `!`),
  `database_exists?/2`, `list_databases/1`, `ready?/1`, `open_database/2`,
  `close_database/2`, `align_database/2` (**cluster-only** — a single-server
  node returns `{:error, %Arcadic.Error{reason: :server_error}}`),
  `check_database/2` (`fix: true` → `CHECK DATABASE FIX`, returns the
  integrity map), `info/2` (`mode: :basic | :default | :cluster`),
  `metrics/1`, `health?/1`, `events/1`, `set_server_setting/3` /
  `set_database_setting/3` (key + value both validated value-free — see
  Errors below), and `profiler/2` (`action` ∈ `:results | :start | :stop |
  :reset`). `shutdown/1` halts the server; a **successful** shutdown typically
  surfaces as `{:error, %Arcadic.TransportError{reason: :closed}}` (the server
  stops responding mid-request) rather than `:ok` — treat that as success, not
  a retryable fault.
- **`Arcadic.Security`** — session/identity admin, HTTP-only: `login/1` mints
  a session token (`POST /api/v1/login`) — feed it to `Arcadic.Conn.with_bearer/2`
  for subsequent Bearer-authenticated calls; `logout/1` revokes the current
  session; `sessions/1`, `users/1`, `groups/1`, `api_tokens/1` list the
  corresponding admin resources; `create_user/2` takes `%{name:, password:,
  databases: %{db => [roles]}}` (`databases` optional) — the password is
  JSON-encoded into the server command and **never echoed** in an error, log,
  or telemetry line (an unencodable spec is rejected value-free as
  `{:error, :invalid_user_spec}`); `drop_user/2` removes a user by name.
- **`Arcadic.Backup`** — backup/restore, HTTP-only: `backup/2` (`BACKUP
  DATABASE` on `conn.database`, optional `:to` target URL), `list/1` (backups
  for `conn.database`), `restore/3` (`restore database <name> <url>`). A
  `:to` target and a `restore/3` URL are both `Arcadic.Identifier.validate_url/1`-
  validated before interpolation (neither command can bind a URL param) — a
  bad one returns `{:error, :invalid_url}`. **SSRF note:** whether the server
  blocks a private/loopback restore source is server-config-dependent —
  `restore/3`'s URL is trusted operator input, never pass it caller-supplied
  values.
- **Migrations** — `Arcadic.Migration` (behaviour: `version/0`, `up/1`, `down/1`),
  `Arcadic.MigrationRegistry` (`use` + `migrations [...]`), `Arcadic.Migrator`
  (`migrate/2`, `status/2`, `rollback/3`, `reset/2`, `pending_migrations/2`),
  tracking applied versions in `_arcadic_migrations`.
- **`Arcadic.Vector`** — dense + sparse vector search over ArcadeDB `LSM_VECTOR` /
  `LSM_SPARSE_VECTOR`: `create_dense_index/5`, `drop_dense_index/3`, `neighbors/6`,
  `fuse/3`, `index_ref/2`, plus `create_sparse_index/5`, `sparse_index_ref/3`,
  `drop_sparse_index/4`, `sparse_neighbors/8` (all + `!`). Tenant-blind; query vector / tokens / weights / `k` /
  `ef_search` / `max_distance` bind as params, index refs are identifier-validated, and
  metadata / query / fusion option inputs are allowlisted and validated value-free.
  Shared opts on `neighbors` / `sparse_neighbors` / `fuse`: `filter` (non-empty
  `#bucket:pos` RID candidate set), `group_by` (`Identifier`-shape-guarded), `group_size`
  — all param-bound. `distance` scale is similarity-dependent; `fuse/3` and
  `sparse_neighbors/8` rank by `score` (sparse rows carry no `distance`). Create sparse
  indexes **before** loading rows — they do not retro-index existing data (a
  `[:arcadic, :vector, :sparse_index_preexisting]` telemetry event fires if you do).
- **`Arcadic.Schema`** — read-only schema introspection: `types/1`, `properties/2`,
  `indexes/2` (with a `:type` filter), `buckets/1`, `database/1` (the engine config,
  `schema:database`), `stats/1` (`schema:stats` per-database operation counters, a single
  map), `dictionary/1` (`schema:dictionary`, a single map), and `materialized_views/1`
  (`schema:materializedviews`, a list) (all + `!`). SQL-only `SELECT FROM
  schema:*`; a caller type name binds as a SQL `:name` param (never `$name` — see
  Parameter binding below) and is `Identifier`-shape-guarded;
  ArcadeDB's `@props` serializer noise is deep-stripped at every depth. `indexes/2` returns
  both logical and physical per-bucket rows (filter on `fileId` absence for logical-only).
- **`Arcadic.Import`** — `database/3` (+ `!`): `IMPORT DATABASE` bulk load. The source URL is
  interpolated (ArcadeDB rejects a bound `:url`) behind a positive character + scheme
  (`http`/`https`/`file`) allowlist that closes the SQL-literal injection surface, value-free on
  rejection; `with:` takes number, boolean, and charset-allowlisted string settings (injection-inert),
  emitted as ArcadeDB's no-parens `WITH k = v` grammar. A private/loopback host trips ArcadeDB's SSRF
  guard (`:unauthorized` / `java.lang.SecurityException`, distinct from an auth failure via
  `error.exception`); `file://` is server-local.
- **`Arcadic.Export`** — `database/3` (+ `!`): `EXPORT DATABASE file://<name>` server-side, symmetric
  to `Arcadic.Import`. The bare export name is guarded by a positive allowlist (no path / traversal /
  quote, value-free); `with:` settings reuse the import grammar (e.g. `format: "jsonl"`,
  `overwrite: true`).
- **Streaming** — `Arcadic.query_stream(conn, sql, params, language: "sql", chunk_size: 500)`
  lazily streams a large read as raw row maps over the default HTTP transport. A streamable
  statement must NOT carry its own `ORDER BY`/`SKIP`/`LIMIT`, or a comment (`--`/`/*` for SQL,
  `//` for Cypher, which would neutralize arcadic's appended suffix) — each rejected value-free
  (`reason: :not_supported`), as is a param named `__arcadic_skip`/`__arcadic_limit` (reserved).
  `chunk_size` must be a positive integer. A WHERE-less **SQL** statement pages by an O(n)
  arcadic-owned `@rid` keyset cursor (`WHERE @rid > <cursor> ORDER BY @rid LIMIT`); a statement
  with its own `WHERE` falls back to `ORDER BY @rid SKIP/LIMIT` offset (O(n²) — arcadic cannot
  inject a keyset predicate without parsing). **Cypher** streams via a caller-supplied
  `order_key: "id(v)"` (restricted to `id(<identifier>)`, the only total, unique order), offset-paged
  with Cypher `$name` placeholders:
  `Arcadic.query_stream(conn, "MATCH (v:Person) RETURN v", %{}, language: "cypher", order_key: "id(v)")`.
  Either way, paging is a stable order, not a snapshot: each page is an independent stateless
  request, so a concurrent delete can skip a row — use a Bolt in-tx cursor for snapshot
  consistency. HTTP streaming refuses inside a transaction (`session_id` set) — in-tx streaming is
  Bolt-only, over the transaction's own connection (so it sees the transaction's own uncommitted
  writes), guarded so a `command`/`query` on that same conn cannot interleave an open cursor on the
  shared socket. **Consume an in-tx stream INSIDE the `transaction/3` body** — it is bound to the
  transaction's connection and cannot be enumerated after the transaction returns. ArcadeDB aborts
  a server-side scan cursor idle for ~10 minutes (`parallelScanAbandonedTimeout`) — a Bolt
  `query_stream/4` consumer that pauses between `PULL`s longer than that can have its cursor
  abandoned mid-stream, so keep pulling.
- **Bolt TLS** — `Arcadic.Transport.Bolt.setup(scheme: "bolt+s", ssl_opts: [...])` runs Bolt over
  TLS. `bolt+s` is **secure by default**: it verifies the server certificate against the OS trust
  store (`verify_peer`) unless the caller passes `ssl_opts: [verify: :verify_none]` — an explicit
  opt-in that accepts any certificate (documents the MITM exposure; only use it against a trusted
  network path, e.g. local dev). Omitting `:scheme` stays on the plaintext `bolt` scheme.
  **Operator note (upstream, fixed 2026-07-08 → ships in 26.7.2):** on ArcadeDB builds predating
  the fix, the Bolt-TLS listener ran every TLS handshake on its single shared accept thread — one
  early-closed connection pinned it in a tight loop (~100% CPU), and a stalled or untrusted-cert
  handshake blocked every other client (no ServerHello) until restart — an ArcadeDB **server**
  defect, not arcadic's (client-side TLS is unaffected). Fixed upstream (per-connection handshake
  threads + read timeout). If your server build predates the fix, treat the hazard as present —
  it is condition-dependent (early-close/stall trigger it; a clean `unknown_ca` alert exchange
  does not), so a clean probe proves nothing — and upgrade. Tracked at
  [ArcadeData/arcadedb#5106](https://github.com/ArcadeData/arcadedb/issues/5106).
- **`Arcadic.Transport`** — the transport behaviour seam; `Arcadic.Transport.HTTP`
  (Req/Finch) is the default, `Arcadic.Transport.Bolt` is the optional Bolt one.
- **`Arcadic.Error` / `Arcadic.TransportError`** — the typed error taxonomy.
- **`Arcadic.Telemetry`** — value-free `:telemetry.span/3` spans.
- **`Arcadic.Identifier`** — allowlist identifier validation.
- **`Arcadic.Param`** — `int8/1` / `bytes/1` typed param-value wrappers
  (`%{"$int8" => [...]}` / `%{"$bytes" => base64}`), decoded server-side to a
  Java `byte[]` before the query runs. HTTP-only, requires ArcadeDB ≥ 26.5.1.
- **`Arcadic.FullText`** — `FULL_TEXT` (Lucene) index DDL (`create_index/4` +
  `drop_index/3`) and `SEARCH_INDEX`/`SEARCH_FIELDS` query builders
  (`search/5`, `search_fields/5`), parallel to `Arcadic.Vector`. HTTP-only SQL;
  a `FULL_TEXT` index retro-indexes rows that already exist. `:with_score` (BM25 `$score`)
  applies to `search/5` (`SEARCH_INDEX`) only — `SEARCH_FIELDS` has no relevance score, so
  `search_fields/5` with `:with_score` projects a constant `0.0`.
- **`Arcadic.Bulk`** — `ingest/3` (+ `!`): bulk-creates vertices and edges over
  ArcadeDB's `POST /api/v1/batch/<db>` NDJSON endpoint, the heavy-ingest
  sibling of `Arcadic.Import.database`. Create-only, atomic by default,
  HTTP-only.
- **`Arcadic.Vector.fuse/3`** now accepts heterogeneous neighbor specs — a bare
  `{type, property, query_vector, k}` dense arm, a `{:sparse, type,
  tokens_property, weights_property, tokens, weights, k}` arm, and/or a
  `{:fulltext, type, property, query, k}` arm — fused in one hybrid-ranked
  result set (see `Arcadic.Vector` above and Bulk loading below).

## Bulk loading

- For a **large initial load**, prefer ArcadeDB's server-side import over an `INSERT`/`CREATE EDGE`
  loop: `Arcadic.Import.database(conn, "https://host/export.jsonl.tgz")` imports CSV / JSON /
  GraphML / Neo4j / OrientDB / ArcadeDB exports. The source URL is validated (positive character +
  scheme allowlist, value-free) rather than hand-interpolated — do NOT hand-build an
  `IMPORT DATABASE '<url>'` string, which reopens the injection surface. The URL must be reachable
  by the SERVER; ArcadeDB blocks private/loopback hosts by default, so use a public URL or a
  server-local `file://`. Optional `with:` number/boolean/string settings tune the load (e.g.
  `with: [commitEvery: 10_000]`).
- For an **index-deferred incremental** load, order it yourself: create the type, bulk-load the
  rows (a `command/4` loop or one `transaction/3`), then create the index — a `LSM_TREE`/dense
  `LSM_VECTOR` index retro-indexes existing rows, but a `LSM_SPARSE_VECTOR` index must be created
  BEFORE the load (see `Arcadic.Vector`). arcadic ships no generic index-deferral helper because
  the correct ordering is index-type-specific.
- For batched **incremental** writes, wrap them in `transaction/3` (one commit for many
  statements) instead of auto-committing each `command/4`.
- **Choosing a bulk-write path.** Three options, in order of what they optimize for:
  - **`Arcadic.Bulk.ingest/3`** (`POST /api/v1/batch`) — records held client-side, one
    atomic NDJSON POST. Vertices carry a structural `"@id"` temp key that edges
    reference via `"@from"`/`"@to"`; the response's `id_mapping` maps each temp `"@id"`
    to its assigned real RID. **Create-only** (no dedup) — a retry after a lost
    response duplicates every record. Best for a graph you're building in one shot from
    in-memory data.
  - **`Arcadic.Import.database/3`** — server-side fetch of a CSV/JSON/GraphML/
    Neo4j/OrientDB/ArcadeDB export. Best for large or already-serialized loads (the
    server streams it, not the client).
  - **The idempotent `UNWIND $rows` idiom** — for a bulk **upsert** (as opposed to
    create-only), unwind a list-of-maps param through `MERGE`:
    ```elixir
    Arcadic.command(conn, "UNWIND $rows AS r MERGE (n:T {id: r.id}) SET n += r.props", %{"rows" => rows})
    ```
    Safe to replay — `MERGE` matches existing rows instead of duplicating them, unlike
    `Arcadic.Bulk.ingest/3`.

## Non-negotiable rules

- **Parameters only.** Every dynamic value goes into the request `params` map and
  is referenced by a placeholder in the statement — **`$name` for Cypher, `:name`
  for SQL** (see Parameter binding below; never interpolate a value into a
  Cypher/SQL string — that is a query-injection defect). This holds for
  `query/4`, `command/4`, `command_async/4`, `query_stream/4`, `explain/4`,
  `profile/4`, and inside `transaction/3`.
- **Redact at the boundary.** Errors and logs carry structure only.
  `Arcadic.Error` exposes a typed `reason`, `http_status`, and `exception` class;
  its `detail` field is quarantined (absent from `message/1` and `inspect/1`).
  `Arcadic.TransportError` carries only the value-free reason atom. Never surface
  raw parameter values or response rows.
- **Validate identifiers.** Database names and other identifiers reaching a URL
  path or statement go through `Arcadic.Identifier.validate/1` first (a failure
  carries the invalid-shape fact only, never the offending string). Values are
  never identifiers — they ride `params`.

## Parameter binding

**SQL binds `:name`; Cypher binds `$name`.** A `$name` placeholder in a
`language: "sql"` statement binds to **null** (ArcadeDB does not error — a silent
mis-bind); a `:name` placeholder in Cypher (or any default-language call) is a
**parse error**.

```elixir
# SQL
Arcadic.query(conn, "SELECT FROM User WHERE name = :name", %{"name" => n}, language: "sql")
# Cypher (default language)
Arcadic.query(conn, "MATCH (u:User {name: $name}) RETURN u", %{"name" => n})
```

**Typed param-value wrappers (`Arcadic.Param`).** A param *value* that is a single-key
`%{"$int8" => list}` or `%{"$bytes" => base64}` map is decoded server-side to a `byte[]`
before the query runs — `Arcadic.Param.int8/1` / `bytes/1` build these. The statement
still references the parameter by the normal placeholder (`:name`/`$name`). **HTTP-only**
(inert over Bolt) and requires ArcadeDB ≥ 26.5.1. **Ambient single-key-collision caveat:**
ArcadeDB decodes *any* single-key `{"$int8" => …}` / `{"$bytes" => …}` value it finds in
`params`, whether or not it came from `Arcadic.Param` — a legitimate caller value that
happens to be exactly a single-key map with one of those keys is reinterpreted as a
`byte[]`; add a second key to a map you want left untouched.

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

`Arcadic.Error.reason`: `:not_idempotent` (write via `query/4`), `:parse_error`,
`:unauthorized` (auth failure, or a blocked private/loopback import URL),
`:database_not_found`, `:transaction_error` (server fault, or client-side session
misuse), `:concurrent_modification`, `:duplicate_key`, `:timeout` (server-side
statement timeout — distinct from the client-side `TransportError` below),
`:invalid_begin_body` (bad `:isolation` on `transaction/3`), `:server_error`
(generic fallback), `:use_explain` (call `explain/4`/`profile/4` instead), and
`:not_supported` (the transport lacks the called capability, e.g. `explain/4`
without a transport impl, HTTP streaming in a transaction, Bolt database admin —
or the statement/opts fail a streaming-eligibility check).

`Arcadic.TransportError.reason` is a connection-level failure with **no HTTP
response** — the underlying transport's own atom, not a fixed enum: for HTTP,
whatever Mint/Finch reports (e.g. `:timeout`, `:closed`, `:econnrefused`); for
Bolt, `:timeout` (a RUN/PULL receive timeout), `:bolt_protocol_error`,
`:transaction_error`, `:cursor_open`/`:cursor_already_open` (the stream
interleaving guard), a `boltx` error code, or `:unknown`.

A separate, non-`Arcadic.Error` convention: value-free bare-atom validation
failures, never echoing the offending value. `{:error, :invalid_identifier}`
(`Arcadic.Identifier.validate/1` — e.g. a bad type name to
`Arcadic.Schema.properties/2`, or a bad database/user name on the admin
surface); `{:error, :invalid_setting_key}` / `{:error, :invalid_setting_value}`
(`Arcadic.Server.set_server_setting/3` / `set_database_setting/3`);
`{:error, :invalid_url}` (`Arcadic.Backup.backup/2`'s `:to` target and
`restore/3`'s source URL); `{:error, :invalid_user_spec}`
(`Arcadic.Security.create_user/2` — an unencodable user spec, e.g. a non-UTF-8
password); and, from `Arcadic.Bulk.ingest/3`, `{:error, :invalid_record}` (a
record that fails to encode), `{:error, :not_supported}` (the transport has no
batch endpoint, e.g. Bolt), and `{:error, :unexpected_response}` (a non-map 2xx
body — off-contract).

## Telemetry

Value-free `:telemetry.span/3` spans; metadata is validated against the fixed
allowlist in `Arcadic.Telemetry.allowed_meta_keys/0`: `:language`, `:mode`,
`:http_status`, `:reason`, `:row_count`, `:in_transaction?`, `:isolation`,
`:async?`, `:operation`. No statement, params, values, or database name ever
rides telemetry.

- `[:arcadic, :query, :start | :stop | :exception]` — `query/4`.
- `[:arcadic, :command, :start | :stop | :exception]` — `command/4` and
  `command_async/4` (the latter's metadata carries `:async? true`).
- `[:arcadic, :explain, :start | :stop | :exception]` — `explain/4` (`:mode`
  `:read`) and `profile/4` (`:mode` `:write`, carries `:in_transaction?`, since
  PROFILE executes).
- `[:arcadic, :query_stream, :start]` / `[:arcadic, :query_stream, :stop]` — every
  HTTP and Bolt stream path (manual `:telemetry.execute/3` events, not a span — no
  `:exception` variant); `:stop` carries `reason: :ok | :halted` plus a
  `:row_count` measurement.
- `[:arcadic, :transaction, :start | :stop | :exception]` — `transaction/3`
  (metadata carries `:isolation`).
- `[:arcadic, :vector, :sparse_index_preexisting]` — see `Arcadic.Vector` above.
- `[:arcadic, :admin, :start | :stop | :exception]` — every `Arcadic.Server` /
  `Arcadic.Security` / `Arcadic.Backup` call (metadata carries `:operation`,
  the atom naming the call, e.g. `:login`, `:set_database_setting`,
  `:restore`, plus `:reason` on `:stop`).
- `[:arcadic, :bulk, :start | :stop | :exception]` — `Arcadic.Bulk.ingest/3`
  (`:stop` carries `:row_count`, the sum of vertices + edges created).

`:start` measurements are `:telemetry.span/3`'s standard `:system_time`/
`:monotonic_time`; `:stop`/`:exception` carry `:duration`/`:monotonic_time`.

## Bolt transport (optional)

The `Arcadic.Transport.Bolt` adapter (optional `boltx` dependency) runs the query
hot path over Bolt. Build it with `Arcadic.Transport.Bolt.setup/1`, which pins Bolt
to **v4** (`versions: [4.4, 4.3, 4.2, 4.1]` — ArcadeDB speaks v4; boltx defaults to
v5), uses the non-TLS **`bolt` scheme** (ArcadeDB Bolt is TLS-disabled by default),
and takes `username`/`password`. `setup/1` starts the pool AND returns the
`transport_options` for `Arcadic.connect/3` in one call — `[bolt: pool, bolt_opts:
resolved]` — carrying both the pool (`:bolt`, for `execute`/`transaction`/`ready?`)
and the resolved per-stream connect opts (`:bolt_opts`, for `query_stream/4`); pass
its return value straight through as `transport_options`. Do NOT hand-build
`transport_options: [bolt: pool]` alone (`start_link/1`'s bare return) — it omits
`:bolt_opts` and makes `query_stream/4` return `{:error, %Arcadic.Error{reason:
:not_supported}}`.
**Admin (`Arcadic.Server`, `Arcadic.Security`, `Arcadic.Backup`) is HTTP-only** —
use an HTTP conn for admin even when queries run over Bolt (`with_bearer/2` also
raises on a Bolt conn). **Vector search is HTTP-only too** —
`Arcadic.Vector` (`LSM_VECTOR` / `LSM_SPARSE_VECTOR`) runs SQL, and Bolt is
Cypher-only (a `SELECT` over Bolt is a syntax error; the Bolt `RUN` carries no
SQL-language selector), so keep vector queries on the HTTP transport.

**`BOLT_*` env vars are rejected.** arcadic **raises** if `BOLT_USER`, `BOLT_PWD`,
`BOLT_HOST`, or `BOLT_TCP_PORT` is set in the environment — at pool setup
(`start_link/1`/`setup/1`) **and** on every connect/reconnect. boltx reads those with
precedence over arcadic's explicit config and re-reads them at connect time, so a var
set after startup would otherwise silently override the connection or its credentials;
the connect-time reject closes that window. Unset the var and pass
`:scheme`/`:hostname`/`:port`/`:username`/`:password` explicitly.

See `AGENTS.md` for the full working rules and the verified ArcadeDB HTTP contract.
