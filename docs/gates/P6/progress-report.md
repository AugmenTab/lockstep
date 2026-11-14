# Phase 6 — progress report and decisions needed (interim, not a completion packet)

- Handoff: `.local/plans/phase-06.md`. Writer: the single writing agent (Implementer). **Nothing here is accepted by
  the Implementer; no gate or subphase is self-accepted.**
- Branch `phase-6` (local only; not pushed), from `6589fe2` (stabilization-1 tip; source identical to the installed
  `d00e26c`). Session 2026-11-13/14, owner away: no provider call, no host change, no external connection, no push.
- Retrospective and evidence index: `.local/retros/retro-06.md`; logs `.local/evals/phase-06/`.

## 1. Governing documents (handoff §1.3)

Already committed before this session (`55c5611`, `6aac167`, `9bf1719`, `6589fe2`). Digests re-verified equal to the
ratification manifest: amendment `4a14dfee…590d`, PRD v0.4 `a69558b1…4522`, Plan v0.4 `7e478504…5c50`.
DG-08 registered as OPEN with its packet (`48a388c`).

## 2. Status by subphase

| Subphase | Status | Evidence |
|---|---|---|
| P6.1 Canonical backlog & intake | **Implemented, locally qualified** (owner acceptance pending). Live Jira/Shortcut intake **NOT_RUN** (no authorized connection); Shortcut adapter NOT_BUILT | `docs/gates/P6.1/` (contract, review); full check `a1deaf9` PASSED (unit 923, integration 602) |
| P6.2 Progress page (command center) | **Implemented, locally qualified** (owner acceptance pending) | `docs/gates/P6.2/`; full checks `0039526`, `081201f` PASSED (unit 944, integration 605) |
| P6.3 Human Inbox & bounded clarification | **Implemented; one frozen case FAILED pending amendment A-P6.3-1** (a literal in my own frozen test; the implementation is right) | `docs/gates/P6.3/` (contract, amendments, review); full check of `2d65a1f`: see §4 |
| DG-08 | **Decision required** | `docs/gates/DG-08/decision-packet.md` |
| P6.4 PRD → Master Plan, DAG, freeze | **BLOCKED on DG-08** (and the frozen-test ruling in its §4) | — |
| P6.5 Continuous scheduler | BLOCKED (needs P6.4) | — |
| P6.6 Profile parity | BLOCKED (needs P6.4, P6.5) | — |
| P6.7 Provisional progression | BLOCKED (needs P6.5, P6.6). Carries the engine gap found in P6.2's review: a Done fix never closes its task, so dependents never become ready | `docs/gates/P6.2/review.md` D1 |
| P6.8 Scribe, P6.9 proposals | BLOCKED (need P6.7) | — |
| P6.10 Host-enforced capsule safety | **P6.10a design done (nonprivileged)**; measurements M1–M3 NOT_RUN (host probing not done unattended); **D6-SEC request drafted**; P6.10b/c need owner authority | `docs/gates/P6.10/design.md` |
| P6.11 Model-free Gate D | NOT_STARTED (needs P6.1–P6.10) | — |
| P6.12 Caesura | **BLOCKED** — needs P6.11, the Caesura PRD/milestone, a provider budget (D6-GATE) and D6-SEC | — |

## 3. Decisions requested from the owner

1. **DG-08** — plan approval/freeze/amendment semantics: recommended Option 2 (immutable approved outline,
   bounded just-in-time Contracts). Also rule on the frozen C-P4.1 assertion that bans `plan`/`phase` in column names
   (`ExecutionTest.hs:437-438`): recommended amendment A-P6.4-1 (keep "a bug needs no plan", drop the name ban).
2. **A-P6.3-1** — authorize correcting two literals in `test/integration/Lockstep/InboxTest.hs` (`"human"` →
   `"Human"`, `"supervisor"` → `"Supervisor"` as C-P4.3 stores them). Details in `docs/gates/P6.3/amendments.md`.
3. **Cancel during a fix** (P6.2 review D2): cancelling a task whose fix is running hides the fix behind "Canceled".
   Recommended: refuse cancel while a fix runs or waits (with P6.5/P6.7's safe-boundary stop).
4. **P6.10** — agree that the measurements M1–M3 (host process/uid behind guest connections; public egress; Lima as a
   dedicated user) may be run with you present; then D6-SEC (`docs/gates/P6.10/design.md` §7).
5. **Push** — `phase-6` exists only locally.

## 4. Full-check results (latest)

`scripts/check --integration` on **`2d65a1f`** (`.local/evals/phase-06/p63r-full-check.log`):

| Step | Result |
|---|---|
| format, lint/static, build, unit (950/950), no-live-model guard | PASSED |
| integration | **FAILED: 621/622** — the single failure is `InboxTest` "a person's question gets one read-only Planner answer…", the A-P6.3-1 literal (`"human"` expected, `"Human"` stored). No other case fails; the C-P4.16 regression found on `ad191be` is fixed. |
| backup/restore | **NOT_RUN** on `2d65a1f` (the script runs it only after a passing integration step); it PASSED on `081201f`, and migration 23 is additive |

If A-P6.3-1 is authorized and applied, the expected result is a full PASS; that has not been observed.

## 5. Limitations recorded

- Clarifications: no per-run process/usage record (NOT_RECORDED); live/capsule clarification NOT_RUN; whether an
  empty workspace stops a capsule-bridged Planner from reading the project capsule is open.
- P6.2 shows model usage as "not recorded"; engine standings beyond the hand-over are qualified only from
  constructed views until P6.11.
- P6.1 dependency kinds are untyped (provenance only) until P6.4.
