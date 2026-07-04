defmodule Arcadic do
  @moduledoc """
  A lean, framework-agnostic Elixir client for [ArcadeDB](https://arcadedb.com)
  over the **HTTP Cypher command API**.

  Arcadic is the "`postgrex` of ArcadeDB": it ships queries and manages
  connections/transactions, and nothing more. It is deliberately **tenant-blind
  and framework-agnostic** — it has no notion of Ash, multitenancy, or data
  classification. Those concerns live one layer up, in the `ash_arcadic` data
  layer (the "`ash_postgres` of ArcadeDB"). See `docs/CHARTER.md`.

  ## Status

  Scaffold only — no implementation yet. The verified ArcadeDB HTTP contract this
  module will wrap (endpoint shapes, the `begin` gotcha, session transactions,
  the result envelope, `MERGE` support) is documented in `docs/CHARTER.md` and
  `AGENTS.md`. The public surface is designed via `/brainstorm-autopilot` before
  any code lands.

  ## Planned surface (subject to the brainstorm)

    * `connect/2` — build a connection handle (base URL, database, auth).
    * `execute/4` — run a statement in a chosen language (`"cypher"` default).
    * `query/3` / `command/3` — read / write convenience wrappers.
    * `transaction/2` — session-scoped `begin`/`commit`/`rollback`.

  All dynamic values reach ArcadeDB **only as bound parameters**, never string
  interpolation (see `AGENTS.md` → Critical Rules).
  """
end
