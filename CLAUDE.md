# Arcadic — start here

**Before any work, read these two files (this repo's context is in them, not here):**

1. **`AGENTS.md`** — the working guide: critical rules (params-only, redact,
   tenant-blind boundary, `MERGE`-is-fine-here), the verified ArcadeDB HTTP
   contract, and the dev/test workflow. **Binding.**
2. **`docs/CHARTER.md`** — the project charter: mission, architecture/layering,
   scope & non-goals, decisions, and the open design questions. A local,
   **unpublished** working doc (gitignored).

## One-line orientation

Arcadic is the **tenant-blind, framework-agnostic ArcadeDB client** — the
"`postgrex` of ArcadeDB" — with three verified transports (HTTP default,
opt-in Bolt and gRPC), released on hex (`arcadic`). The Ash data layer that
rides on it lives in the sibling **`ash_arcadic`** repo. The client surface is
feature-complete; forward work here is new ArcadeDB transport capabilities
(preserving the tenant-blind boundary), with product composition
consumer-side in `ash_arcadic`.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook; gitignored).

- For orientation ("where is X handled", "what connects A to B", "explain module M"), prefer `graphify query "<question>"` / `graphify explain "<Module>"` / `graphify path "<A>" "<B>"` over grep/Read fan-outs — one call returns a scoped subgraph with file:line hits.
- Graph output is NAVIGATION, never evidence. Edges reflect the last build, not the working tree, and cross-module call edges can be incomplete (Elixir: file-local only — alias-mediated calls are NOT resolved). Consumer sweeps and every load-bearing claim (review finding, plan anchor) still verify against live code: grep + file:line read.
- After large uncommitted changes, `graphify update .` refreshes the graph (AST-only, no API cost, no key).
