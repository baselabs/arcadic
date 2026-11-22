# Arcadic — AI Agent & Contributor Guide

How to work effectively in this repo. This file is the *how* and is
self-contained; its Critical Rules are binding. A fuller *what & why* charter is
kept as a local, **unpublished** working doc at `docs/CHARTER.md` (not tracked).

## What this is

A framework-agnostic Elixir client for ArcadeDB, released on Hex as `arcadic`, with three
verified transports: HTTP over the Cypher command API (the default) and opt-in Bolt and gRPC.
The "`postgrex` of ArcadeDB." **Tenant-blind, Ash-agnostic, transport-only.**
Multitenancy, classification, and Ash resources live in the sibling `ash_arcadic`
data layer — never here. Forward work here is new ArcadeDB transport capabilities that
preserve the tenant-blind boundary.

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

Probed live against ArcadeDB. CI pins `arcadedata/arcadedb:26.11.1`, and a daily canary
runs the moving `latest` image. This is the substrate; build to it.

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

## Workflow

Make the change, run the tests that cover it, and commit with named paths. Nobody pushes
`main`. A commit lands through one CI run on `kci/<full sha>`; that workflow's final
`qualified` job is the verdict, and `main` moves to the commit only after `qualified` succeeds.
If it goes red, fix forward in a new commit.

A landing is finished only when its residue is gone, removed in the same step and checked
before it is reported: every branch it used other than `main` (`kci/*`, which
the landing tool deletes itself, plus any `review/*` or topic branch, local and on origin),
every worktree and scratch clone made for it, the scratchpad logs and scripts it wrote, and
anything a test or check left behind (containers and their volumes, databases,
`erl_crash.dump`, PLTs and `doc/` built outside CI). A fork branch and upstream clone made for
an outside pull request go when that pull request merges or closes. `git worktree list`,
`git branch -a` and the scratchpad hold none of the landing's work when it is reported.

The `arcadedb:latest` canary (`.github/workflows/canary.yml`) runs daily and on demand
against the moving upstream image. It never gates a landing: a red canary is upstream drift
to fix before the next deliberate ArcadeDB pin bump.

CI and the canary only restore caches; `.github/workflows/cache-warmer.yml` is the one writer.
On each push, daily and on demand, and only on the default branch, it builds missing caches:
`deps` and `_build` for each Elixir build, and the dialyzer PLT for the default build. A cache's
path or key changes in the warmer and in every restore step together.

Every workflow runs its steps as `bash -eo pipefail` (`defaults: run: shell: bash`), and every
script a job calls is bash with `set -euo pipefail`, so a failure behind a pipe fails its step.
A command whose failure must fail the job is never followed by `|| true` and never feeds a check
through `$(...)` inside `echo` or a `for` list: assign it to a variable first.

Elixir, Erlang and Java versions live only in `.tool-versions`; `scripts/toolchain.sh` reads
it for every workflow, so a toolchain bump is a one-file change.

```bash
mix deps.get
mix format
mix test
```

CI runs: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`,
`mix audit`, `mix test --warnings-as-errors`, `mix dialyzer` (all but `audit` bundled as
`mix quality`) and `mix docs --warnings-as-errors` on the default toolchain; compile and unit tests on the
supported floor and newest Elixir/OTP, each on the dependency tree a host on that Elixir can run
(`elixir scripts/ci_host_mode.exs` leaves out an optional dependency whose chain needs a newer
Elixir); compile (`--force --warnings-as-errors`) and unit tests with every optional
dependency removed on the default toolchain (`ci_host_mode.exs --without-optional`, the
`without-optional` job); the live integration lanes; and every notebook the
package ships, run top to bottom against this checkout and a live server by
`elixir scripts/run_notebook.exs NOTEBOOK.livemd`. Run the ones that cover your change.
Every job fetches with `mix deps.get --check-locked`, so a `mix.lock` that does not match
`mix.exs` fails CI: commit lock changes with the change that causes them.

- A test that fails on every run is a defect: fix it, or quarantine it with a reason, in the
  change that finds it.
- Update `CHANGELOG.md` under `[Unreleased]` when behavior, a dependency or a contract changes;
  other docs only when a contract changes.

## CI/CD and releases

CI/CD, the runners, the build machine and releases belong to the infrastructure owner (infra),
for every BaseLabs product. The organization's CI requirements for every product bind this
repository. Re-read them whenever you touch a workflow, a Dockerfile, a release script or a
secret. This file points at them and does not copy them.

- **Your part ends at `main`.** A change lands only through the landing run on `kci/<full sha>`
  (see Workflow). Never release, deploy, publish, tag a version, dispatch a workflow, push an
  image by hand, or handle a release, publish or CI key. When something should go out, send
  infra one message: repository, full commit, what goes out, and anything it needs. A release
  is the version commit with its CHANGELOG entry dated, landed; infra asks the owner,
  dispatches `.github/workflows/publish.yml` and tags `v<version>` on the published commit.
  Qualification and publication use `scripts/release/build_archives.sh` with the Hex version
  in `scripts/release/hex-version` to build and inspect both archives before any key is
  available: the package is built twice and must match byte for byte; docs are built once,
  because a docs build is not byte-stable, and carry `release.json` naming the package,
  version and the commit they were built from. Publication has no cache; its isolated
  `mix run --no-mix-exs` step uploads only what Hex does not yet serve for an existing
  package name, and holds the key only for that upload. It never replaces a package or
  served docs. A second dispatch finishes the first: the package Hex serves must equal the
  build, and docs Hex serves are kept and never compared. It refuses existing tags, retired
  versions and missing changelog sections. Read-back requires the served docs' `release.json`
  to name this release and the dispatched commit or an ancestor on the default branch (the
  published commit, which infra tags), and exports `release-assets`: the package, those
  inspected served docs, checksums, and release notes read from the published commit's
  CHANGELOG (not the checkout, which is newer when a dispatch resumes). Infra creates the
  GitHub release from them.
- **You write your own workflow changes; infra reviews them.** Before landing any change to
  `.github/`, a Dockerfile, a release script or anything that touches a secret, send infra the
  branch and head commit and wait for its review. Any CI/CD, runner, build-machine or key
  problem goes to infra, not around it.
- **Where checks run:** this repository is public, so it never uses a self-hosted runner or
  the build machine, and nothing that compiles or tests runs on a maintainer's workstation.
  Its checks run on GitHub-hosted runners: push the branch as `kci/<topic>` (ci.yml starts on
  `kci/**`), read that run, fix forward, and delete `kci/<topic>` once the change has landed.
  A secret never appears on a command line, in a log or in a message; if you see one exposed,
  tell infra where it sits without copying the value. Never list process arguments (no `ps`
  with `args` or `-f`, no `/proc/*/cmdline`).
- **Messages to infra:** one per result, complete enough to act on without a reply. No
  acknowledgements and no status notes.
- Every brief given to a sub-agent carries these same rules.

## Testing

- **Unit tests** (`test/*_test.exs`): no server. Stub HTTP with
  [`Req.Test`](https://hexdocs.pm/req/Req.Test.html) — Req is the transport, so
  its built-in test stubs cover request/response shaping without a real ArcadeDB.
- **Integration tests** (`test/integration/**`, tag `@moduletag :integration`):
  require a live server. Gate them on an env var (`ARCADIC_TEST_URL`); skip when
  unset so the pure-unit suite runs anywhere. Contributors without a server can start one with
  `docker run -p 2480:2480 -e JAVA_OPTS="-Darcadedb.server.rootPassword=…" \
  arcadedata/arcadedb:26.11.1`. CI starts a disposable, digest-pinned server for each run.
  Set the variables each suite reads for your server (`ARCADIC_TEST_*`,
  `ARCADIC_TS_TEST_*`, `ARCADIC_BOLT_*`, `ARCADIC_GRPC_TEST_*`). The TLS and
  admin-shutdown suites need their own throwaway server.
- **gRPC TLS live suite** (`test/integration/grpc_tls_test.exs`, tag
  `@moduletag :integration_grpc_tls`): needs a TLS-enabled gRPC ArcadeDB — the
  cert script and docker flags are in the test's moduledoc (on ARM64 images add
  `-Dio.grpc.netty.shaded.io.netty.handler.ssl.noOpenSsl=true`; netty-tcnative
  crashes otherwise). Proves the fail-closed contract: untrusted CA and bare
  OS store both reject the handshake.
- **Bolt is native** (`lib/arcadic/transport/bolt/`): arcadic owns PackStream v1,
  chunking, Bolt v4 messages, sockets and DBConnection callbacks. The compile gate
  is the optional `db_connection` dependency; no third-party Bolt driver is used.
  Unit byte peers cover hostile/truncated replies and stalls that a live server
  cannot intentionally generate; the integration tier always uses real ArcadeDB.
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
- **26.11 renames the missing-database exception** (probed 2026-11-01 on
  26.11.1-SNAPSHOT): a never-created database answers HTTP 404
  `DatabaseNotFoundException` (26.10: `DatabaseNotAvailableException`; <=26.9: 500
  `DatabaseOperationException`). All three map to `:database_not_found`; the live
  drift-guard is `test/integration/error_mapping_test.exs`.
- **26.12 rejects a third `SEARCH_INDEX` argument** (probed 2026-11-17 on
  26.12.1-SNAPSHOT): `SEARCH_INDEX(ref, q, {metadata:true})` fails with "expects 2
  arguments but got 3". The two-argument form returns the same rows, relevance order,
  `$score` and fuse RRF scores on 26.7.2, 26.8.1 and 26.12.1-SNAPSHOT, so
  `FullText.search` and the fuse full-text arm emit only the two-argument form.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook;
gitignored). Prefer `graphify query`, `graphify explain` and `graphify path` for orientation.
Graph output is navigation, never evidence: Elixir edges are file-local only, so verify
load-bearing claims against live code. `graphify update .` refreshes it after large uncommitted
changes.
