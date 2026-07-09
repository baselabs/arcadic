# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Arcadic.explain/4` + `Arcadic.profile/4` (+ `!`) — surface the ArcadeDB EXPLAIN/PROFILE plan
  (`%{plan, plan_tree, rows}`) that `query`/`command` silently dropped. `explain` is plan-only;
  **`profile` executes the statement** (a write mutates). Works over HTTP and Bolt (Cypher-only).
- `query`/`command`/`query_stream` now return `{:error, %Arcadic.Error{reason: :use_explain}}` on a
  bare EXPLAIN/PROFILE (was a silent `{:ok, []}`).

### Fixed

- Docs: SQL `:name` vs Cypher `$name` parameter binding is now documented; the Bolt-streaming
  example uses `Arcadic.Transport.Bolt.setup/1` (the prior `transport_options: [bolt: …]` form
  returned `:not_supported` for streaming); `~> 0.4` install pins; hexdoc module groups.

### Notes

- Re-verified boltx temporal decode against ArcadeDB 26.8.1 (`:integration_bolt` green).

## [0.4.0] - 2026-07-07

### Added

- `Arcadic.Schema` — tenant-blind schema introspection: `types/1`, `properties/2`, `indexes/2`
  (with a `:type` filter), `buckets/1`, and `database/1` (the engine config, `schema:database`)
  (all + `!`). SQL-only `SELECT FROM schema:*`; a caller type
  name binds as a `$param` and is `Identifier`-shape-guarded (value-free); ArcadeDB's `@props`
  serializer noise is deep-stripped at every nesting depth.
- `Arcadic.Import` — `database/3` (+ `!`) wrapping `IMPORT DATABASE`. The source URL is validated
  against a positive character allowlist (closing the interpolated-URL injection surface, since the
  URL cannot be a bound parameter and ArcadeDB honours backslash-escapes inside string literals) and
  a scheme allowlist (`http`/`https`/`file`); `with:` accepts number, boolean, and charset-allowlisted
  string settings, emitted as ArcadeDB's no-parens `WITH k = v` grammar. Import
  errors are reflected faithfully — a private/loopback host trips ArcadeDB's SSRF guard
  (`:unauthorized` / `java.lang.SecurityException`, distinct from an auth failure's
  `ServerSecurityException` via `error.exception`).
- `Arcadic.Export` — `database/3` (+ `!`) wrapping `EXPORT DATABASE file://<name>`, symmetric to
  `Arcadic.Import`: the bare export name is path-traversal-guarded (value-free), and `with:` reuses
  the same number/boolean/string settings grammar.
- HTTP `query_stream` pages WHERE-less SQL by an O(n) `@rid` keyset cursor (offset fallback for
  WHERE'd statements) and supports Cypher streaming via a caller `order_key: "id(v)"` (offset,
  `$name` placeholders). The comment guard is language-aware (`//` rejected for Cypher). Inside
  `transaction/3` over Bolt, streaming uses the O(n) in-transaction cursor.
- Transaction-scoped Bolt streaming — `query_stream/4` inside `transaction/3` streams over the
  transaction's own connection (sees uncommitted writes), guarded so an `execute` cannot interleave
  an open cursor on the shared socket; the cursor callbacks disconnect on a wire fault (desync-safe).
  Consume the stream inside the `transaction/3` body (it is bound to the tx connection).
- Bolt over TLS — `scheme: "bolt+s"` with `ssl_opts`. `bolt+s` is **secure by default**
  (`verify_peer` against the OS trust store, via boltx's inverted `bolt+ssc` scheme under the
  hood); `ssl_opts: [verify: :verify_none]` is an explicit caller opt-in to skip verification.
  A `:uri` opt is rejected (it would bypass the scheme translation and silently skip verification).
- Bolt now fails loud if a `BOLT_USER`/`BOLT_PWD`/`BOLT_HOST`/`BOLT_TCP_PORT` environment variable is
  set — both at pool setup (`start_link/1`/`setup/1`) and again on every connect/reconnect, because
  boltx re-reads them with precedence over arcadic's explicit config at connect time (so a var set
  after startup is caught too); unset the var.

### Changed

- Bolt RUN/PULL wire-framing is deduplicated to a single site (`stream_run`/`stream_pull`), shared by
  the non-transaction stream and the in-transaction cursor callbacks.

### Fixed

- `Arcadic.query/4`, `command/4`, and `query_stream/4` now reject a non-keyword-list `opts`
  with a value-free `ArgumentError` (`"opts must be a keyword list"`). Previously an improper-list
  `opts` (e.g. `[:foo]`) raised a `Keyword` error whose message echoed the offending entry — a
  Rule-3 value leak on the core query paths. The opt-key guard is now shared across the query,
  `Schema`, `Import`, and `Vector` surfaces.

### Notes

- Documented an upstream ArcadeDB **server** hazard for operators running Bolt over TLS (older
  builds): a single untrusted-cert TLS handshake failure could wedge ArcadeDB's shared Bolt listener
  (~100% CPU, no ServerHello for any client) until the server restarts. arcadic's client-side TLS is
  unaffected. **Re-verified FIXED on ArcadeDB 26.8.1-SNAPSHOT (2026-07-09):** after a `verify_peer`
  `unknown_ca` rejection the listener kept answering ServerHello for all subsequent clients at idle
  CPU (throwaway-container probe). The operator note is version-qualified, not removed (older builds
  are still affected — observed on `latest` as of 2026-07-06). Tracked upstream at
  [ArcadeData/arcadedb#5106](https://github.com/ArcadeData/arcadedb/issues/5106).

## [0.3.0] - 2026-07-05

### Added

- `Arcadic.Vector` sparse + hybrid completion:
  - `create_sparse_index/5` (+ `!`), `drop_sparse_index/4` (+ `!`), `sparse_neighbors/8` (+ `!`)
    over ArcadeDB `LSM_SPARSE_VECTOR` indexes (`(tokens, weights)` pair; rows ranked by top-level
    `score`). `create_sparse_index` opts: `dimensions`, `modifier` (`:none` | `:idf`).
  - `filter` (param-bound candidate RID set), `group_by`, and `group_size` opts on `neighbors/6`,
    `sparse_neighbors/8`, and `fuse/3`.
  - A `[:arcadic, :vector, :sparse_index_preexisting]` telemetry event when a sparse index is
    created over rows that already exist (which a sparse index does not retro-index).

## [0.2.1] - 2026-07-05

### Fixed

- Install instructions in the README and getting-started notebook pointed at a pre-publish
  path dependency and `~> 0.1`; corrected to `{:arcadic, "~> 0.2"}` from Hex.

### Added

- README: Hex.pm + hexdocs badges, a Benchmarks section (linking the `bench/` harness and the
  100k result set), and a Bulk-loading note; `usage-rules.md` bulk-loading entry
  (`IMPORT DATABASE` / `transaction/3`).

_No library code changed in this release — docs/packaging only._

## [0.2.0] - 2026-07-05

### Added

- `Arcadic.Vector` — dense vector search over ArcadeDB `LSM_VECTOR` indexes:
  `create_dense_index/5` (+ `!`), `drop_dense_index/3` (+ `!`), `neighbors/6` (+ `!`),
  `fuse/3` (+ `!`), and `index_ref/2`. Tenant-blind; the query vector, `k`, `ef_search`,
  and `max_distance` bind as params; index refs are identifier-validated; metadata
  keys/values and query/fusion option inputs are allowlisted and validated value-free
  (`similarity`, `encoding`, `quantization`, `fusion` against their ArcadeDB enums).
  `neighbors/6` rows carry a `distance` whose scale depends on the index `similarity`
  (COSINE `0..1` ascending; DOT_PRODUCT negative); `fuse/3` rows are ranked by `score`.
  Sparse retrieval and the Ash-native surface are named non-goals.

## [0.1.0] - 2026-07-04

### Added

- `Arcadic.Conn` — pure-data connection handle (redacting `Inspect`) and
  `Arcadic.connect/3` / `Arcadic.with_database/2` to build and derive handles.
- `Arcadic.query/4` + `query!/4` (idempotent read endpoint) and
  `Arcadic.command/4` + `command!/4` (write endpoint), params-only (`$name`),
  Cypher-default with SQL/Gremlin/GraphQL/Mongo/SQLScript opt-in.
- `Arcadic.command_async/4` — fire-and-forget write (server enqueues, returns
  `:ok` on HTTP 202).
- Session transactions: `Arcadic.transaction/3` (commit on return, reraise on
  exception) and `Arcadic.rollback/2` (intentional abort → `{:error, reason}`).
- `Arcadic.Server` — server admin: `create_database/2` (+ `!`), `drop_database/2`
  (+ `!`), `database_exists?/2`, `list_databases/1`, `ready?/1`.
- `Arcadic.Error` / `Arcadic.TransportError` — typed error taxonomy with
  boundary redaction (quarantined `detail`, value-free reasons).
- `Arcadic.Transport` — the transport behaviour seam, with the default
  `Arcadic.Transport.HTTP` (Req/Finch) implementation.
- `Arcadic.Telemetry` — value-free `:telemetry.span/3` spans (no statement,
  params, values, or database name).
- `Arcadic.Identifier` — allowlist identifier validation.
- Migration runner: `Arcadic.Migration` (behaviour), `Arcadic.MigrationRegistry`
  (`use` + `migrations [...]`), and `Arcadic.Migrator` (`migrate/2`, `status/2`,
  `rollback/3`, `reset/2`, `pending_migrations/2`), tracking applied versions in
  `_arcadic_migrations`.
- `Arcadic.Transport.Bolt` — optional Bolt transport (Bolt v4, non-TLS scheme)
  via the optional `boltx` dependency; server admin remains HTTP-only.
- `Arcadic.query_stream/4` — Bolt-only lazy `Stream.t()` of raw row maps, chunked
  over Bolt `PULL`/`has_more` (default `chunk_size: 1000`); a `:timeout` opt bounds
  each RUN/PULL receive (default `:infinity`), raising
  `%Arcadic.TransportError{reason: :timeout}` on breach; guarded off HTTP and inside
  transactions with a typed `:not_supported`.
- `Arcadic.Transport.Bolt.setup/1` — single-source `transport_options` builder
  (`[bolt: pool, bolt_opts: opts]`).
- `Arcadic.Telemetry.event/3` — allowlist-validated manual telemetry for lazy ops;
  `[:arcadic, :query_stream, :start | :stop]` events (value-free).

### Fixed

- `Arcadic.Transport.Bolt` now threads `conn.database` into every Bolt RUN/BEGIN, so
  `with_database/2` selects the database on Bolt (was hitting the connection default).
- Bolt `transaction/3` maps a commit-failure to a typed `%Arcadic.Error{reason:
  :transaction_error}` instead of leaking DBConnection's bare `:rollback` atom.
- `Arcadic.Transport.Bolt` — a failed Bolt connect (wrong password, or a Bolt conn
  pointed at a non-Bolt port) no longer leaks a `:gen_tcp` socket. arcadic now owns the
  connect handshake and HELLO on both the per-stream connection and the DBConnection
  pool, closing the socket on every failure; a bad-password stream connect surfaces
  `:unauthorized`, and the connect HELLO is bounded by `connect_timeout`. Connect-time
  errors are redacted on both sites: a HELLO response arcadic's parser cannot classify
  returns a value-free `:bolt_protocol_error` instead of a raw exception carrying server
  bytes, and the DBConnection pool's connect error drops the server-supplied failure
  message (keeping the error code/class) so it cannot ride a connect-failure log line.
