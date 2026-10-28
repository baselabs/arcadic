# Arcadic — AI Agent & Contributor Guide

How to work effectively in this repo. This file is the *how* and is
self-contained; its Critical Rules are binding. A fuller *what & why* charter is
kept as a local, **unpublished** working doc at `docs/CHARTER.md` (not tracked).

## What this is

A framework-agnostic Elixir client for ArcadeDB over the HTTP Cypher command API.
The "`postgrex` of ArcadeDB." **Tenant-blind, Ash-agnostic, transport-only.**
Multitenancy, classification, and Ash resources live in the sibling `ash_arcadic`
data layer — never here.

## Critical rules

**1. Parameters only — never interpolate values into a statement.**
Every dynamic value goes into the request `params` map and is referenced as
`$name`. `command <> value` is a query-injection defect. ArcadeDB binds
`params`; use it. This is what closes the injection surface that a hand-written
Cypher template would otherwise open.

**2. Validate identifiers.** Database names, labels, and property names that reach
a statement as identifiers (not values — those are params) must be validated
against a strict allowlist before use. A value-free error on failure.

**3. Redact at the boundary.** Errors and logs carry structure only — HTTP status,
ArcadeDB error class, statement shape. **Never** put raw parameter values,
response rows, or a caller's data into an error message or log line. Assume every
value may be PII or a secret.

**4. Stay tenant-blind.** No multitenancy, scope, or classification logic enters
this lib. If a change reaches for a "tenant" or "scope" concept, it belongs in
`ash_arcadic`. This boundary is the whole reason the two libs are separate.

**5. `MERGE` is fine here (unlike the AGE sibling).** ArcadeDB's native
OpenCypher `MERGE` is verified correct. This deliberately diverges from the
sibling `ash_age` lib, which bans `MERGE` because Apache AGE's implementation
has performance bugs — different engine, different rule. Do not copy AGE's
"never MERGE" rule into this stack.

## Verified ArcadeDB HTTP API contract

Probed live against `arcadedata/arcadedb:latest`. This is the substrate; build to
it.

- **Command:** `POST /api/v1/command/<db>` with basic auth and body
  `{"language":"cypher","command":"…","params":{…}}`. `language` also accepts
  `"sql"`, `"gremlin"`, `"graphql"`, `"mongo"`, `"sqlscript"`.
- **Reads:** `POST /api/v1/query/<db>` — same body shape, the server's read/idempotent
  path (`http.ex` routes `query/4` there). The **server** rejects a non-idempotent
  statement on this endpoint (`QueryNotIdempotentException`, mapped value-free to
  `:not_idempotent`); there is NO client-side idempotency classification — a write
  sent as a read reaches the server and comes back as that error.
- **Result envelope:** `{"user":"…","result":[ {…} ]}`. Rows may carry `@`-prefixed
  keys: `@props` is serializer noise (**strip it**), but `@rid`/`@type`/`@cat`
  (`v`/`e`)/`@in`/`@out` are record + graph identity (**keep them**). Return
  `result`. (Verified: spec §15 P4/P15.)
- **Transactions (session-based):**
  - `POST /api/v1/begin/<db>` — **call with NO body.** A JSON body that lacks
    `isolationLevel` returns **HTTP 400** (`Missing parameter 'isolationLevel'`);
    an explicit `{"isolationLevel":"READ_COMMITTED"}` also works. No-body is the
    safe default.
  - The session id returns in the **`arcadedb-session-id` response header**. Echo
    it as a request header on every subsequent command **and** on
    `commit`/`rollback`.
  - `POST /api/v1/commit/<db>` / `POST /api/v1/rollback/<db>` with the session
    header. Verified: rollback discards writes, commit persists.
- **Readiness:** `GET /api/v1/ready` → **204** (use for health checks).
- **Idempotent write primitives** (native Cypher): `MERGE (n {key:$k})` is
  replayable; `ON CREATE SET` vs `ON MATCH SET` split stub-vs-rich semantics;
  `n += $props` merges properties.
- **Server-side statement retry (`retries` body param, probed 2026-07-15):**
  concurrent writes to one type contend on its BUCKETS — on a default-bucket type,
  100 concurrent creates @ 16-wide → ~85 `ConcurrentModificationException`;
  `retries: 10` in the command body → **0 conflicts, all rows persisted**
  (single-create and `UNWIND`-batch forms both). An autocommit statement is
  all-or-nothing, so the server-side retry is idempotency-safe by construction.
  Inside a session the param is a no-op (conflicts surface at commit). Schema
  lever: `CREATE VERTEX TYPE X BUCKETS <n>` (server caps ~32; `BUCKETS 128` →
  HTTP 400) sizes a hot type for its write concurrency.

## Development workflow

```bash
mix deps.get
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
mix dialyzer
# or all quality gates at once:
mix quality
```

`mix quality` is the declared local gate. Update `CHANGELOG.md` under `[Unreleased]`.

## Workflow (owner ruling, October 28, 2026)

Process is sized to the risk of the specific change, never the repository. Each check, gate,
record or review names the failure it prevents.

- **Heavy** when the diff touches statement or param building (the command/query paths in
  `lib/arcadic.ex`, `lib/arcadic/param.ex`), identifier validation
  (`lib/arcadic/identifier.ex`), the redaction boundary (`lib/arcadic/error.ex`,
  `transport_error.ex`, `opts.ex`), user and token admin (`lib/arcadic/security.ex`),
  transport TLS or auth (`lib/arcadic/transport/`), or the migrator's crash-recovery marker
  (`lib/arcadic/migrator.ex`). Write the failing test first, get one independent
  review and do one fix round, and run the declared local gate once before pushing. Heavy
  pushes need the owner's approval.
- **Light** for everything else: focused checks on the changed behavior, then push; hosted CI
  is the gate. No outcome record, gauge or review; the commit message is the record. A light
  change the owner asked for lands without a separate push approval.
- Publishing, deploying and pushes to mirrors always need the owner's approval for that action.
- A test that fails on every run is a defect: fix it, or quarantine it with a reason, in the
  change that finds it.
- Update the CHANGELOG when behavior, a dependency or a contract changes; other docs only when
  a contract changes.

## Testing

- **Unit tests** (`test/*_test.exs`): no server. Stub HTTP with
  [`Req.Test`](https://hexdocs.pm/req/Req.Test.html) — Req is the transport, so
  its built-in test stubs cover request/response shaping without a real ArcadeDB.
- **Integration tests** (`test/integration/**`, tag `@moduletag :integration`):
  require a live server. Gate them on an env var (`ARCADIC_TEST_URL`); skip when
  unset so the pure-unit suite runs anywhere. Contributors without a server can start one with
  `docker run -p 2480:2480 -e JAVA_OPTS="-Darcadedb.server.rootPassword=…" \
  arcadedata/arcadedb:latest`. Maintainer machines use the shared server; its values sit
  in the gitignored `.env` under the names the suites read (`ARCADIC_TEST_*`,
  `ARCADIC_TS_TEST_*`, `ARCADIC_BOLT_*`, `ARCADIC_GRPC_TEST_*`); load them with
  `set -a; . ./.env; set +a` before a lane. The TLS and admin-shutdown suites
  still need their own throwaway server.
- **gRPC TLS live suite** (`test/integration/grpc_tls_test.exs`, tag
  `@moduletag :integration_grpc_tls`): needs a TLS-enabled gRPC ArcadeDB — the
  cert script and docker flags are in the test's moduledoc (on ARM64 images add
  `-Dio.grpc.netty.shaded.io.netty.handler.ssl.noOpenSsl=true`; netty-tcnative
  crashes otherwise). Proves the fail-closed contract: untrusted CA and bare
  OS store both reject the handshake.
- **Bolt live suites** (tags `:integration_bolt`, `:integration_bolt_tls`):
  Bolt is not enabled by default — the plugin flag, BOTH env families
  (`ARCADIC_BOLT_*` and the B6 describe's `ARCADIC_TEST_BOLT_*`), and the
  `arcadedb.ssl.*` keystore spellings for bolt TLS are in `bolt_test.exs`'s
  moduledoc. TLS material: `test/support/tls/gen-grpc-certs.sh` (shared with
  the gRPC TLS suite).

## Docs & lifecycle-artifact policy

- **Tracked / published:** `AGENTS.md`, `README.md`, `CHANGELOG.md`,
  `CONTRIBUTING.md`, `usage-rules.md`, `LICENSE`, and `notebooks/`.
- **Never tracked:** the project charter (`docs/CHARTER.md`) plus all brainstorm
  specs, plans, exec notes, reviews, and handoffs. They live under `/docs/`,
  which is **gitignored** (matching the `ash_age` convention). Do not move
  `docs/` artifacts out to the repo root.
- **Instruction history:** `docs/reference/agent-history.md` (force-tracked) holds dated
  narratives and superseded instructions moved out of this file; not binding.
- AI-tool state dirs (`.claude/`, `.serena/`, etc.) are gitignored.

## Verified ArcadeDB drift notes

- **DDL is NOT transactional in session transactions** (probed 2026-10-15 on 26.10.2:
  `begin → CREATE TYPE → INSERT → rollback` discards the row, keeps the type; a session stays valid after an in-tx
  statement error). The migrator's marker contract exists because of this.
- **Import failures moved into the result row** (26.10): a bad `WITH` setting answers
  HTTP 2xx with `"result": "FAIL"` in the row — `Import.database` fails closed on it.
- **26.10 behavior changes** (pinned in the integration suite): the sparse-vector
  retro-index now covers pre-existing rows; an unknown time-series FIELD write and an
  unknown tag-key filter are rejected (was fail-open); projected rows no longer carry the
  synthetic `_$$$ORDER_BY_ALIAS$$$` ordering column, so HTTP keyset streaming of a
  projection falls back to offset paging (value-free warning, same rows).
