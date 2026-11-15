# Contract — P6.7 Provisional progression and human authority

- Contract ID: `C-P6.7@v1`
- Status: FROZEN (§5)
- Authority: `.local/plans/phase-06.md` §12 (P6.7); `.local/plans/phase-06_update1.md` §7; D6-AUTH (Bible v2.3 §8).
- Basis: `phase-6` after C-P6.6 qualified.
- Writer: the single writing agent (Implementer). The Implementer does not accept this subphase.

## 1. What exists, and what this adds

C-P6.5 already lets a technically accepted fix satisfy its dependents' technical edges on a provisional unit, before
the person's Done. Each dependent is built on the exact accepted commit, and the ancestors it built on are recorded
(`lockstep_fix_bases`). If a prerequisite is no longer satisfied when its dependent's basis stage runs, that
dependent halts (R-P6.5-1).

Three things are still missing:
- What happens to descendants **already built** on an ancestor the owner then rejects.
- What a later plan revision's `changed`/`invalidated` reconciliation means for work done under the old revision
  (C-P6.4: "will need redoing (Lockstep does not enforce this yet)").
- How work is **redone**: a task can be handed over only once (C-P4.1 X6).

P6.7 records each invalidation explicitly, stops what it affects at a safe boundary, keeps every record, and adds
an explicit rework path that needs fresh evidence.

| # | Decision |
|---|---|
| V1 | **Provisional acceptance is recorded, and is not Done.** A fix's technical acceptance (C-P4 `Accepted`) is the provisional local acceptance of D6-AUTH. The Ticket and the person's Done are unchanged. Nothing pushes, merges or publishes. |
| V2 | **Invalidation, recorded** (`lockstep_fix_invalidations`, immutable: the fix, its cause, a code, when). A fix is invalidated when: (a) the owner **rejects** it (Not done on an accepted fix, `rejected-by-person`) — not recorded for the fix itself, whose state already says so, but for each descendant; (b) a fix it was built on (`lockstep_fix_bases`, transitively) is rejected or invalidated (`ancestor-rejected`); (c) the owner approves a plan revision that reconciles its unit `changed` or `invalidated` (`plan-changed`). Its descendants follow (b). Pure: `Lockstep.Kernel.Invalidation.descendantsOf` over the recorded bases. Unrelated fixes are untouched. |
| V3 | **Effect on eligibility.** An invalidated accepted fix is `FixAcceptanceInvalidated` (C-P6.5 S1): it satisfies no edge. Its dependents wait, and its own unit waits as `invalidated` (words: it must be redone). The person's Done on an invalidated fix is refused (`acceptance-invalidated`). The Not done that rejects it, or the Stop, stays the person's. |
| V4 | **Active work stops at a safe boundary.** Before the engine runs any stage of a running fix, and before it applies a person's retry to a halted one, an invalidated fix halts at that stage (`ancestor-rejected` or `plan-changed`). Such a halt offers only Stop. No stage runs on an invalidated basis. This includes the acceptance stage, so a late finding prevents acceptance. A fix whose recorded ancestors are not all still accepted (or Done) and valid when it reaches acceptance halts `basis-stale`. |
| V5 | **History is kept.** Nothing is deleted or changed: every transaction, record, invocation, branch and commit stays, and the invalidation rows say why each fix stopped counting. Nothing is rolled back in Git. |
| V6 | **Rework, explicitly.** A task whose latest fix has **stopped** (by the person, or after an invalidation the person stopped) may be handed over again, by the person only (C-P4.1 X6, a new key). The scheduler never hands a stopped unit over again by itself (C-P6.5 `stopped`). The new hand-over has its own Work Order and transaction, and its fix collects all its evidence anew from a fresh basis under the governing revision. The task's latest hand-over is the one that counts. A second hand-over while the latest fix is still live, even if it is accepted, stays `already-admitted`. Eligibility returns only when the new fix is accepted and valid. |
| V7 | **No new authority.** An approved revision's unit with external effects is still never handed over (C-P6.5 `not-local`). A proposed or rejected revision changes nothing. Neither provisional acceptance nor rework needs or grants new owner authority. A rework of a `changed` unit runs under the newly approved revision. |

## 2. Typing

- Kernel: `Lockstep.Kernel.Invalidation` (`InvalidationCause`, `invalidationCode`, `descendantsOf`);
  `Kernel.Transaction`: the `Invalidated` input (legal at a running or halted stage); `haltChoices` gives Stop only
  for the invalidation codes and `basis-stale`.
- Persistence: migration 29 — `lockstep_fix_invalidations`; the admissions' and dispatches' one-per-task
  constraints are dropped (the latest counts; the task lock serializes).
- Application: `Engine` (decideCompletion propagates a rejection; advance checks invalidation; accept checks
  bases), `Tasks.fixOf` (latest admission; invalidated), `Execution.admitTask` (rework), `Plans.approve` (V2 c),
  `Dispatch` (rework, `invalidated` reason).

## 3. Mandatory tests (handoff §12) → cases

| Handoff test | Where |
|---|---|
| Verified ancestor unlocks dependent work without Human Done | integration `unlocksWithoutDone` |
| Human Done remains unchanged | integration `unlocksWithoutDone` (no Ticket or fix is Done) |
| Local technical acceptance cannot authorize push or merge | integration `unlocksWithoutDone` (no remote, the person's branch unchanged) |
| An ancestor rejection invalidates transitive descendants | integration `rejectionInvalidates` (a three-unit chain: rejecting the first invalidates the second and the third) |
| An unrelated branch continues | integration `rejectionInvalidates` (a fourth, independent unit is accepted) |
| A late finding prevents invalid acceptance | integration `lateRejection` (the ancestor rejected while the descendant is under way: it halts, never accepted) |
| Active descendant stops safely | integration `lateRejection` (halted `ancestor-rejected`, Stop only) |
| Stale Git basis refuses | integration `lateRejection` (`basis-stale` when a recorded ancestor no longer counts at acceptance) |
| Rework requires fresh evidence | integration `rework` (a second hand-over, a new transaction with its own records; the old ones kept) |
| New architecture or external-effect authority requires owner approval | integration `noNewAuthority` (an external-effect unit is never handed over; a proposed revision changes nothing) |
| (C-P6.4 debt) a changed unit's accepted work is invalidated | integration `planChangeInvalidates` |

## 4. Verification files

`test/unit/Lockstep/Kernel/InvalidationTest.hs`, `test/integration/Lockstep/ProvisionalTest.hs`, the runners.

## 5. Freeze record

| File | sha256 |
|---|---|
| `test/unit/Lockstep/Kernel/InvalidationTest.hs` | `c5f36a321513938021334287ed5119514f33bbdf140fadc85044fca337feaaa5` |
| `test/integration/Lockstep/ProvisionalTest.hs` | `8aa6145896932c0bd3ef03680d88c47392017a745f44f0c30ee18919f0c1facb` |
| `test/integration/Main.hs` (shared runner; supersedes R-P6.6's digest, additive) | `daf08d724849e292db28433227f86b57537b7f6e2ab9ca4995d4bcbde62eafd4` |
| `test/unit/Main.hs` (shared runner; supersedes R-P6.6's digest, additive) | `7955715d43fb38f3834c6b09484acba65921108f7f0672e902a0ce07865e5c7e` |

Formatted and linted before the digests were taken.

**RED baseline against the stubs.** The stubs are `Kernel.Invalidation`; the `Invalidated` input with no transition
(illegal); and the `InvalidatedUnit` reason with no code, words or use. Nothing else changed.
- Unit: **10 of 13 fail**. The three that pass assert refusals the stub's illegal input already gives (accepted,
  done or stopped; not the Supervisor) and the input's name.
- Integration: **4 of 6 fail**, each at its missing behaviour: no invalidation record, a fix under way not stopped,
  no rework hand-over (`already-admitted`), no plan-change record.
- Kept as guards (they pass): the C-P6.5 behaviour that a technical acceptance unlocks its dependent without Done,
  push or merge, and the C-P6.4 refusal of external effects with nothing handed over for a proposed revision.
- Logs: `.local/evals/phase-06/p67-baseline-*.log`.

**Disclosed:** as for C-P6.6, the frozen tests were first run against the implementation in the working tree
(Phase 6 unit 155/155, P6.7 integration 6/6, `.local/evals/phase-06/p67-pretrial-*.log`), so that later assertions
that RED never reaches would not freeze a fixture mistake. None was found and no test changed. The stub tree was then
restored and the baseline above run on it before this freeze.

## 6. Allowed paths

New: §2/§4 files, `docs/gates/P6.7/**`. Changed: `Kernel/Transaction.hs`, `Kernel/Dispatch.hs` (the
`invalidated` reason), `Persistence/Migrations.hs` (append 29), `Persistence/Execution.hs`,
`Persistence/Dispatch.hs`, `Application/Engine.hs`, `Application/Tasks.hs`, `Application/Execution.hs`,
`Application/Dispatch.hs`, `Application/Plans.hs`, `Web/PlanPage.hs`, the runners, `docs/OPERATOR_GUIDE.md`.

## 7. Budget, stop, rollback

At most 3 attempts per failing frozen test. Model-free (scripted roles). Rollback: the branch; migration 29 is
additive except the two dropped constraints, which are replaced by the task lock (recorded).
