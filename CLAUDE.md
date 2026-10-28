# Arcadic — start here

Read **`AGENTS.md`** first: the binding critical rules (params-only, validated identifiers,
redaction, tenant-blind boundary, `MERGE`-is-fine-here), the verified ArcadeDB HTTP contract,
and the workflow tiers. `docs/CHARTER.md` (local, gitignored) holds mission, layering, scope
and open design questions.

Arcadic is the **tenant-blind, framework-agnostic ArcadeDB client** — the "`postgrex` of
ArcadeDB" — with three verified transports (HTTP default, opt-in Bolt and gRPC), released on
hex (`arcadic`). The Ash data layer lives in the sibling **`ash_arcadic`** repo. Forward work
here is new ArcadeDB transport capabilities that preserve the tenant-blind boundary.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook;
gitignored). Prefer `graphify query` / `explain` / `path` for orientation. Graph output is
navigation, never evidence: Elixir edges are file-local only, so verify load-bearing claims
against live code. `graphify update .` refreshes it after large uncommitted changes.
