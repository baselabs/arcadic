# Arcadic

A lean, framework-agnostic Elixir client for [ArcadeDB](https://arcadedb.com)
over the **HTTP Cypher command API**.

Arcadic is the "`postgrex` of ArcadeDB" — it ships Cypher/SQL to ArcadeDB and
manages connections and transactions, and nothing more. It is deliberately
**tenant-blind and framework-agnostic**: no Ash, no multitenancy, no data
classification. Those belong one layer up, in
[`ash_arcadic`](https://github.com/baselabs/ash_arcadic) (the "`ash_postgres` of
ArcadeDB").

The working rules for contributors and agents are in [`AGENTS.md`](AGENTS.md) —
read it first.

## Quickstart

```elixir
conn = Arcadic.connect("http://localhost:2480", "mydb", auth: {"root", pass})

{:ok, rows} = Arcadic.query(conn, "MATCH (n:User) RETURN n LIMIT $lim", %{"lim" => 10})

{:ok, [user]} =
  Arcadic.command(conn, "CREATE (u:User {name:$n}) RETURN u", %{"n" => "Jo"})

{:ok, result} =
  Arcadic.transaction(conn, fn tx ->
    Arcadic.command!(tx, "MERGE (u:User {id:$id})", %{"id" => "u1"})
  end)
```

Every dynamic value reaches ArcadeDB **only as a bound parameter** (`$name`) —
never string interpolation. `query/4` hits the idempotent read endpoint;
`command/4` hits the write endpoint. Both return `{:ok, rows}` or
`{:error, %Arcadic.Error{} | %Arcadic.TransportError{}}`; `query!/4` and
`command!/4` return the rows or raise. `command_async/4` fire-and-forgets
(server enqueues, returns `:ok` on 202 — the caller cannot confirm the write
landed). The default language is `"cypher"`; pass `language: "sql"` (or
`gremlin`/`graphql`/`mongo`/`sqlscript`) to switch.

`Arcadic.transaction/3` opens an ArcadeDB session, runs the fun with a
session-scoped conn, and commits on normal return. An exception rolls back and
reraises (postgrex semantics); `Arcadic.rollback/2` aborts intentionally and
yields `{:error, reason}`.

## Production pool

The HTTP transport runs on Req/Finch. In production, give Arcadic a dedicated
Finch pool in your supervision tree rather than the default shared one:

```elixir
# lib/my_app/application.ex
children = [
  {Finch, name: MyApp.ArcadicFinch},
  # ...
]

# then point connections at it
conn =
  Arcadic.connect("http://localhost:2480", "mydb",
    auth: {"root", pass},
    transport_options: [finch: MyApp.ArcadicFinch]
  )
```

## Server admin

`Arcadic.Server` covers server-level operations: `create_database/2` (+ `!`),
`drop_database/2` (+ `!`), `database_exists?/2`, `list_databases/1`, and
`ready?/1`. Every database identifier is allowlist-validated before it reaches
the wire.

## Migrations

`Arcadic.Migrator` runs `Arcadic.Migration`s in order and tracks applied
versions in the `_arcadic_migrations` type. Declare a migration
(`version/0`, `up/1`, `down/1`), register the ordered list with
`use Arcadic.MigrationRegistry` + `migrations [...]`, then run
`Arcadic.Migrator.migrate/2` / `status/2` / `rollback/3` / `reset/2`.

```elixir
defmodule MyApp.Migrations.V1 do
  @behaviour Arcadic.Migration
  @impl true
  def version, do: 1
  @impl true
  def up(conn), do: Arcadic.command!(conn, "CREATE VERTEX TYPE User", %{}, language: "sql") && :ok
  @impl true
  def down(conn), do: Arcadic.command!(conn, "DROP TYPE User IF EXISTS", %{}, language: "sql") && :ok
end

defmodule MyApp.Migrations do
  use Arcadic.MigrationRegistry
  migrations [MyApp.Migrations.V1]
end

{:ok, _count} = Arcadic.Migrator.migrate(conn, MyApp.Migrations)
```

## Bolt transport (optional)

Admin is HTTP-only, but the query hot path can run over Bolt via the optional
`boltx` dependency. Add `{:boltx, "~> 0.0.6"}`, start a Bolt connection with
`Arcadic.Transport.Bolt.start_link/1` (it pins Bolt v4 —
`versions: [4.4, 4.3, 4.2, 4.1]` — and the non-TLS `bolt` scheme, which ArcadeDB
requires, and takes `username`/`password`), then pass the connection reference:

```elixir
{:ok, bolt} =
  Arcadic.Transport.Bolt.start_link(
    hostname: "localhost", port: 7687, username: "root", password: pass
  )

conn =
  Arcadic.connect("http://localhost:2480", "mydb",
    auth: {"root", pass},
    transport: Arcadic.Transport.Bolt,
    transport_options: [bolt: bolt]
  )
```

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

## Why greenfield, not `arcadex`?

The existing [`arcadex`](https://hex.pm/packages/arcadex) hex package covers the
same niche and was a useful HTTP body-shape reference. Arcadic is a greenfield
rewrite on strictly mechanical grounds — roughly 80% of the surface is different
code, not a fork:

- **Cypher-first defaults** — the default language is `"cypher"`, with SQL and
  the other engines opt-in per call.
- **Typed error taxonomy + boundary redaction** — `Arcadic.Error` carries a
  typed `reason`, and raw values never enter an error message, log line, or
  `inspect/1` output (`detail` is quarantined).
- **Session rework off the real response header** — transactions read the
  session id from the verified `arcadedb-session-id` response header.
- **Identifier-allowlist validation** — every identifier that reaches a URL path
  or statement is validated before the wire.
- **`Req.Test` suite** — the test surface stubs HTTP with `Req.Test` rather than
  Bypass.

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
