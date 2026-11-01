# Attended calculator smoke — running notes and evidence (C-P4.L.N, candidate 05da865/9898fc2)

Live, attended, native subscription (owner's Max plan), disposable repo `~/lockstep-projects/calc-smoke`
(`calc.py` = `return a - b`, initial commit `35c1ec6`). Started 2026-11-01.

## Live role runs (from the helper log; usage is total tokens over the role's whole agentic session)

- `run-live-readonly 5ec815c3…` exited 0, **28,315 tokens** — Planner discovery.
- `run-live-readonly a80f57cf…` exited 0, **30,026 tokens** — second read-only step.
- Transaction halted at **reproduction**: "Lockstep could not make the bug happen" (the fixture has no test to
  make the bug observable); owner decision pending (go on without reproducing / try again / stop).

Milestone confirmed: a real request on the owner's subscription reached Anthropic over end-to-end TLS through the
passthrough filter and returned (native auth works end to end).

## Operational lesson: rebuilding the runner image under a running helper (2026-11-01)

The transaction first halted at `candidate baseline-run-failed`: the deterministic `run-verify` containers
(reproduction, baseline) failed to launch with Docker **exit 125**, while the live model runs succeeded. Root cause
(self-inflicted, not a Lockstep defect): `scripts/service install` was run *after* the helper had started, and it
rebuilds the `lockstep-dev:p1` tag — which is also the runner image. The running helper had cached the previous image
**ID** at startup (`e840d3e8…`); after the rebuild the tag moved to a new ID (`418f6426…`) and the helper kept
invoking the stale ID for every verify → 125. Live runs were unaffected because they use the separate provider image.
Restarting the helper (it re-reads the image ID) fixed it.

**Operator rule:** build/install the runner and provider images **before** starting the `--runner` helper; if either
is rebuilt, **restart the helper** so it re-reads the image IDs. **Possible Lockstep hardening (for the Planner):**
the helper could detect a moved/missing runner image ID and refuse cleanly (as it already does for the provider image
at start) rather than fail opaquely with a per-run 125; or resolve the image by tag per run. (Deferred.)

## Future metric (owner, 2026-11-01) — surface a per-run token breakdown

The per-run total (~30k for a short read-only role) reads as "a lot" because it is surfaced as one summed number that
includes cache reads. It is ordinary Claude Code usage: an agentic multi-turn session re-sends the system prompt, the
built-in tool schemas (Read/Edit/Bash), the role instructions and all prior tool results each turn, mostly counted as
cache reads; output is a small fraction. Same mechanism as any Claude Code session.

**Backlog item:** Lockstep should surface a **breakdown** of each run's usage — input, output, 5-minute cache write,
1-hour cache write, cache read — rather than one opaque total, so operators are not caught off guard by the number.
The data is available in the CLI's own JSON result (`usage`); `execute_native_run` currently sums it into
`egress.tokens` and could record the split alongside. (Deferred; not part of this smoke. Noted because the owner was
surprised by the summed figure.)

## Per-transaction overhead and the role count (owner, 2026-11-01)

The full transaction runs the same ceremony for a one-line fix as for a serious defect: a fixed floor of ~5–6 live
model sessions (plus container spin-up each time and the human decision points). Observation: the per-transaction
cost (wall time + tokens) is large relative to a trivial fix. **Not a serious issue unless trivial bugs are common in
real projects** (frequency unknown); the ceremony's value (frozen tests, independent challenge, independent review,
Supervisor-only commit, human Done) is what makes it trustworthy on a real bug.

**Backlog items:**
- A **cost monitor** for a transaction (tokens and wall time across all its role runs), surfaced to the operator.
- **Scrutinize the role count.** The intended set was three — Planner, Implementer, Reviewer. The engine actually
  uses **four** role types (`src/Lockstep/Kernel/Roles.hs`: Planner, Challenger, Implementer, Reviewer), and two run
  twice, so a clean transaction is up to six live sessions:
  1. Planner — discovery (P4.6)
  2. Planner — Contract + candidate tests (P4.8)
  3. Challenger — challenge the candidate tests before the freeze (P4.7 / DG-07)
  4. Implementer — the fix (P4.10; up to two attempts, Transaction.hs:168)
  5. Challenger — challenge the fix after it (P4.12)
  6. Reviewer — independent review (P4.13)

  (Verification/the automatic checks and reproduction are **deterministic** — Lockstep runs them itself, no model
  session.) The extras beyond the intended three are the **Challenger** (×2, the adversarial integrity check) and the
  **two-stage Planner** (discovery then Contract). Both are deliberate Phase 4 design (DG-07 for the challenge), but
  whether each needs a full, separate ~30k-token model session is worth the Planner's scrutiny — e.g. whether the
  Challenger could be cheaper/merged, or the Planner's two stages combined, without losing the independence that
  makes the challenge and review meaningful. (Deferred; a design-scrutiny item, not a smoke fix.)

### Provenance of the Challenger, and the owner's reconsideration (2026-11-01)

For the record: the Challenger was not added unilaterally. It traces to **DG-07** ("Semantic challenger independence,
budget, disposition, escalation"), **ACCEPTED WITH CLARIFICATION by the owner on 2026-10-28** (D-7.1–D-7.4;
`docs/governance/DECISION_REGISTER.md`, `.local/plans/phase-04_update1.md` §DG-07), whose wording specifies "a
separate read-only challenger invocation without the Planner's or Implementer's transcripts," the dispositions and
budgets, and scratch-snapshot execution; and to `phase-04.md` P4.7 (pre-freeze challenge) and P4.12 (post-work
challenge). The owner did not recall authorizing it and is reconsidering it — their prerogative.

**For the Planner (deferred, design scrutiny — not a smoke fix):**
- The owner questions whether the **pre-freeze Challenger (P4.7)** is necessary at all.
- The owner suggests the **post-work Challenger (P4.12)** responsibilities might belong to a **Verifier** instead.
  (Note: today verification is deterministic — Lockstep runs the frozen checks itself, no model role — so a model
  "Verifier" would be a new role; the trade is independence vs. the cost of an extra ~30k-token session.)
