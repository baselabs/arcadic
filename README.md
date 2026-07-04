# Arcadic

A lean, framework-agnostic Elixir client for [ArcadeDB](https://arcadedb.com)
over the **HTTP Cypher command API**.

Arcadic is the "`postgrex` of ArcadeDB" — it ships Cypher/SQL to ArcadeDB and
manages connections and transactions, and nothing more. It is deliberately
**tenant-blind and framework-agnostic**: no Ash, no multitenancy, no data
classification. Those belong one layer up, in
[`ash_arcadic`](https://github.com/baselabs/ash_arcadic) (the "`ash_postgres` of
ArcadeDB").

> **Status: scaffold.** No implementation yet. The working rules for contributors
> and agents are in [`AGENTS.md`](AGENTS.md) — read it first. A fuller project
> charter (the verified ArcadeDB HTTP contract, architecture, and scope
> boundaries) is kept as a local, **unpublished** working doc at
> `docs/CHARTER.md`.

## Why not `arcadex`?

The existing [`arcadex`](https://hex.pm/packages/arcadex) hex package covers the
same niche and is a useful reference, but at v0.1.0 / single-maintainer it is not
a dependency to anchor production infrastructure on. Arcadic is built to be
owned: a transport-adapter seam (HTTP now, Bolt only if ever justified), a clean
extension point for the `ash_arcadic` data layer, and the maturity/tests a
payments-adjacent store needs.

## Layering

```
Ash core            (multitenancy DSL, policies, the tenant concept)
   │  passes tenant / builds queries
ash_arcadic         (Ash.DataLayer — set_tenant/3, sensitive-attr verifiers, traversal)
   │  calls
Arcadic  ← this lib (HTTP Cypher transport, sessions/transactions — tenant-blind)
   │  POST /api/v1/command/<db>  {"language":"cypher", ...}
ArcadeDB            (native OpenCypher engine)
```

## Installation

Not yet published. During co-development, depend on it by path:

```elixir
{:arcadic, path: "../arcadic"}
```

## Development

```bash
mix deps.get
mix test
mix quality   # format --check-formatted + credo --strict + dialyzer
```

## License

MIT — see [LICENSE](LICENSE).
