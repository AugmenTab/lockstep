# Phase 6 update 2 — frozen-test amendments

Each amendment below was authorized by the owner (`docs/gates/P6/update2-decisions.md`). Nothing else in a frozen
test was changed.

## A-U2-1 — C-P6.4 `PlanTest.parity` (R6.2)

- File: `test/integration/Lockstep/PlanTest.hs`, case `parity` only, plus one import line
  (`chooseChecks`, `ChecksOutcome`).
- Old digest: `ba6239f10e5ffadf6b6a6dc42348342da72e7a0cd80718548b597784d5e1a09d` (frozen by R-P6.4).
- New digest: `4212d49da487ab2e5ac4a02dfae91b6194f90a97f90f72c3c45b7a3084b759c7`.
- Why: the case handed the greenfield unit `core` (whose fixture names the bug-fix Profile) over through `admitBug`
  with bug-only project checks and expected it accepted; that is the defect R6.2 removes (a plan unit handed over
  by a person ran as a bug fix).
- Change: in this case only, `core` names `lockstep-engineering`; after enabling execution the owner chooses the
  engineering checks; two counts are added: the plan task's admission is `greenfield`, the ticket's `bug-fix`.
- Invariants kept: a plan-derived task and a ticket-derived task have the same view, readiness and hand-over;
  both hand-overs are accepted with distinct Work Orders; two admissions; a waiting plan task is refused
  `task-waiting`. The shared `caesura` fixture and every other case are unchanged.
- Baseline: RED against the stub (`core` admitted as a bug fix, greenfield count 0, `PlanTest.hs:523`); green with
  the U2-A implementation.
