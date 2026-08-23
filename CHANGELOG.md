# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-08-23

### Added

- **`request_timeout` — the whole-response bound.** New conn field/connect opt
  (`Arcadic.connect/3, request_timeout: ms`), per-call override on
  `Arcadic.query/command` (`request_timeout:`), and transport wiring on every
  HTTP request site (`post/4`, `raw_get/3`, `batch_ingest`, `ts_write`). It maps
  to Finch's `request_timeout`, bounding the COMPLETE response — the hazard
  class `receive_timeout` (max wait per received chunk) cannot bound: a peer
  that trickles bytes can otherwise hold a call open indefinitely. Default
  `nil` keeps Finch's own default (`:infinity`) — existing conns are unchanged.
  Proven on a real socket: a 20-byte trickle at 200 ms intervals under
  `timeout: 60_000` is killed at ~400 ms by `request_timeout: 400`
  (`TransportError{reason: :timeout}`); the same trickle with no
  `request_timeout` completes. Mutation-red-proven (dropping the wiring reds
  exactly the kill test).

### Fixed

- `Arcadic.connect/3` now REJECTS a `base_url` carrying userinfo together with
  an explicit `:auth` (value-free `ArgumentError`). At the HTTP layer the URL
  credentials silently override the Authorization header, so a caller
  deliberately overriding credentials via `:auth` would send the URL's instead.

### Changed

- `req` floor bumped `~> 0.5` → `~> 0.7` (0.7 is where `request_timeout`
  exists as a request option; resolved 0.7.3, full suite green on it).

## [1.0.0] - 2026-08-22

The first stable release: the full client surface (HTTP, Bolt, gRPC) is
feature-complete, every dependency-security advisory is closed, and the entire
139-test integration surface is live-proven (see **Verified** below). 1.0.0 is
a compatibility commitment for the public API.

### Historical backfill

Surface that shipped in earlier releases without a changelog entry, recorded
here for the 1.0 record:

- The `:retries` command option (server-side optimistic-lock retry for
  concurrent autocommit writes) has existed since v0.1.0
  (`http.ex` — forwarded to ArcadeDB's `retries` body param). It was first
  DOCUMENTED in the 0.7.1-era reliability work with a live tripwire
  (100 concurrent writers, ~85 conflicts without → 0 with `retries: 10`).
- `Arcadic.Transport.execute_with_index/4` — the offset-paging read
  underlying HTTP result streaming.
- `Arcadic.DDLBody` (internal) — the reject-not-escape guard for ArcadeDB
  DDL body literals (`DEFINE FUNCTION` / `CREATE TRIGGER`), and
  `Arcadic.Admin` (internal) — the shared, value-free admin span + transport
  delegation plumbing. Both `@moduledoc false` by design; named here so the
  security-relevant guard is on the record.
- `notebooks/operations.livemd` — the change-events / functions / triggers /
  materialized-views / geo notebook (the fourth Livebook, alongside
  getting_started, graphrag, and timeseries).

### Verified

- **Live-verification record (2026-08-22, `arcadedata/arcadedb:latest` =
  26.9.1-SNAPSHOT, throwaway containers on this host):** the ENTIRE
  139-test integration surface — every test excluded from the default
  unit pass — ran green in one session on the post-migration tree:
  HTTP `:integration` 55 (incl. the server-side `:retries` tripwire),
  websocket 6, time-series 10, `:integration_grpc` 38 (grpc 1.0.4 + mint
  adapter), `:integration_grpc_tls` 5, `:integration_shutdown` 1, and the
  Bolt family — `:integration_bolt` 22 (bolt, bolt_explain, bolt_stream,
  tx-scoped B6 streaming) + `:integration_bolt_tls` 2 (verify_peer
  connects with the trusted CA; fails closed untrusted). Bolt substrate
  recipes (plugin flag, both env families, the `arcadedb.ssl.*` keystore
  spellings) are recorded in `bolt_test.exs`'s moduledoc; TLS material
  for the grpc and Bolt suites comes from
  `test/support/tls/gen-grpc-certs.sh` (now also emitting the server-side
  PKCS12 keystore + JKS truststore).

### Added

- gRPC TLS trust-store selection + a live fail-closed suite. `grpcs://` still
  hardcodes `verify: :verify_peer` (never `verify_none`), but callers may now
  select a private CA via `transport_options: [cacertfile: path]` (or
  `cacerts:` as a DER list) — an allowlist merge, so a caller chooses the
  trust store but cannot downgrade verification itself. The trust selection
  is part of the `ChannelPool` key (`{host, port, tls?, trust}`), so pooled
  channels never cross trust stores (a cross-vendor review finding: with the
  old key, a channel established under one trust anchor was silently reused
  by conns with a different trust config — fail-closed would have become
  first-conn-wins through the pool); passing both `cacertfile` and `cacerts`
  is rejected value-free instead of letting OTP precedence silently pick one.
  New `:integration_grpc_tls` live suite closes the long-standing "no live
  TLS coverage" gap: cert recipe (`test/support/tls/gen-grpc-certs.sh`) + a
  TLS-enabled gRPC ArcadeDB (recipe in the test moduledoc; on ARM64 images
  add `-Dio.grpc.netty.shaded.io.netty.handler.ssl.noOpenSsl=true` to dodge
  netty-tcnative's LSE-atomics crash). Proven live: trusted CA connects and
  executes; an untrusted CA and the bare OS store both fail the handshake —
  pooled and unpooled, each with its own liveness anchor — and non-vacuous:
  a scratch `verify_none` mutation reddens both fail-closed tests, and the
  pool-crossing test was observed RED before the key fix.

### Fixed

- Restore the `mix format --check-formatted` gate: the vendored generated
  protobuf module (`lib/arcadic/transport/grpc/proto/`) is excluded from
  formatter inputs, and the live `:retries` tripwire integration test —
  committed unformatted — is reformatted.
- Restore the `mix compile --warnings-as-errors` gate: drop the unreachable
  `{:error, {:already_started, _}}` clause in the gRPC client-supervisor
  bootstrap (Elixir 1.20 type analysis proves it dead; the catch-all already
  evaluated to the same `:ok`, so behavior is unchanged).

### Security

- Dependency lock refresh clears every advisory with a released fix: mint
  1.9.3, hpax 1.0.4, bandit 1.12.5, plug 1.20.3, cowboy 2.18.0, cowlib
  2.19.0, gun 2.5.0 (plus plug_crypto/ranch rides). The composite `mix audit`
  gate dropped from 21 advisories to 8; the remainder (grpc 0.11.5's
  CRITICAL + 3 HIGH, plus gun/cowlib advisories unpatched upstream) is fully
  resolved by the grpc 1.x migration below.
- **grpc 1.x migration** (`~> 0.11` → `~> 1.0`, locked 1.0.4): closes every grpc
  advisory — CRITICAL CVE-2026-48853 (RCE via erlpack deserialization) plus HIGHs
  CVE-2026-48599/53430/48854 — all fixed in grpc 1.0.0. The channel pins the
  mint adapter explicitly (grpc 1.x defaults to gun): mint 1.9.3 is patched and
  already a runtime dependency via req, and the move drops gun/cowboy/cowlib
  from the dependency tree entirely — their advisories (unpatched upstream at
  the latest published versions) leave the tree with them. `mix audit` is now
  fully green: zero advisories, zero retired packages. Internal to the
  migration: the 0.11 lazy client-supervisor bootstrap is gone (grpc 1.x
  auto-starts its own connection supervisor), and `ChannelPool` now
  best-effort-disconnects a stale cached channel when reconnecting replaces
  it (cross-vendor review finding: grpc 1.x owns connection processes under
  its own supervisor with random names, so dropping the handle without
  disconnecting would orphan that connection tree); pool teardown is
  best-effort for the same reason. Verified live against ArcadeDB
  26.9.1-SNAPSHOT (gRPC suite 38/38; HTTP 55, websocket 6, time-series 10,
  shutdown 1 on the refreshed lock). Consumers pinning grpc 0.11.x will see
  a resolver conflict — intended; re-pin to `~> 1.0`.

### Changed

- ArcadeDB 26.9.x substrate drift, pinned in the live suites (characterization
  re-pins, verified against 26.9.1-SNAPSHOT): a mixed line-protocol write with
  an unknown timeseries type still partially writes (the known line lands) but
  now answers HTTP 400 with a structured partial-write body instead of the
  26.7.2 silent 200 — arcadic maps it value-free to
  `{:error, %Arcadic.Error{reason: :server_error}}`; and `Server.shutdown/1`
  halts asynchronously (graceful drain can outlive the ack), so the live suite
  polls health with a bounded deadline.
- Align the contributor guide with the released 0.7.1 surface and the
  post-release server-side `retries:` documentation and live tripwire already
  present on `main`.

## [0.7.1] - 2026-07-14

### Changed

- Docs: the README and `usage-rules.md` now document the **gRPC transport** (`Arcadic.Transport.Grpc`)
  alongside HTTP and Bolt — the 0.7.0 release shipped the transport but the README/hexdocs still
  described only HTTP + Bolt. No code change (maintenance release for documentation currency).

## [0.7.0] - 2026-07-14

### Added

- `Arcadic.Server.database_info/1` — database-level info (`%{database, type, records, classes,
  size_bytes}`) for the connection's database. Over gRPC it maps to `GetDatabaseInfo` (all fields);
  over HTTP to `SELECT FROM schema:database` (name/size; record and class counts are `nil`, not
  cheaply available on that transport).
- `Arcadic.Transport.Grpc` — an optional third transport over ArcadeDB's gRPC plugin, behind the
  new optional deps `{:grpc, "~> 0.11"}` and `{:protobuf, "~> 0.17"}`. Its headline is streaming:
  `StreamQuery` in `CURSOR` mode is a real server cursor (O(n), server-paced, language-agnostic),
  where HTTP result streaming offset-pages (O(n²) in the general case) and Bolt streams Cypher only.
  The transport implements the full surface it can support:
  - **Reads/writes** — `execute/4` (`ExecuteQuery`/`ExecuteCommand`) and `query_stream/4` (the CURSOR win).
  - **Transactions** — `begin`/`commit`/`rollback`, so `Arcadic.transaction/3` and tx-scoped
    reads/writes work over gRPC.
  - **Bulk graph ingest** — `Arcadic.Bulk.ingest/3` (via `GraphBatchLoad`), the gRPC twin of the HTTP
    `/batch` endpoint (same counts/`id_mapping` result; transport-transparent).
  - **`Arcadic.Ingest`** — document bulk-insert into a class (`BulkInsert`, or `InsertStream` via
    `:chunk_size`), returning insert-summary counts.
  - **`Arcadic.Record`** — single-record create/lookup/update/delete by `@rid` (raw maps).
  - **Admin** — `Arcadic.Server` database management (`list_databases`/`database_exists?`/`create_database`/
    `drop_database`/`info`/`database_info`) and `Arcadic.explain`/`profile`.
  - **`Arcadic.Transport.Grpc.ChannelPool`** — an opt-in, caller-supervised shared-channel cache; add
    it to your supervision tree for channel reuse (absent, a fresh channel per call is used).

  Errors are value-free (an atom reason, never the gRPC wire message; per-row ingest errors surface
  only a row index + a categorical code). Transport is plaintext by default; enabling TLS (a secure
  `grpcs://` scheme or `transport_options: [tls: true]`) verifies the server certificate against the OS
  trust store (`verify_peer`, never `verify_none`). A few operations are intentionally HTTP-only: server settings,
  user management (the server itself does not implement it over gRPC), token login/logout, time-series,
  and HA read-consistency — use an HTTP `Conn` for those. Select it with
  `transport: Arcadic.Transport.Grpc` and a `grpc://host:port` URL; credentials come from `Conn.auth`.
  **HTTP/Bolt-only consumers are unaffected**: the transport and its generated protobuf stubs are
  compile-guarded on the optional deps, so a consumer that doesn't add `:grpc`/`:protobuf` compiles and
  ships without them.

## [0.6.0] - 2026-07-14

### Added

- `Arcadic.transaction/3` accepts an opt-in `:retry` option (`true` for defaults,
  `max_attempts: 3, base_backoff_ms: 50, max_backoff_ms: 1000`, or a keyword
  overriding any of those). Off by default (unchanged behavior). On a transient
  server fault (`:concurrent_modification`, `:not_leader`, and a pre-commit
  `:timeout`) it retries with jittered exponential backoff up to `:max_attempts`.
  **The retried function must be idempotent** - it may run more than once.
  Emits `[:arcadic, :transaction, :retry]` telemetry per attempt (`%{attempt}`
  measurement, `%{reason}` metadata).
- `Arcadic.Conn.with_consistency/2` and `connect(consistency: ...)`: a
  read-consistency level for subsequent reads: `:eventual` (default, sends no
  extra header), `:read_your_writes`, or `:linearizable`. HTTP-only; a
  non-default level on a Bolt connection raises. On a single-server deployment,
  `:read_your_writes` is a harmless no-op.
- `Arcadic.query_bookmarked/4` / `command_bookmarked/4` (+ `!` variants), like
  `query/4`/`command/4` but return `{:ok, rows, conn'}`, where `conn'` carries a
  monotonically-advancing read-your-writes bookmark. Thread `conn'` into the next
  call to observe your own writes. HTTP-only; bookmarked calls target the primary
  host and do not participate in multi-host failover.
- `connect(hosts: [...])`: additional base URLs for multi-host availability
  failover. Reads fail over to the next host on any connection error; writes fail
  over only on a pre-send connect error, never on an ambiguous post-send close. A
  session (inside `transaction/3`) pins to whichever host answers first. This is
  availability failover, not load balancing; front a cluster with a load
  balancer if you want request distribution.
- New `Arcadic.Error` reason `:not_leader`: the target node is not the cluster
  leader and could not forward the write (`ServerIsNotTheLeaderException`).
  Treated as retriable by managed retry and as failover-eligible by multi-host
  failover (the write was rejected, nothing applied).
- `Arcadic.Changes` — a live change-events client for ArcadeDB's `/ws` feed. Start
  it under your own supervision tree (`start_link/1`) and `subscribe/3` a database
  to receive `{:arcadic_change, %Arcadic.Changes.Event{}}` messages. **Best-effort
  at-most-once**: the feed has no replay, so a reconnect delivers a `:reconnected`
  marker (events during the gap are lost) and a full delivery buffer delivers one
  `:overflow` marker after dropping the oldest events — either marker means the
  subscriber should reconcile. A terminal `401`/`403` handshake failure delivers
  `{:arcadic_change_error, :unauthorized}` (then stops, no reconnect spin); a
  server-rejected subscribe delivers a non-terminal
  `{:arcadic_change_error, :subscribe_rejected}`. Requires the optional
  `mint_web_socket` dependency; `start_link/1` returns
  `{:error, :mint_web_socket_not_available}` without it, and validates the `:conn`
  value-free (`:invalid_auth` / `:invalid_url_scheme` / `:invalid_max_buffer` —
  an unrecognized URL scheme is refused, never downgraded to plaintext).
- `Arcadic.Function` — `define/4` / `delete/2` (+ `!`) for ArcadeDB user-defined
  functions (`DEFINE FUNCTION` / `DELETE FUNCTION`). A function name is a dotted
  `library.fn`; the body is a single-line, single-quoted literal (ArcadeDB's DDL
  string literal has no escape). `define/4` takes a single trailing `opts` keyword
  list — `:params` (a list of parameter names) and `:language` (`:js` default,
  `:sql`, `:cypher`) — matching the other DDL helpers. Call a defined function from
  an ordinary `query/4`/`command/4` via the backtick idiom.
- `Arcadic.Trigger` — `create/4` / `drop/2` (+ `!`) for ArcadeDB triggers
  (`CREATE TRIGGER` / `DROP TRIGGER`), firing a `:timing` (`:before`/`:after`) ×
  `:event` (`:create`/`:delete`/`:update`/`:read`) action in `:sql`, `:javascript`,
  or `:java`. Shares `Arcadic.Function`'s single-line/single-quoted body limit.
- `Arcadic.MaterializedView` — `create/3` / `drop/2` (+ `!`) for ArcadeDB
  materialized views (`CREATE MATERIALIZED VIEW` / `DROP MATERIALIZED VIEW`) from
  a raw `SELECT` statement.
- `Arcadic.Geo` — `create_index/4` / `drop_index/3` (+ `!`) for a `GEOSPATIAL`
  index over a string property holding WKT (this ArcadeDB build has no native
  `POINT` schema type). Geospatial querying rides ordinary `query/4`/`command/4`.
- `Arcadic.TimeSeries` — a client for ArcadeDB's time-series wire family.
  Requires ArcadeDB ≥ 26.7.2 (an older server 404s every `/api/v1/ts` route).
  - `create_type/4` / `drop_type/2` (+ `!`) — `TIMESERIES` DDL (fields, tags,
    precision, shards, retention, compaction interval); `add_downsampling/3` /
    `drop_downsampling/2` (+ `!`) — downsampling policies.
  - `create_aggregate/3` / `refresh_aggregate/2` / `drop_aggregate/2` (+ `!`) —
    continuous aggregates (`CREATE`/`REFRESH`/`DROP CONTINUOUS AGGREGATE`),
    materializing a raw `SELECT` as a document type.
  - `write/3` / `write_lines/3` (+ `!`) — Influx line-protocol writes: `write/3`
    builds the wire format from structured point maps (typed fields, string
    tags, Identifier-validated names); `write_lines/3` is a raw passthrough for
    an already-built line-protocol batch. Append-only, non-idempotent — see the
    module's Operational contract before relying on retries or mixed-type
    batches.
  - `query/3` / `latest/3` (+ `!`) — JSON reads: `query/3` returns the raw
    columnar shape or, with `:aggregation` + `:bucket_interval`, bucketed
    aggregations; `latest/3` returns the newest point matching at most one tag.
  - `prom_query/3`, `prom_query_range/6`, `prom_labels/2`, `prom_label_values/3`,
    `prom_series/3` (+ `!`) — the PromQL read family (instant, range, labels,
    label values, series matching), decoding the Prometheus `data` envelope.
  - Four new optional `Arcadic.Transport` callbacks (`ts_write/3`, `ts_query/3`,
    `ts_latest/3`, `ts_prom_get/4`) back the wire family, HTTP-only (Bolt
    returns `{:error, %Arcadic.Error{reason: :not_supported}}`).
  - New `notebooks/timeseries.livemd` — DDL, writes, query/latest, PromQL,
    continuous aggregates, downsampling, and pointing Prometheus/Grafana at
    ArcadeDB.

### Changed

- `connect/3` and `transaction/3` now reject unknown option keys value-free
  (an `ArgumentError` naming the allowed set), matching `query`/`command`. A
  typo'd option — `consistancy:`, or `retires:` for `retry:` — was previously
  ignored silently, which for a connection-control option meant the wrong
  default applied (a mis-spelled `retry:` silently meant no retry). The
  offending value is never echoed.

## [0.5.0] - 2026-07-10

### Added

- `Arcadic.explain/4` + `Arcadic.profile/4` (+ `!`) — surface the ArcadeDB EXPLAIN/PROFILE plan
  (`%{plan, plan_tree, rows}`) that `query`/`command` silently dropped. `explain` is plan-only;
  **`profile` executes the statement** (a write mutates). Works over HTTP and Bolt (Cypher-only).
- `query`/`command`/`query_stream` now return `{:error, %Arcadic.Error{reason: :use_explain}}` on a
  bare EXPLAIN/PROFILE (was a silent `{:ok, []}`).
- `Arcadic.Server` — server administration, expanded beyond database lifecycle: `info/2`
  (server info/metrics, `mode: :basic | :default | :cluster`), `metrics/1`, `health?/1`,
  `events/1`, `set_server_setting/3` / `set_database_setting/3` (key + value both
  allowlist-validated value-free), `open_database/2` / `close_database/2`, `align_database/2`
  (cluster-only — a single-server node returns a server error), `check_database/2`
  (`fix: true` runs `CHECK DATABASE FIX`, returns the integrity map), `profiler/2`, and
  `shutdown/1` (a successful shutdown typically surfaces as a transport-closed error, since
  the server stops responding mid-request), alongside the existing `create_database/2` /
  `drop_database/2` / `database_exists?/2` / `list_databases/1` / `ready?/1`. HTTP-only,
  tenant-blind.
- `Arcadic.Security` — server security & auth admin (HTTP-only): `login/1` / `logout/1`
  (session tokens), `sessions/1`, `users/1`, `groups/1`, `api_tokens/1`, `create_user/2`,
  and `drop_user/2` (all + `!`). `create_user/2`'s password is JSON-encoded into the server
  command and never echoed — an unencodable spec (e.g. a non-UTF-8 password) is rejected
  value-free as `{:error, :invalid_user_spec}` before any wire call.
- `Arcadic.Backup` — backup and restore (HTTP-only): `backup/2` (`BACKUP DATABASE`, optional
  `:to` target URL), `list/1`, and `restore/3` (all + `!`). A `:to` target and the restore
  URL are allowlist-validated via `Arcadic.Identifier.validate_url/1` before interpolation
  (neither command can bind a URL param), value-free on rejection (`{:error, :invalid_url}`).
- `Arcadic.Conn.with_bearer/2` — derive a Bearer-token-authenticated connection from a
  session token (typically `Arcadic.Security.login/1`'s); HTTP-only.
- `Arcadic.Schema` — `stats/1` (`schema:stats`, per-database operation counters),
  `dictionary/1` (`schema:dictionary`), and `materialized_views/1` (`schema:materializedviews`)
  (all + `!`), `@props`-stripped like the rest of the module.
- Every `Arcadic.Server` / `Arcadic.Security` / `Arcadic.Backup` call emits a value-free
  `[:arcadic, :admin, :start | :stop | :exception]` telemetry span (metadata: `:operation`,
  `:reason` — no database name, setting key/value, URL, or credential).
- `Arcadic.command/4` / `command_async/4` accept an `:auto_commit` boolean opt, forwarded
  as-is to ArcadeDB's `autoCommit` body param.
- `Arcadic.FullText` — full-text search: `FULL_TEXT` (Lucene) index DDL (`create_index/4` +
  `drop_index/3`, retro-indexes existing rows) and `SEARCH_INDEX`/`SEARCH_FIELDS` query
  builders (`search/5`, `search_fields/5`, `:with_score` projects the BM25 `$score`).
  HTTP-only SQL.
- `Arcadic.Bulk` — `ingest/3` (+ `!`): bulk-creates vertices and edges over ArcadeDB's
  `POST /api/v1/batch/<db>` NDJSON endpoint in one atomic POST (edges wire via a
  structural `"@id"` temp key on vertex records; the response's `id_mapping` maps each
  temp `"@id"` to its assigned real RID). Create-only, HTTP-only, via a new optional
  `batch_ingest/3` transport callback.
- `Arcadic.Param` — `int8/1` / `bytes/1`: typed param-value wrappers (`$int8`/`$bytes`)
  decoded server-side to a `byte[]` before the query runs. HTTP-only, requires
  ArcadeDB ≥ 26.5.1.
- `Arcadic.Vector.fuse/3` now accepts heterogeneous neighbor specs — dense (bare
  4-tuple), `:sparse`, and `:fulltext` — fused together in one hybrid-ranked result set.
- New notebook `notebooks/graphrag.livemd` — an end-to-end graphRAG walkthrough (bulk
  ingest, idempotent `UNWIND` upsert, dense/sparse/full-text/hybrid retrieval, INT8
  params, traversal).

### Fixed

- Docs: SQL `:name` vs Cypher `$name` parameter binding is now documented; the Bolt-streaming
  example uses `Arcadic.Transport.Bolt.setup/1` (the prior `transport_options: [bolt: …]` form
  returned `:not_supported` for streaming); `~> 0.5` install pins; hexdoc module groups.

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

- Documented an upstream ArcadeDB **server** hazard for operators running Bolt over TLS: the
  listener performed TLS handshakes on its single shared accept thread, so one early-closed,
  stalled, or untrusted-cert handshake could wedge Bolt for every client (~100% CPU tight loop or
  no ServerHello) until restart. arcadic's client-side TLS is unaffected. Reported by arcadic;
  root-caused and fixed upstream on `main` 2026-07-08 (per-connection handshake threads + read
  timeout), shipping in 26.7.2 —
  [ArcadeData/arcadedb#5106](https://github.com/ArcadeData/arcadedb/issues/5106). Builds predating
  the fix remain affected; the wedge is condition-dependent (a cleanly-delivered `unknown_ca`
  alert does not trigger it — early-close/stall do), so a clean probe on a pre-fix build proves
  nothing.

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
