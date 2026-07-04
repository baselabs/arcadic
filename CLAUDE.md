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
