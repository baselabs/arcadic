# Arcadic

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fbaselabs%2Farcadic%2Fmain%2Fnotebooks%2Fgetting_started.livemd)

A lean, framework-agnostic Elixir client for [ArcadeDB](https://arcadedb.com)
over the **HTTP Cypher command API**, with an optional Bolt transport for the
query hot path.

Arcadic is the "`postgrex` of ArcadeDB" — it ships Cypher/SQL to ArcadeDB and
manages connections, sessions, and transactions, and nothing more. It is
deliberately **tenant-blind and framework-agnostic**: no Ash, no multitenancy,
no data classification. Those belong one layer up, in
[`ash_arcadic`](https://github.com/baselabs/ash_arcadic) (the "`ash_postgres` of
ArcadeDB").

## Highlights

- **Cypher-first, multi-language** — the default language is `"cypher"`; opt into
  `sql`, `gremlin`, `graphql`, `mongo`, or `sqlscript` per call.
- **Parameters only** — every dynamic value reaches ArcadeDB as a bound parameter
  (`$name`), never string interpolation, so the injection surface stays closed.
- **Typed errors with boundary redaction** — `Arcadic.Error` carries a typed
  `reason`, HTTP status, and error class; raw parameter values and response rows
  never enter an error message, log line, or `inspect/1` output.
- **Session transactions** — `transaction/3` opens an ArcadeDB session and commits
  on normal return, rolls back and reraises on exception (postgrex semantics).
- **Pluggable transport** — HTTP (Req/Finch) by default, with an optional Bolt v4
  transport for the query hot path and lazy result streaming.
- **Vector search** — dense `LSM_VECTOR` index DDL plus nearest-neighbour and
  hybrid-fusion query builders (`Arcadic.Vector`), params-only and value-free.
- **Batteries included** — server admin, a migration runner, vector search,
  allowlist-validated identifiers, and value-free telemetry spans.

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

Every dynamic value reaches ArcadeDB **only as a bound parameter** (`$name`).
`query/4` hits the idempotent read endpoint; `command/4` hits the write endpoint.
Both return `{:ok, rows}` or `{:error, %Arcadic.Error{} | %Arcadic.TransportError{}}`;
`query!/4` and `command!/4` return the rows or raise. `command_async/4` submits a
fire-and-forget write, returning `:ok` once ArcadeDB accepts it for processing
(HTTP 202). The default language is `"cypher"`; pass `language: "sql"` (or
`gremlin`/`graphql`/`mongo`/`sqlscript`) to switch.

`Arcadic.transaction/3` opens an ArcadeDB session, runs the fun with a
session-scoped conn, and commits on normal return. An exception rolls back and
reraises; `Arcadic.rollback/2` aborts intentionally and yields `{:error, reason}`.

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

## Vector search

`Arcadic.Vector` builds ArcadeDB dense-vector index DDL and nearest-neighbour /
hybrid-fusion queries. Create an `LSM_VECTOR` index (idempotent — `IF NOT EXISTS`),
then search. The query vector, `k`, and options bind as parameters; the index
reference is identifier-validated before it reaches the statement.

```elixir
:ok =
  Arcadic.Vector.create_dense_index(conn, "Doc", "embedding", 1536, similarity: :cosine)

{:ok, rows} =
  Arcadic.Vector.neighbors(conn, "Doc", "embedding", query_vector, 10, max_distance: 0.3)

# hybrid fusion over multiple dense subqueries
{:ok, fused} =
  Arcadic.Vector.fuse(
    conn,
    [{"Doc", "embedding", dense_a, 20}, {"Doc", "embedding", dense_b, 20}],
    fusion: :rrf
  )
```

`neighbors/6` rows carry a `distance` whose scale depends on the index `similarity`
(COSINE `0..1` ascending, so smaller is nearer; DOT_PRODUCT is negative, so a small
positive `max_distance` filters nothing — choose thresholds per similarity). `fuse/3`
rows are ranked by `score` (higher is better). Sparse retrieval and the Ash-native
data-layer surface are non-goals.

## Bolt transport (optional)

The query hot path can run over Bolt via the optional
[`boltx`](https://hex.pm/packages/boltx) dependency. Add `{:boltx, "~> 0.0.6"}`,
start a Bolt connection with `Arcadic.Transport.Bolt.start_link/1` (it pins Bolt
v4 — `versions: [4.4, 4.3, 4.2, 4.1]` — and the non-TLS `bolt` scheme, which
ArcadeDB uses, and takes `username`/`password`), then pass the connection
reference. Server admin runs over HTTP; use an HTTP conn for it even when queries
go over Bolt.

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

For paging large result sets, `Arcadic.query_stream/4` returns a lazy `Stream.t()`
of rows over Bolt, chunked via `PULL`.

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

Arcadic is developed alongside
[`ash_arcadic`](https://github.com/baselabs/ash_arcadic). Depend on it by path
during co-development:

```elixir
def deps do
  [
    {:arcadic, path: "../arcadic"},
    # optional, for the Bolt transport:
    {:boltx, "~> 0.0.6"}
  ]
end
```

Once published to Hex, `{:arcadic, "~> 0.1"}` will pull it directly.

## Development

```bash
mix deps.get
mix test
mix quality   # format --check-formatted + credo --strict + dialyzer
```

To explore the full surface interactively against a local ArcadeDB, open the
[getting-started notebook](notebooks/getting_started.livemd) (the **Run in
Livebook** badge at the top launches it directly).

Contributor and agent working rules — including the params-only, redaction, and
tenant-blind invariants — live in
[`AGENTS.md`](https://github.com/baselabs/arcadic/blob/main/AGENTS.md).

## Credits

- [**ArcadeDB**](https://arcadedb.com) — the multi-model database Arcadic speaks to.
- [**arcadex**](https://hex.pm/packages/arcadex) — prior-art ArcadeDB client that
  served as a reference for the HTTP command-API request/response shapes.
- [**boltx**](https://hex.pm/packages/boltx) — the Bolt protocol driver behind the
  optional Bolt transport.
- [**Req**](https://hex.pm/packages/req) / [**Finch**](https://hex.pm/packages/finch)
  — the HTTP client and pool behind the default transport.
- [**DBConnection**](https://hex.pm/packages/db_connection) — connection pooling for
  the Bolt transport.

The `postgrex`/`ash_postgres` split that inspired Arcadic and `ash_arcadic` is the
work of the Elixir Ecto and Ash communities.

## License

MIT — see [LICENSE](LICENSE).
