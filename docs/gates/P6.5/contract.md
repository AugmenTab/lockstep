# Contract — P6.5 Continuous deterministic scheduling of an approved plan

- Contract ID: `C-P6.5@v1`
- Status: FROZEN (§5)
- Authority: `.local/plans/phase-06.md` §10 (P6.5, "the central capability of Phase 6"); `.local/plans/phase-06_update1.md`
  §5 (cancellation target), §7; DG-08 (Option 2); D6-AUTH (Bible v2.3 §8: one approved plan permits automatic local
  dependency-ready progression; final Human Done separate).
- Basis: `phase-6` after C-P6.4 qualified (`b32da66`, record `cc8120b`).
- Writer: the single writing agent (Implementer). The Implementer does not accept this subphase.

## 1. What exists, and what this adds

C-P6.4 makes an approved plan's units canonical tasks with typed edges. The engine worker already starts a fix for
every handed-over task (one writer per Engineer, in hand-over order) and advances it; a person still hands each task
over and nothing ever satisfies a dependency, because no code path brings a task to `done` (P6.2 review D1). P6.5
adds the **deterministic dispatcher**: inside the existing engine worker, before its transactions, it hands over the
next eligible unit of each project's effective plan by itself, so no person presses Continue between eligible units.
It is not a model, not a queue of agent commands and not a second scheduler: it is a pure Kernel decision over the
durable facts, followed by the existing hand-over (`admitBug`'s checks and writes) and the existing engine.

| # | Decision |
|---|---|
| S1 | **When a prerequisite is satisfied** (pure `Lockstep.Kernel.Dispatch.prerequisiteSatisfied`, used for *every* task's readiness, not only plan tasks): its Ticket is `done` (as before); or its latest fix is **Done** by the person (any edge kind; this closes P6.2 D1 for ordinary tasks too); or — only for a **technical** plan edge whose prerequisite unit is `provisional` in the effective revision — its latest fix is **technically accepted** (`Accepted`: verified, reviewed, committed on its work branch by the Supervisor) and that acceptance is not invalidated. A `human-acceptance` or `external` edge, or an untyped task dependency, needs the person's Done. A canceled prerequisite still means the dependent cannot start. |
| S2 | **Eligibility** (pure `dispatchDecision`), per project, of each unit of the **effective** revision: its task is ready to work (with S1); it has not been handed over; the project's execution is enabled; the repository's one writer is free (no handed-over task of the project whose fix is not yet `Accepted`, `Done` or `Stopped`); the plan's token budget, when it has one, is not unknown (Lockstep does not yet record usage, so a budgeted plan **waits** with `usage-unknown`; it is never treated as available); the unit is local-only (C-P6.4). A unit that is not eligible has exactly one **waiting reason** with a code and words. |
| S3 | **Order** (DG-05 S7 where compatible): priority (high first), then the unit's position in the plan, then its key. Priority never bypasses a dependency: only eligible units are ordered. At most one unit per project is handed over per pass (one writer per repository). |
| S4 | **Hand-over** of the chosen unit is the existing `admitBug` path — same refusals, same rows, same profile binding — under an idempotency key fixed by the project, the revision's digest and the unit, with the actor `scheduler`; inside the hand-over's transaction the effective revision is read again and must be the one decided on (else `stale-plan-revision`, nothing written); the hand-over is recorded in `lockstep_plan_dispatches` in the same transaction. Two dispatchers at once produce one admission (the task lock, the unique admission per task, the key). |
| S5 | **Continuous.** The engine worker's pass runs the dispatcher first, then starts and advances transactions as before; a unit whose prerequisites become satisfied is handed over on the next pass with no person involved. A three-unit chain whose edges are technical and provisional runs to the end on one approval. |
| S6 | **Restart.** Nothing is in memory: a restart before the hand-over commits leaves nothing (the next pass decides again, same key); after it, the unit is handed over and is never handed over again; an accepted unit is never re-dispatched; a replayed pass creates no admission and no invocation. Uncertain effects are not retried by the dispatcher (the engine's own recovery applies). |
| S7 | **Truthful waiting.** The plan page shows, for the effective revision, the next unit to hand over and each other unit's waiting reason (codes: `waiting-for` with the prerequisites, `writer-busy` with the task that holds it, `execution-not-enabled`, `usage-unknown`, `queued-behind`, `handed-over`, `finished`, `not-ready`, `blocked`, `cannot-start`, `canceled`, `not-local`, `unknown`). A withdrawn unit is not in the effective revision, so it has no reason here (its task is blocked, C-P6.4 R-P6.4-2). A human decision that holds one fix holds only that repository's writer: another project continues. |
| S8 | **The basis of a dependent fix.** A fix whose task has a prerequisite satisfied by a technical acceptance alone (S1) starts from that **accepted commit**, not from the person's checkout: the Supervisor creates the work branch at the accepted commit (C-P4 compare-and-swap rules unchanged) and records each such acceptance as the fix's basis provenance (`lockstep_fix_bases`). With several such prerequisites the basis is the one accepted commit that contains all the others (a Git ancestry check); if none does, the fix halts at its basis with `basis-ambiguous`. A fix with no such prerequisite starts from the checkout as before. |
| S9 | **No new authority.** The dispatcher hands over only units of an owner-approved effective revision; a proposed, rejected or superseded revision dispatches nothing; nothing pushes, merges or publishes; Human Done stays the person's. |
| S10 | **Cancellation during a fix** (update 1 §5): a task whose fix is handed over, running, halted for a decision, or accepted and waiting for the person's Done cannot be canceled (`fix-active`); the person stops the fix through its existing Stop choice and may cancel once it has stopped. The page keeps showing the fix's real state. |

## 2. Typing

- Kernel: `Lockstep.Kernel.Dispatch` — `FixFact`, `PrerequisiteFact`, `prerequisiteSatisfied`, `readinessWith`,
  `UnitFacts`, `ProjectFacts`, `BudgetFact`, `WaitReason` (+ code, words), `DispatchDecision`, `dispatchDecision`,
  `chooseBasis`.
- Persistence: migration 26 — `lockstep_plan_dispatches` (revision, unit, task, Work Order, key; immutable) and
  `lockstep_fix_bases` (transaction, the acceptance it builds on: ancestor transaction, accepted commit; immutable);
  `Lockstep.Persistence.Dispatch`; `Persistence.Plans.effectiveRevision`, `allPlans`.
- Effects: `GitSupervisor.isAncestor`, `GitSupervisor.commitBasis`.
- Application: `Lockstep.Application.Dispatch` (`dispatchOnce`, `dispatchView`, `handOverUnit`), `Application.Tasks`
  (S1 in readiness, `fixFactOf`; S10), `Application.Execution` (`admitTask`, the shared hand-over), `Application.Engine`
  (S8 in the basis stage), the worker's first phase (`engineOnceWith`, `startEngineWorkerWith`).
- Web: the plan page's "What runs next" part.

## 3. Mandatory tests (handoff §10) → cases

| Handoff test | Where |
|---|---|
| Three dependent units execute automatically | integration `chain`: a 3-unit technical/provisional chain, one approval, worker passes only → three fixes accepted, each built on the previous accepted commit |
| Multiple ready units use deterministic ordering | unit (`dispatchDecision`: priority, position, key); integration `ordering` |
| Priority cannot bypass dependencies | unit; integration `ordering` (a high-priority waiting unit is not handed over) |
| Two dispatcher contenders obtain at most one claim | integration `contenders` (two concurrent `dispatchOnce`) |
| Restart before claim settlement does not duplicate work | integration `contenders` (a fresh runtime; same key; one admission) |
| Restart after settlement does not redispatch accepted work | integration `chain` (a fresh runtime after three acceptances) |
| Stale plan revision refuses | integration `staleRevision` |
| Unavailable resource produces truthful waiting state | unit; integration `waiting`, `ordering` (`execution-not-enabled`, `writer-busy`) |
| Unknown quota is never treated as known availability | unit; integration `waiting` (`usage-unknown`) |
| A human decision blocks only affected work | integration `humanBlocksOnlyItsOwn` |
| No manual Continue is required between eligible units | `chain`, through the worker's pass |
| (P6.2 D1) a Done fix satisfies its dependents | integration `doneSatisfies` |
| (update 1 §5) no cancel while a fix is active | integration `cancelDuringFix` |

## 4. Verification files

`test/unit/Lockstep/Kernel/DispatchTest.hs`, `test/integration/Lockstep/DispatchTest.hs`, and the two runners.

## 5. Freeze record

| File | sha256 |
|---|---|
| `test/unit/Lockstep/Kernel/DispatchTest.hs` | `00fa924924ea885d0ed453028a6af09526a00763f4de1566d05f01f78e14fa70` |
| `test/integration/Lockstep/DispatchTest.hs` | `220695b41c905467a36d0f130a7b499e6c9b41ac193d1e1dc9016177eb22a88f` |
| `test/integration/Main.hs` (shared runner; supersedes R-P6.4's digest, additive) | `120739d9f645df509de659de54e83f9659d250f244095e02b9acdcf83472ee05` |
| `test/unit/Main.hs` (shared runner, additive) | `e7fd5d7619fc7cc538812a95eb967b565ebab3b6c319c91356a107cf13a5e402` |

Formatted and linted before the digests were taken. RED baseline against the stubs (`Kernel.Dispatch` and
`Application.Dispatch` stubs; nothing else changed): unit **14 of 16 fail** (the two that pass assert that nothing
satisfies and that no candidate gives the checkout, which the stub's constants happen to give); integration **8 of 8
fail**, each at its own missing behaviour (no hand-over by the worker; `not-implemented`; no claim; no
`stale-plan-revision`; a Done fix does not satisfy; cancel during a fix allowed). Logs:
`.local/evals/phase-06/p65-baseline-unit.log`, `p65-baseline-integration.log`.

Before the freeze the scripted Reviewer was given its `inspected` files (else every fix halts `review-needs-human`,
which would have made the `doneSatisfies` case fail at its fixture, not at S1), and `passesUntil` reports the last
pass when it gives up.

## 6. Allowed paths

New: §2/§4 files, `docs/gates/P6.5/**`. Changed: `Persistence/Migrations.hs` (append 26), `Persistence/Plans.hs`,
`Effects/GitSupervisor.hs`, `Application/Tasks.hs`, `Application/Engine.hs`, `Application/Execution.hs`,
`Application/EngineWorker.hs`, `Web/PlanPage.hs`, `Web/App.hs`, `app/lockstep/Main.hs`, the runners,
`docs/OPERATOR_GUIDE.md`.

## 7. Budget, stop, rollback

At most 3 attempts per failing frozen test. Model-free (scripted roles). Rollback: the branch; migration 26 is additive.
