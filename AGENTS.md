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
OpenCypher `MERGE` is verified correct. Do **not** import `ash_age`'s "never use
MERGE" rule — that is an Apache AGE performance bug, a different engine. See
CHARTER D3.

## Verified ArcadeDB HTTP API contract

Probed live against `arcadedata/arcadedb:latest`. This is the substrate; build to
it.

- **Command:** `POST /api/v1/command/<db>` with basic auth and body
  `{"language":"cypher","command":"…","params":{…}}`. `language` also accepts
  `"sql"`, `"gremlin"`, `"graphql"`, `"mongo"`, `"sqlscript"`.
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

All gates must pass before a commit/PR. Update `CHANGELOG.md` under
`[Unreleased]`.

## Testing

- **Unit tests** (`test/*_test.exs`): no server. Stub HTTP with
  [`Req.Test`](https://hexdocs.pm/req/Req.Test.html) — Req is the transport, so
  its built-in test stubs cover request/response shaping without a real ArcadeDB.
- **Integration tests** (`test/integration/**`, tag `@moduletag :integration`):
  require a live server. Gate them on an env var (`ARCADIC_TEST_URL`); skip when
  unset so the pure-unit suite runs anywhere. Spin ArcadeDB locally with
  `docker run -p 2480:2480 -e JAVA_OPTS="-Darcadedb.server.rootPassword=…" \
  arcadedata/arcadedb:latest`.
- **gRPC TLS live suite** (`test/integration/grpc_tls_test.exs`, tag
  `@moduletag :integration_grpc_tls`): needs a TLS-enabled gRPC ArcadeDB — the
  cert script and docker flags are in the test's moduledoc (on ARM64 images add
  `-Dio.grpc.netty.shaded.io.netty.handler.ssl.noOpenSsl=true`; netty-tcnative
  crashes otherwise). Proves the fail-closed contract: untrusted CA and bare
  OS store both reject the handshake.
- **TDD:** write the test first.

## Docs & lifecycle-artifact policy

- **Tracked / published:** `AGENTS.md`, `README.md`, `CHANGELOG.md`,
  `CONTRIBUTING.md`, `usage-rules.md`, `LICENSE`, and `notebooks/`.
- **Never tracked:** the project charter (`docs/CHARTER.md`) plus all brainstorm
  specs, plans, exec notes, reviews, and handoffs. They live under `/docs/`,
  which is **gitignored** (matching the `ash_age` convention). Do not move
  `docs/` artifacts out to the repo root.
- AI-tool state dirs (`.claude/`, `.serena/`, etc.) are gitignored.

## Current status

The Phase-1 and Phase-2 client surfaces are closed and feature-complete.
`arcadic` 0.7.1 is released with HTTP, Bolt, and full gRPC transport coverage;
time-series, server programmability, administration, ingest, graphRAG, HA/read
consistency, telemetry, and the reliability surface are all shipped.

`main` past `v0.7.1` carries no package-version change; its user-facing
addition is the documented and live-tripwired server-side `retries:` option
for concurrent autocommit writes (docs, tooling, and dependency hygiene
only — no library behavior change). Forward product
composition is consumer-side through `ash_arcadic` (`~> 0.7`), while new
ArcadeDB transport capabilities still land here first to preserve the
tenant-blind boundary.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook; gitignored).

- For orientation ("where is X handled", "what connects A to B", "explain module M"), prefer `graphify query "<question>"` / `graphify explain "<Module>"` / `graphify path "<A>" "<B>"` over grep/Read fan-outs — one call returns a scoped subgraph with file:line hits.
- Graph output is NAVIGATION, never evidence. Edges reflect the last build, not the working tree, and cross-module call edges can be incomplete (Elixir: file-local only — alias-mediated calls are NOT resolved). Consumer sweeps and every load-bearing claim (review finding, plan anchor) still verify against live code: grep + file:line read.
- After large uncommitted changes, `graphify update .` refreshes the graph (AST-only, no API cost, no key).
