# Agent instruction history

Text moved byte-for-byte out of `AGENTS.md` on October 28, 2026, when the owner ruled that
process is sized to the risk of each change. Historical record only; not binding.

## From AGENTS.md: Verified ArcadeDB HTTP API contract (duplicate of the drift note)

- **Session transactions do NOT roll back DDL** (probed 2026-10-15, v26.10.2):
  `begin → CREATE VERTEX TYPE T → INSERT → rollback` discards the INSERT and KEEPS
  the type; a session stays valid after an in-tx statement error. Only DML is
  transactional.

## From AGENTS.md: Development workflow (superseded)

All gates must pass before a commit/PR. Update `CHANGELOG.md` under
`[Unreleased]`.

## From AGENTS.md: Testing (Bolt receipt and superseded TDD rule)

- **Bolt live suites** (tags `:integration_bolt`, `:integration_bolt_tls`):
  Bolt is not enabled by default — the plugin flag, BOTH env families
  (`ARCADIC_BOLT_*` and the B6 describe's `ARCADIC_TEST_BOLT_*`), and the
  `arcadedb.ssl.*` keystore spellings for bolt TLS are in `bolt_test.exs`'s
  moduledoc. TLS material: `test/support/tls/gen-grpc-certs.sh` (shared with
  the gRPC TLS suite). Benchmark to beat (2026-08-22, 26.9.1-SNAPSHOT): 22 +
  2 green; the full session ran all 139 integration tests live.
- **TDD:** write the test first.

## From AGENTS.md (whole section)

## Current status

The client surface is closed and feature-complete: HTTP, Bolt, and full gRPC transport
coverage; time-series, server programmability, administration, ingest, graphRAG, HA/read
consistency, telemetry, migrations (with the crash-recovery marker contract), and the
reliability surface are all shipped. `arcadic` **1.2.0** is the current release (Hex,
2026-10-16): the post-review hardening batch — dependency CVE closures, HTTP-boundary
redaction, gRPC timeout/laziness/pool fixes, import fail-closed, migrator crash
recovery, and the ArcadeDB 26.10 drift triage.

Forward product composition is consumer-side through `ash_arcadic` (`~> 0.7`), while new
ArcadeDB transport capabilities still land here first to preserve the tenant-blind
boundary.
