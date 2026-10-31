# Amendment to frozen tests for C-P4.L.S — for the Planner's authorization

- Status: **APPROVED and applied.** Authorization record: the Planner, 2026-10-31 ("P4.L.S Planner Decision"):
  "APPROVE A-P4.L.S-1, A-P4.L.S-2, and A-P4.L.S-3 in full for offline qualification … Apply exactly the five proposed
  frozen-file changes … Verify every amended file against its proposed SHA-256 digest." Applied from
  `.local/p4ls/amend/`; every file's sha256 after applying equals its proposal (below). No other frozen file changed.
  The approval is for offline qualification only: real subscription token injection and provider calls are **not**
  authorized (see `credential-boundary.md`).
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

## A-P4.L.S-2 — `scripts/lib/check-live-subscription` (C-P4.L.S, frozen `3764f93`)

- Original `f5fd8dcbc9a7f65fca031ce9f29b987add2e637e0a557cd7e0e8b014f0ab3f60`; proposed
  `c379d96ab11dfbfff0180015ae5b10162bf04007679d1e1e77baa6e44f8ab76d`.
- Why: one expectation assumed the Bash tool's environment would show the subscription placeholder. Measured, the CLI
  keeps `CLAUDE_CODE_OAUTH_TOKEN` out of its tools' environment altogether (`env-oauth=none`): stronger than expected.
  The expectation now accepts none or only the placeholder; it still requires no API key, and the separate expectation
  that the token is in no file stays.

  ```diff
  -  expect "S1 the role's container saw only a placeholder (no API key, a placeholder token)" \
  -    grep -q 'env-api=none env-oauth=lockstep-placeholder' "$log"
  +  # A-P4.L.S-2: the CLI keeps even the placeholder from its tools' environment (measured), so either is right.
  +  expect "S1 the role's tools saw no API key and no subscription token (none, or only the placeholder)" \
  +    grep -qE 'env-api=none env-oauth=(none|lockstep-placeholder-the-proxy-holds-the-token) end' "$log"
  ```

## A-P4.L.S-3 — `scripts/lib/live-standin` (C-P4.L, frozen `a6b69e2`)

- Original `6589bf3ed83839f3110ac5b91d05c7beaadf2ff6c3263145eef03ba7a410bf57`; proposed
  `260d44f6485070550aa7fad16427e39b047dd304836881c3842c9b48cff4c322`.
- Why: the stand-in decides "after a tool result" from the last message only. Without `--bare` the CLI ends its history
  with a `system` message after the tool results (measured: roles `user, system, assistant, user, system`), so the
  stand-in answered every request as if it were the first, and `check-live-runner`'s real-CLI run looped until the
  request allowance stopped it (50 requests, `requests-exhausted`). The test tool's guess, not the product. Now: a tool
  result in any message after the last assistant turn. Used only by `check-live-runner`.

  ```diff
  -            last = messages[-1] if messages else {}
  -            after_tool = isinstance(last.get("content"), list) and any(
  -                isinstance(b, dict) and b.get("type") == "tool_result" for b in last["content"])
  +            # After a tool result: one in a message after the last assistant turn (A-P4.L.S-3: without
  +            # --bare the CLI ends the history with a system message, so the last message is not it).
  +            since = []
  +            for m in messages:
  +                if isinstance(m, dict) and m.get("role") == "assistant":
  +                    since = []
  +                elif isinstance(m, dict):
  +                    since.append(m)
  +            after_tool = any(isinstance(m.get("content"), list) and any(
  +                isinstance(b, dict) and b.get("type") == "tool_result" for b in m["content"]) for m in since)
  ```

## Trials (the implementation in the working tree, image `2dfe970b…`; amended files as copies in `.local/p4ls/`)

| Check | Result |
|---|---|
| `check-live-subscription` (frozen) with the amended fixture | 21 of 22; the one failure is exactly A-P4.L.S-2's line (`env-oauth=none`) |
| `check-live-subscription` with A-P4.L.S-1 and -2 | **22 of 22** (`.local/evidence/live-subscription-20261031t183025z/`) |
| `check-live-runner` with the amended fixture | 83 of 84: the real-CLI run looped (A-P4.L.S-3) |
| `check-live-runner` with the amended fixture and stand-in | **84 of 84** |
| `check-live-boundary`, `-impersonation`, `-isolation` with the amended fixture | **83/83, 43/43, 26/26** |
| `check-live-concurrency`, `-proxy` (unchanged) | **17/17, 21/21** |

The Haskell files of A-P4.L.S-1 (the unit and integration tests) are trialled after approval in the full Mac and
Linux runs: their change is the literal `--bare` in the expected vector, against an adapter that no longer emits it.
