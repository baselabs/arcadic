# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
