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

## 4. Role runs, usage, retries (reconciled against the authoritative DB record, `lockstep_invocations`)

This section is now keyed to the database, not inferred from the helper log. Usage is **tokens** (subscription usage
units, not dollars); the summed per-run figure includes cache reads (see the token-breakdown note in `smoke-notes.md`).
The `reproduction`, `baseline`, `verification`, `mutant` and `counterexample` steps are **deterministic** — Lockstep
runs them itself, no model session, no tokens.

The whole smoke is **one** transaction (one `transaction_id`, 15 invocations). It ran in two attempts around a helper
restart; the restart **resumed** the transaction (it did not start a new one).

**First attempt (blocked):** `discovery/planner` answered (28,315) → `reproduction` **launch-failed (125)** →
`candidate/planner` answered (30,026) → `candidate/baseline` **launch-failed (125)**. Cause of the 125s: a
self-inflicted image-ordering mistake — the runner image was rebuilt (`scripts/service install`) under the
already-running helper, which kept invoking the stale image ID for the deterministic verify runs. Fixed by restarting
the helper. (Full write-up in `smoke-notes.md`.)

**After the restart, the transaction resumed from the `candidate` stage** — `discovery` was **not** re-run (its answer
was reused), so only the `candidate` stage repeated. The authoritative post-restart sequence:

| time (UTC) | stage | what | role / outcome | tokens |
|---|---|---|---|---|
| 05:12:16 | candidate | planner | Planner — Contract + candidate tests (re-run), answered | 30,511 |
| 05:13:06 | candidate | baseline | deterministic baseline, **exited ec=1 = RED** (tests detect the bug) ✓ | — |
| 05:13:09 | challenge-pre | **challenger** | **pre-freeze Challenge**, answered | 31,646 |
| 05:13:25 | challenge-pre | mutant | deterministic mutant check, exited 0 | — |
| 05:13:30 | implement | implementer | Implementer — attempt 1, answered | 34,440 |
| 05:13:42 | implement | implementer | Implementer — attempt 2, answered | 28,298 |
| 05:13:55/56 | verify | verification | deterministic checks, exited 0 (×2) | — |
| 05:13:59 | challenge-post | **challenger** | post-fix Challenge, answered | 30,605 |
| 05:14:15 | challenge-post | counterexample | deterministic counterexample check, exited 0 | — |
| 05:14:18 | review | reviewer | independent Review, answered | 30,313 |

- **Model sessions, authoritative counts:** Planner ×3 (discovery + candidate first attempt + candidate re-run),
  **Challenger ×2** (pre-freeze + post-fix), Implementer ×2 (two attempts), Reviewer ×1 — **8 live sessions total**,
  matching the helper log's 8 live runs.
- **Total live usage: 244,154 tokens over the 8 sessions.** Of that, the image-ordering mistake made **one** stage
  redundant — the `candidate` Planner run was done twice (30,026 then re-run 30,511). So the mistake wasted
  **~30,026 tokens** (one duplicated candidate stage), **not 58,341**: `discovery` (28,315) was reused by the resumed
  transaction, not repeated. (Earlier drafts said 58,341; that double-counted the reused discovery.)
- **Retries:** two `implement/implementer` sessions, both `answered` — the Implementer took two attempts (DG-17 permits
  two). Both are the single Implementer, not parallel writers; the two deterministic `verification` runs after them
  exited 0 (the fix passed).
- Elapsed: the resumed transaction ran 05:12:16–05:14:18 UTC (~2 min of role + deterministic steps) plus the Supervisor
  commit and the human decisions; the first (blocked) attempt and the diagnosis/restart (a ~45-min gap, 04:26→05:12)
  added the rest of the wall time.

## 5. Human interventions

- Reproduction decision on the first attempt ("go on without reproducing"). That waiver **stood** across the restart:
  the DB shows `reproduction` did not re-run after the restart. Instead the deterministic `baseline` check ran and
  exited **ec=1 (RED)** — i.e. the frozen tests fail against the unfixed code, which is exactly how the baseline proves
  the tests detect the bug. (An earlier draft said reproduction re-ran and the waiver was moot; that was wrong.)
- Operational: the owner initialized the auth volume, completed the real `claude auth login` (in a real terminal —
  the `!` session shell has no TTY), and restarted the helper (to recover from the image-ordering mistake).
- The final **Done** decision.

## 6. Verified claims (handoff §2 / the Planner's acceptance list)

- Real subscription-backed Claude execution — **yes** (8 live sessions on the Max plan, end-to-end TLS, no API key).
- Normal Lockstep planning and **frozen regression tests** — **yes** (`6bb9032`).
- Exactly **one** code-writing Implementer — **yes** (only `run-live-write` is the Implementer; two attempts of the
  one Implementer, not parallel writers).
- Successful implementation and independent verification — **yes** (deterministic checks green after the fix).
- Independent Reviewer assessment and semantic challenge — **yes**, and now confirmed against the DB: a dedicated
  `review/reviewer` session (05:14:18) **and** two `challenger` sessions — a **pre-freeze** challenge (`challenge-pre`,
  05:13:09, before the tests were frozen) and a **post-fix** challenge (`challenge-post`, 05:13:59). The required
  pre-freeze challenge **did occur**.
- Supervisor-owned Git commit — **yes** (`cf0f209`, `6bb9032`; main untouched; nothing pushed).
- Recorded runtime, usage, retries, interventions — **yes** (§4, §5).
- Explicit human Done — **yes** (the owner).

## 7. Findings and limitations (detail in `smoke-notes.md`)

1. **Image-ordering mistake (mine), cost ~30,026 wasted tokens (one duplicated candidate stage) + the restart.** Build the runner/provider images
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

## 9. Reconciliation against the authoritative record (Planner §1)

The role sessions were reconciled against `lockstep_invocations` (the authoritative DB record), not just the helper
log. The actual Planner, Challenger, Implementer and Reviewer sessions all occurred as the workflow requires, and **the
required pre-freeze challenge DID occur** (`challenge-pre/challenger/answered`, before the tests were frozen).

Deviations found were in my earlier draft, not in the workflow — all corrected above:
- The restart **resumed** the transaction from `candidate` (discovery reused), so the mistake wasted **~30,026 tokens**
  (one duplicated candidate stage), not 58,341.
- Two role labels were wrong: the first post-restart run was the **candidate re-run** (not discovery), and the second
  was the **pre-freeze Challenger** (not "Planner Contract+tests").
- `reproduction` did **not** re-run after the restart (the waiver stood); the post-restart `baseline` exited **ec=1
  (RED)**, the correct baseline result, not exit 0.

No missing acceptance criterion was found. The workflow ran correctly end to end on the real subscription.

## 10. For the owner

Gate C-EXEC is **not** self-accepted. This packet (reconciled against the authoritative DB record) is the evidence of a
complete, independently verified, subscription-backed transaction with a human Done, presented for your explicit Gate
C-EXEC acceptance. Deferred and unaffected: Brigid dogfood (after C-EXEC acceptance), the role-count/cost scrutiny, the
tech-stack correction pass, UX-C8/C9, Phase 5.
