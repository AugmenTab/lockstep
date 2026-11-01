# Smoke completion packet — first real-provider calculator transaction (Gate C-EXEC evidence)

- For: the owner. Prepared 2026-11-01 by the writing agent (Implementer, manual). The Implementer did **not** perform
  or coach the fix; the live Claude roles did the work, and the human Done was the owner's.
- **Result: a real bug was fixed through Lockstep end to end, on the owner's Claude subscription, with independently
  verified results and a human Done.** Presented for the owner's explicit **Gate C-EXEC acceptance** (a successful
  transaction is the evidence; acceptance is the owner's decision).

## 1. Environment

- Candidate: `9898fc2` (code `05da865`, C-P4.L.N native subscription auth). Qualified offline Mac/Linux 870/571; the
  seven live checks green; one clean independent review.
- Service: the candidate installed into `.local/control`/`.local/install`, DB migrated to revision 21, running with
  `--runner` (native subscription mode). Provider image `lockstep-provider:claude-2.1.312` (`4a050cb4…`,
  `lockstep-isolation 2 ok`); runner image `lockstep-dev:p1` (`418f6426…`).
- Provider: the **unmodified Claude Code CLI 2.1.312** on the owner's **Claude Max subscription** (OAuth, authMethod
  `claude.ai`), token held only by the CLI identity in the Docker volume `lockstep-provider-auth-main`; Lockstep never
  read, stored, injected or relayed it. Model `claude-sonnet-5-5`, effort `medium`. Reached Anthropic over end-to-end
  TLS through the passthrough filter (`api.anthropic.com` allowlist).

## 2. The bug and the repository

- Disposable repo `~/lockstep-projects/calc-smoke`, basis commit **`35c1ec6`**, `calc.py` = `def add(a, b): return a - b`.
- Task: "add subtracts instead of adding"; acceptance `add(2, 2) == 4 and add(1, 2) == 3`. Profile `lockstep-bug-fix`
  (5 extra checks). Transaction `bbbef7c9-…`, work order `7b6a5052-…`, work branch `lockstep/7b6a5052-…`.

## 3. Outcome and Git evidence

- The transaction completed; the owner marked it **Done**.
- Work branch `lockstep/7b6a5052-…`:
  - `35c1ec6` calc: initial (add mistakenly subtracts)
  - `6bb9032` **Lockstep: frozen tests** (Supervisor)
  - `cf0f209` **Fix: add subtracts instead of adding** (Supervisor) — `calc.py` now `def add(a, b): return a + b`.
- **`main` is untouched** (`return a - b`); the repo has **no remote** — nothing was pushed. Only the Supervisor
  committed, only on the work branch.

## 4. Role runs, usage, retries (from the helper log; exact per-role mapping is in the task's technical details)

Usage is **tokens** (subscription usage units, not dollars); the summed per-run figure includes cache reads (see the
token-breakdown note in `smoke-notes.md`). `run-verify` steps are **deterministic** — Lockstep runs them, no model,
no tokens.

**First attempt (blocked, wasted):** Planner discovery 28,315 + Planner candidate 30,026 = **58,341 tokens**, then the
baseline/reproduction `run-verify` **launch-failed (125)**. Cause: a self-inflicted image-ordering mistake — the
runner image was rebuilt (`scripts/service install`) under the already-running helper, which kept invoking the stale
image ID for verify runs. Fixed by restarting the helper. (Full write-up in `smoke-notes.md`.)

**Successful transaction (after the restart):** 6 live model sessions, **185,813 tokens**:

| # | Run (helper id) | Role (inferred) | Tokens |
|---|---|---|---|
| 1 | `run-live-readonly ed25e2e7` | Planner — discovery | 30,511 |
| — | `run-verify 15b94bde` exit 1 | reproduction (deterministic; the bug was reproduced) | — |
| 2 | `run-live-readonly 5fc5ec2e` | Planner — Contract + candidate tests | 31,646 |
| — | `run-verify 532212d9` exit 0 | baseline (deterministic) | — |
| 3 | `run-live-write 5e98465e` | Implementer — attempt | 34,440 |
| 4 | `run-live-write 56da48ef` | Implementer — attempt | 28,298 |
| — | `run-verify 0f760578`, `d60a3206` exit 0 | post-fix checks (deterministic) | — |
| 5 | `run-live-readonly efdb3429` | Challenger — post-fix (or Reviewer) | 30,605 |
| — | `run-verify 8b5b946a` exit 0 | checks (deterministic) | — |
| 6 | `run-live-readonly bd29a603` | Reviewer (or Challenger) | 30,313 |

- **Total live usage across the whole smoke: 244,154 tokens over 8 live sessions** (the 58,341 of the first attempt
  was wasted by the image-ordering mistake, not by the workflow).
- **Retries:** two `run-live-write` (Implementer) sessions in the successful run — i.e. the Implementer took two
  attempts (DG-17 permits two). Worth confirming against the task's technical details whether attempt 1's checks
  failed and attempt 2 succeeded, or both wrote (a point for the role-count scrutiny).
- Elapsed: the successful transaction ran ~05:13:05–05:14:31 UTC (~90 s of role runs) plus the Supervisor commit and
  the human decisions; the first (blocked) attempt and the diagnosis/restart added the rest of the wall time.

## 5. Human interventions

- Reproduction decision on the first attempt ("go on without reproducing"); after the restart the reproduction step
  ran on its own and reproduced the bug, so that waiver was not needed in the successful run.
- Operational: the owner initialized the auth volume, completed the real `claude auth login` (in a real terminal —
  the `!` session shell has no TTY), and restarted the helper (to recover from the image-ordering mistake).
- The final **Done** decision.

## 6. Verified claims (handoff §2 / the Planner's acceptance list)

- Real subscription-backed Claude execution — **yes** (8 live sessions on the Max plan, end-to-end TLS, no API key).
- Normal Lockstep planning and **frozen regression tests** — **yes** (`6bb9032`).
- Exactly **one** code-writing Implementer — **yes** (only `run-live-write` is the Implementer; two attempts of the
  one Implementer, not parallel writers).
- Successful implementation and independent verification — **yes** (deterministic checks green after the fix).
- Independent Reviewer assessment and semantic challenge — **yes** (the two post-fix read-only sessions).
- Supervisor-owned Git commit — **yes** (`cf0f209`, `6bb9032`; main untouched; nothing pushed).
- Recorded runtime, usage, retries, interventions — **yes** (§4, §5).
- Explicit human Done — **yes** (the owner).

## 7. Findings and limitations (detail in `smoke-notes.md`)

1. **Image-ordering mistake (mine), cost 58,341 wasted tokens + the restart.** Build the runner/provider images
   *before* starting the `--runner` helper; restart the helper if either is rebuilt. Possible Lockstep hardening: the
   helper should detect a moved/missing runner image and refuse cleanly rather than fail opaquely with a per-run 125.
2. **Token total surprised the owner.** Backlog: surface a per-run usage **breakdown** (input/output/cache), and a
   **cost monitor** per transaction (tokens + wall time). On a subscription these are usage units, not dollars.
3. **Per-transaction overhead is large for a trivial fix** (fixed ceremony regardless of bug size). Not a problem
   unless trivial bugs are common in real projects.
4. **Role count: four roles, not the intended three.** The engine runs Planner, **Challenger**, Implementer, Reviewer
   (two of them twice). The Challenger traces to **DG-07** (owner-ratified 2026-10-28); the owner is reconsidering it
   (drop the pre-freeze Challenger; possibly fold the post-work challenge into a Verifier). A Planner scrutiny item.
5. **Offline qualification is not proof of live acceptance** — now moot: live acceptance is demonstrated by this
   transaction. The egress allowlist needed only `api.anthropic.com`.
6. The filesystem credential-isolation tests show the tools cannot read the auth volume; they are **not** proof
   against every in-process, model-directed file operation by the CLI itself (documented residual).

## 8. Confirmations

- No API-key billing; no token-substitution proxy; the subscription token never seen by Lockstep (held by the CLI in
  its volume). No secrets in this packet or the evidence. `main` untouched; no remote; nothing pushed. The run touched
  only the disposable `calc-smoke` repo.

## 9. For the owner

Gate C-EXEC is **not** self-accepted. This packet is the evidence of a complete, independently verified,
subscription-backed transaction with a human Done, presented for your explicit Gate C-EXEC acceptance. Deferred and
unaffected: Brigid dogfood (after C-EXEC acceptance), the role-count/cost scrutiny, the tech-stack correction pass,
UX-C8/C9, Phase 5.
