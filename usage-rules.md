# arcadic usage rules

_A framework-agnostic Elixir client for ArcadeDB over the HTTP Cypher command API._

## What arcadic is (and is not)

- **Is:** a thin transport. Sends Cypher/SQL to ArcadeDB's HTTP command API,
  manages connections and session transactions, normalizes responses.
- **Is not:** Ash-aware, tenant-aware, or classification-aware. Never put
  multitenancy or sensitive-data logic here — that is `ash_arcadic`'s job.

## Public surface

- **`Arcadic`** — `connect/3`, `with_database/2`; `query/4` + `query!/4`
  (idempotent read endpoint), `command/4` + `command!/4` (write endpoint),
  `command_async/4` (fire-and-forget, returns `:ok` on 202); `transaction/3` and
  `rollback/2` for session transactions. Non-bang calls return `{:ok, rows}` or
  `{:error, %Arcadic.Error{} | %Arcadic.TransportError{}}`. Default language is
  `"cypher"`; opt into `sql`/`gremlin`/`graphql`/`mongo`/`sqlscript` per call.
- **`Arcadic.Conn`** — a pure-data connection handle (no process). Its `Inspect`
  redacts auth and session id.
- **`Arcadic.Server`** — server admin: `create_database/2` (+ `!`),
  `drop_database/2` (+ `!`), `database_exists?/2`, `list_databases/1`, `ready?/1`.
- **Migrations** — `Arcadic.Migration` (behaviour: `version/0`, `up/1`, `down/1`),
  `Arcadic.MigrationRegistry` (`use` + `migrations [...]`), `Arcadic.Migrator`
  (`migrate/2`, `status/2`, `rollback/3`, `reset/2`, `pending_migrations/2`),
  tracking applied versions in `_arcadic_migrations`.
- **`Arcadic.Vector`** — dense + sparse vector search over ArcadeDB `LSM_VECTOR` /
  `LSM_SPARSE_VECTOR`: `create_dense_index/5`, `drop_dense_index/3`, `neighbors/6`,
  `fuse/3`, `index_ref/2`, plus `create_sparse_index/5`, `drop_sparse_index/4`,
  `sparse_neighbors/8` (all + `!`). Tenant-blind; query vector / tokens / weights / `k` /
  `ef_search` / `max_distance` bind as params, index refs are identifier-validated, and
  metadata / query / fusion option inputs are allowlisted and validated value-free.
  Shared opts on `neighbors` / `sparse_neighbors` / `fuse`: `filter` (non-empty
  `#bucket:pos` RID candidate set), `group_by` (`Identifier`-shape-guarded), `group_size`
  — all param-bound. `distance` scale is similarity-dependent; `fuse/3` and
  `sparse_neighbors/8` rank by `score` (sparse rows carry no `distance`). Create sparse
  indexes **before** loading rows — they do not retro-index existing data (a
  `[:arcadic, :vector, :sparse_index_preexisting]` telemetry event fires if you do).
- **`Arcadic.Schema`** — read-only schema introspection: `types/1`, `properties/2`,
  `indexes/2` (with a `:type` filter), `buckets/1` (all + `!`). SQL-only `SELECT FROM
  schema:*`; a caller type name binds as a `$param` and is `Identifier`-shape-guarded;
  ArcadeDB's `@props` serializer noise is deep-stripped at every depth. `indexes/2` returns
  both logical and physical per-bucket rows (filter on `fileId` absence for logical-only).
- **`Arcadic.Import`** — `database/3` (+ `!`): `IMPORT DATABASE` bulk load. The source URL is
  interpolated (ArcadeDB rejects a bound `:url`) behind a positive character + scheme
  (`http`/`https`/`file`) allowlist that closes the SQL-literal injection surface, value-free on
  rejection; `with:` takes number/boolean settings. A private/loopback host trips ArcadeDB's SSRF
  guard (`:unauthorized` / `java.lang.SecurityException`, distinct from an auth failure via
  `error.exception`); `file://` is server-local.
- **`Arcadic.Transport`** — the transport behaviour seam; `Arcadic.Transport.HTTP`
  (Req/Finch) is the default, `Arcadic.Transport.Bolt` is the optional Bolt one.
- **`Arcadic.Error` / `Arcadic.TransportError`** — the typed error taxonomy.
- **`Arcadic.Telemetry`** — value-free `:telemetry.span/3` spans.
- **`Arcadic.Identifier`** — allowlist identifier validation.

## Bulk loading

- For a **large initial load**, prefer ArcadeDB's server-side import over an `INSERT`/`CREATE EDGE`
  loop: `Arcadic.Import.database(conn, "https://host/export.jsonl.tgz")` imports CSV / JSON /
  GraphML / Neo4j / OrientDB / ArcadeDB exports. The source URL is validated (positive character +
  scheme allowlist, value-free) rather than hand-interpolated — do NOT hand-build an
  `IMPORT DATABASE '<url>'` string, which reopens the injection surface. The URL must be reachable
  by the SERVER; ArcadeDB blocks private/loopback hosts by default, so use a public URL or a
  server-local `file://`. Optional `with:` number/boolean settings tune the load (e.g.
  `with: [commitEvery: 10_000]`).
- For an **index-deferred incremental** load, order it yourself: create the type, bulk-load the
  rows (a `command/4` loop or one `transaction/3`), then create the index — a `LSM_TREE`/dense
  `LSM_VECTOR` index retro-indexes existing rows, but a `LSM_SPARSE_VECTOR` index must be created
  BEFORE the load (see `Arcadic.Vector`). arcadic ships no generic index-deferral helper because
  the correct ordering is index-type-specific.
- For batched **incremental** writes, wrap them in `transaction/3` (one commit for many
  statements) instead of auto-committing each `command/4`.

## Non-negotiable rules

- **Parameters only.** Every dynamic value goes into the request `params` map and
  is referenced as `$name` in the statement. Never interpolate a value into a
  Cypher/SQL string — that is a query-injection defect. This holds for
  `query/4`, `command/4`, `command_async/4`, and inside `transaction/3`.
- **Redact at the boundary.** Errors and logs carry structure only.
  `Arcadic.Error` exposes a typed `reason`, `http_status`, and `exception` class;
  its `detail` field is quarantined (absent from `message/1` and `inspect/1`).
  `Arcadic.TransportError` carries only the value-free reason atom. Never surface
  raw parameter values or response rows.
- **Validate identifiers.** Database names and other identifiers reaching a URL
  path or statement go through `Arcadic.Identifier.validate/1` first (a failure
  carries the invalid-shape fact only, never the offending string). Values are
  never identifiers — they ride `params`.

## Bolt transport (optional)

The `Arcadic.Transport.Bolt` adapter (optional `boltx` dependency) runs the query
hot path over Bolt. Start it with `Arcadic.Transport.Bolt.start_link/1`, which
pins Bolt to **v4** (`versions: [4.4, 4.3, 4.2, 4.1]` — ArcadeDB speaks v4;
boltx defaults to v5), uses the non-TLS **`bolt` scheme** (ArcadeDB Bolt is
TLS-disabled by default), and takes `username`/`password`. Pass the connection
reference as `transport: Arcadic.Transport.Bolt, transport_options: [bolt: ref]`.
**Server admin (create/drop/list database) is HTTP-only** — use an HTTP conn for
admin even when queries run over Bolt.

See `AGENTS.md` for the full working rules and the verified ArcadeDB HTTP contract.
