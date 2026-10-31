# Amendment to frozen tests for C-P4.L.S — for the Planner's authorization

- Status: **PROPOSED.** The frozen files are unchanged; the amended versions are drafts in `.local/p4ls/amend/`.
  Prepared 2026-10-31 by the writing agent (Implementer, manual) under the owner's instruction to use the subscription
  (contract §1–§2).

## A-P4.L.S-1 — the argument vector without `--bare`

Why: with `--bare` the pinned CLI refuses subscription login ("Not logged in · Please run /login"; nothing sent), and
the same with `CLAUDE_CODE_SIMPLE=1` (what `--bare` sets) — measured offline (contract S-F1). Three frozen files pin
`--bare` in the adapter's argument vector. Nothing else in them changes. What `--bare` kept out is kept out by the
CLI's own switches and the existing isolation (contract S3), and the new frozen `check-live-subscription` proves it
(the repository's `CLAUDE.md`, skills, agents, commands and `.mcp.json` reach no request).

| File | Frozen | Original sha256 | Proposed sha256 | Change |
|---|---|---|---|---|
| `test/fixtures/live/claude-argv` | C-P4.L `a6b69e2` | `2ed204fc…16c2` | `da509962…1878` | line 3 `--bare` removed |
| `test/unit/Lockstep/Effects/ClaudeAdapterTest.hs` | C-P4.L | `bc0ff3c0…9058` | `51b810d3…3e8a` | L1-e: `assertBool "bare" ("--bare" `L.elem` argv)` → `assertBool "no --bare" ("--bare" `L.notElem` argv)`, and its name says why |
| `test/integration/Lockstep/LiveAdapterTest.hs` | C-P4.L | `aa16c106…53bc` | `2739b6c4…3591` | lines 235 and 366: `L.take 7 … ["claude", "-p", "--bare", "--model", …]` → `L.take 6 … ["claude", "-p", "--model", …]` |

Full digests: original `2ed204fce6dc775097294107190a45154ae1d3a3092fc39f75f7d8f436fb16c2`,
`bc0ff3c05eb70695c9d0c238b1a80fec10cf21553fe11886b83ce37916329058`,
`aa16c10647cbaa1c5b0c7999b13a8670b1384cb20199ccd403c70b0e21e753bc`; proposed
`da50996296eb84033bf223a4ba6bddd9eda597813913053bb8e6364cdbd21878`,
`51b810d3f3ef888e519ef8162723373f74b0dbe13717f16cc7dd4e7bc71f3e8a`,
`2739b6c4cd4d48ce18a54f154f53bbc9e301351e6617ef617985f3bf0fec3591`.

The fixture is also the argument vector every frozen live check submits, so with the amendment those checks run the
CLI without `--bare` (in their API-key mode); they must stay green unchanged.

Trials: (to be filled) the amended tests against the current adapter (RED, exactly these lines) and against the
implementation (GREEN); the live checks with the amended fixture.
