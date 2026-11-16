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

## A-U2-2 — C-P6.9 `ProposalTest` (OQ-P6.9-1, R6.6)

- File: `test/integration/Lockstep/ProposalTest.hs`.
- Old digest: `f3c389c145bc5a83fe793eb3560de5538c8b26bc7a2dcef096d8da4a091bd975` (frozen by C-P6.9).
- New digest: `6a66504475dd7e2fca075633ae9bd459e3d8936875dbce8f52b3c2cdab2b8301`.
- Why: (a) the shared fixture cited a well-formed SHA no fix recorded, so `commit:` evidence could only be checked for
  form; (b) `selfPrivilege` expected a proposal for the unregistered `team-checks` to be accepted, so a non-catalog
  target could not be refused.
- Change: `haltedFix` no longer writes an uncommitted file, so its fix records its basis commit and halts at discovery
  (no helper) instead of at its basis; a helper `recordedCommit` reads that basis; the shared `proposal` fixture takes
  the commit it cites, and `duplicates`, `forged` and `stale` now make the halted fix first to have one; `selfPrivilege`
  registers `team-checks` version 1 before proposing for it.
- Invariants kept: every assertion of every case (duplicates count once; only a person decides, once; stale decisions
  refused; an approval mutates nothing; private scope; a summary proposes nothing; self-privilege refused; an unknown
  fix refused).
- Baseline: the amended cases pass against `aa28633` and against the implementation.

## A-U2-3 — R-P6.9 `ProposalReviewTest` (R6.6)

- File: `test/integration/Lockstep/ProposalReviewTest.hs`.
- Old digest: `06e8e6940b8ef6fd67a1e154aeb6d5670a0d44194e091d4d79a00a5e271b5494` (frozen by R-P6.9).
- New digest: `12dbebfda3ca6e6946c097b24fdbdd51b10e2fec8b1f7a2d4565c8b6f779493a`.
- Why: `spelling` cited the unrecorded literal SHA `0123…4567` and expected it accepted; its `halted` helper halted the
  fix at its basis, so no commit was ever recorded.
- Change: `halted` no longer writes the uncommitted file (the fix records its basis and halts at discovery, still with
  an open request and records); `spelling` cites that recorded basis (lower and upper case) instead of the literal.
- Invariants kept: every assertion (`free-text-commit`, `short-commit` still refused; resolved evidence accepted; a
  second spelling counts once; a stale catalog rule refused; a recorded proposal decided as recorded).
