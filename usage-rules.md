# arcadic usage rules

_A framework-agnostic Elixir client for ArcadeDB over the HTTP Cypher command API._

> Scaffold stage — this file will carry concrete usage rules once the client
> surface is implemented. The binding facts today:

## What arcadic is (and is not)

- **Is:** a thin transport. Sends Cypher/SQL to ArcadeDB's HTTP command API,
  manages connections and session transactions, normalizes responses.
- **Is not:** Ash-aware, tenant-aware, or classification-aware. Never put
  multitenancy or sensitive-data logic here — that is `ash_arcadic`'s job.

## Non-negotiable rules

- **Parameters only.** Every dynamic value goes into the request `params` map and
  is referenced as `$name` in the statement. Never interpolate a value into a
  Cypher/SQL string — that is a query-injection defect.
- **Redact at the boundary.** Errors and logs carry structure only (status code,
  SQLSTATE-equivalent, statement shape) — never raw parameter values or response
  bodies that may contain caller data.

See `docs/CHARTER.md` for the verified ArcadeDB HTTP contract and `AGENTS.md` for the
full working rules.
