# Arcadic — start here

**Before any work, read these two files (this repo's context is in them, not here):**

1. **`AGENTS.md`** — the working guide: critical rules (params-only, redact,
   tenant-blind boundary, `MERGE`-is-fine-here), the verified ArcadeDB HTTP
   contract, and the dev/test workflow. **Binding.**
2. **`docs/CHARTER.md`** — the project charter: mission, architecture/layering,
   scope & non-goals, decisions, and the open design questions. A local,
   **unpublished** working doc (gitignored).

## One-line orientation

Arcadic is the **tenant-blind HTTP Cypher client for ArcadeDB** — the "`postgrex`
of ArcadeDB." The Ash data layer that rides on it lives in the sibling
**`ash_arcadic`** repo. No client implementation exists yet; the surface is
designed via `/brainstorm-autopilot` against the verified contract in
`docs/CHARTER.md`.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook; gitignored).

- For orientation ("where is X handled", "what connects A to B", "explain module M"), prefer `graphify query "<question>"` / `graphify explain "<Module>"` / `graphify path "<A>" "<B>"` over grep/Read fan-outs — one call returns a scoped subgraph with file:line hits.
- Graph output is NAVIGATION, never evidence. Edges reflect the last build, not the working tree, and cross-module call edges can be incomplete (Elixir: file-local only — alias-mediated calls are NOT resolved). Consumer sweeps and every load-bearing claim (review finding, plan anchor) still verify against live code: grep + file:line read.
- After large uncommitted changes, `graphify update .` refreshes the graph (AST-only, no API cost, no key).
