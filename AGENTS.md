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
- **TDD:** write the test first.

## Docs & lifecycle-artifact policy

- **Tracked / published:** `AGENTS.md`, `README.md`, `CHANGELOG.md`,
  `CONTRIBUTING.md`, `usage-rules.md`, `LICENSE`, and `notebooks/`.
- **Never tracked:** the project charter (`docs/CHARTER.md`) plus all brainstorm
  specs, plans, exec notes, reviews, and handoffs. They live under `/docs/`,
  which is **gitignored** (matching the `ash_age` convention). Do not move
  `docs/` artifacts out to the repo root.
- AI-tool state dirs (`.claude/`, `.serena/`, etc.) are gitignored.

## Next action

The client surface and the Phase-1 completion design (S1–S6) are shipped and
closed. Current work is **Phase 2 — gap closure (S7–S12)**: see the local working
docs `docs/superpowers/ROADMAP.md` (detail) and `docs/superpowers/BACKLOG.md`
(status). Next: `/brainstorm-autopilot` S7 (correctness + docs currency), then
plan → exec → review against the verified contract above.
