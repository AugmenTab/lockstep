# P2.6 Contract — Typed executor and persistent dispatch

- Contract ID: `C-P2.6@v1`
- Status: **FROZEN** (2026-10-19)
- Basis: `v2` at `60e475e` (P2.5 `VERIFIED — awaiting human acceptance`); the C-P2.5 intent
  lifecycle (§3), fencing (E4), dispatch marker (E5), observations (E6) and budgets (E7), unchanged.
- Authority: `.local/plans/phase-02.md` §10 (P2.6); **DG-04 ACCEPTED with safety clarifications**
  (`docs/gates/P2.5/dg-04-decision-request.md`): D-4.5 (crash table, amended by requirements 3
  and 5), D-4.7, D-4.9 and binding requirements 1, 2, 4, 5 and 7. Class-C lookup
  (requirement 3), human resolution of an unknown outcome (D-4.6, requirements 5 and 6),
  late-observation handling after reconciliation and real cross-process contention are C-P2.7.
- Traces: FR-EXE-02, PRD §6.2 (effects outside the transaction; `RECOVERY_REQUIRED` when
  unprovable; an old worker's late observation is rejected), PRD §4.1 (unknown outcome), Bible §38.
- Writer: the single writing agent (manual).

## 1. Objective

Execute a durably authorized effect intent through a typed, model-free adapter, with these
guarantees:

- No effect is attempted without a committed claim and a committed dispatch marker for an
  active Work Order.
- Every answer, or the lack of one, is stored as an observation correlated with the operation
  id and the claim generation.
- After a crash, recovery follows the D-4.5 crash table for the effect's class. A crash, a
  timeout, a missing or malformed answer, or an adapter failure is never success and never
  permission to retry by itself.
- An unknown outcome halts the Work Order and stays visible until C-P2.7 (lookup or a human)
  resolves it.

Phase 2 adapters are scripted and in-process. Nothing here invokes a model, a provider, Git or
the network. The Phase 1 no-op dispatcher is unchanged (D-4.8).

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| X1 | **Adapters** (`Lockstep.Effects.Executor`). An `EffectAdapter` declares the exact `EffectSpec` it implements and a run function from (operation id, parameters) to a `DestinationAnswer`: `AnswerApplied result` or `AnswerNotApplied reason`, as the destination reports. Effect-specific semantics (deduplication, lookup) live only in adapters and their destinations (D-4.9). There is no generic retry wrapper (requirement 7). |
| X2 | **Invocation** (`invokeAdapter timeoutMs adapter operation parameters`) runs the adapter **once** and turns what happened into an `Observation`: applied with a valid text → `DestinationApplied`; not applied with a valid text → `DestinationNotApplied`; a text that is empty, longer than 4096 characters or contains a control character → `NoAnswer "malformed-answer"`; no answer within the timeout → `NoAnswer "timeout"`; a synchronous exception → `NoAnswer "adapter-failed"`. Asynchronous exceptions (a cancelled worker) propagate and are never turned into an observation. |
| X3 | **Scripted destinations** (`Lockstep.Effects.Scripted`). An in-process destination records every application (operation id, parameters), oldest first. A scripted adapter takes one script step per call (`StepApply r`, `StepRefuse r`, `StepApplyThenHang r`, `StepHang`, `StepApplyThenFail`, `StepFail`, `StepMalformed`); after the script, every call is `StepApply "ok"`. For an `idempotent` spec the destination deduplicates by operation id, as requirement 2 demands: a repeat with the same parameters answers the first result without applying again or consuming a step; a repeat with different parameters answers `AnswerNotApplied "changed-parameters"`. Its keys never expire within the process, which exceeds any declared key lifetime. Other classes apply on every applying step. `StepMalformed` applies and answers an empty text (an effect that ran, with an unusable answer). A hang lasts one hour; failures throw. |
| X4 | **Executor configuration.** An `Executor` has an owner (non-empty, no control characters), a lease of 1–3600 seconds, an adapter timeout of at least 1 ms and **less than the lease**, and its adapters (at most one per spec name). Anything else is `invalid-record`, and nothing is written. |
| X5 | **Execution** (`executeIntent`), in this order, each step its own transaction: (1) load the intent; no adapter with its spec name → `no-adapter`; an adapter whose spec differs in any respect → `adapter-mismatch` (nothing written); (2) **claim for execution**: locks the Work Order, then the intent; the C-P2.5 claim decides, and an accepted claim for an order that is not `active` is `subject-not-active` (nothing written); (3) **begin dispatch**: the same locks; the C-P2.5 dispatch decides, and an accepted dispatch for an order that is no longer `active` is `subject-not-active` (nothing written); an accepted one commits the marker; (4) invoke the adapter (X2); (5) **conclude** (X6). The adapter is invoked only after (3) commits. Refusals pass through unchanged. |
| X6 | **Conclusion** (`concludeIntent`, one transaction; locks the Work Order, then the intent). It stores the observation with the generation (C-P2.5 observe). A refused observation (stale, settled, abandoned or already observed) is **stored as evidence** with `accepted = false` and its refusal code (requirement 4), and the refusal is returned. Then by result: applied → settled (applied); not applied with `dispatches ≤ budget` → stays `confirmed-not-applied` (claimable again, C-P2.5 E7); not applied with `dispatches > budget` → settled (not applied) and the order halts with `retries-exhausted operation=<uuid>`; no answer → `outcome-unknown` and the order halts with `outcome-unknown operation=<uuid>`. A halt is the C-P2.2 `halt` by `Supervisor`, appended as an event in the same transaction, only when the order's lifecycle accepts it (claimed, active or waiting); otherwise no event is written. Conclusion never requires an active order: an effect that ran is always recorded. |
| X7 | **Recovery** (`Lockstep.Kernel.Recovery`, pure; D-4.5 windows W4/W5). For a `dispatched` intent whose lease has ended (`now ≥ lease end`), with the input (owner, now, new lease end, whether the order is active). Check order: `Agent` → `agent-assertion`; settled or abandoned → `already-settled`; not `Supervisor` → `not-authorized`; not `dispatched` → `nothing-to-recover`; `now` < lease end → `lease-active`; then: order not active → unknown `dispatch-interrupted: subject not active`; `repeatable` or `idempotent` with `dispatches ≤ budget` → **redispatch**: `claimed` with generation + 1, the new owner and lease end, the same operation id, parameters and dispatch count (the next dispatch counts); `repeatable` or `idempotent` with `dispatches > budget` → unknown `dispatch-interrupted: no retry left`; `queryable` → unknown `dispatch-interrupted: lookup not available` (C-P2.7 adds the lookup; until then the outcome is not provable); `unqueryable` → unknown `dispatch-interrupted: unqueryable effect` (requirement 5: never re-dispatched automatically). |
| X8 | **Recovery, durable** (`recoverDispatched`, one transaction; locks the Work Order, then the intent; the database clock). It applies X7, writes the intent and appends one recovery record: the generation it replaced and the canonical text (§4). An unknown result halts the order as in X6. A refusal writes nothing. `recoverAndExecute` recovers and, on a redispatch, continues at X5 step (3) under the new generation. |
| X9 | **Crash windows** (D-4.5). W2 (`pending`): an executor claims it. W3 (a claim, no marker): a new executor reclaims after the lease ends (C-P2.5: no budget used) and dispatches. W4/W5 (a marker; the effect may or may not have run): only recovery (X7); a claim is `dispatched-needs-recovery`. W6 (an observation stored, not settled) cannot arise: X6 observes and settles in one transaction. W7 (a late or duplicate observation): refused and stored as evidence (X6). |
| X10 | **Selection.** `runnableIntents`: intents of `active` Work Orders that are `pending`, `claimed` with an ended lease, or `confirmed-not-applied` with `dispatches ≤ budget`, oldest first. `recoverableIntents`: `dispatched` intents with an ended lease, oldest first, whatever their order's state. `executeOnce` (a dispatcher pass; a restarted worker calls it) first recovers the oldest recoverable intent the executor has an adapter for, else executes the oldest runnable one it has an adapter for, else returns nothing. One intent per pass; no loop. |
| X11 | **Faults** (library-only `ExecutorFaults`): hooks after the claim, after the dispatch marker and after the effect, before its conclusion. A hook's exception propagates to the caller. It stands for the worker dying at that point: everything already committed stays, and nothing after it happens. The binary has no fault plan (the C-P1.7 guard is unchanged). |
| X12 | **Migration 0009** (forward-only, adds one table): `lockstep_effect_recoveries` (`id`, `operation_id` → intents, `generation`, `decision`, `recorded_at`). It refuses UPDATE, DELETE and TRUNCATE through `lockstep_refuse_change()`. |
| X13 | **No new commands.** P2.6 adds library functions only. Operator commands and evidence views are C-P2.8. |

## 3. Recovery table (normative)

`d` is the dispatch count, `b` the budget. Only after the checks of X7 (a `dispatched` intent
whose lease has ended, by `Supervisor`).

| Order active | Class | `d ≤ b` | Result |
|---|---|---|---|
| no | any | any | unknown `dispatch-interrupted: subject not active` |
| yes | repeatable, idempotent | yes | redispatch: `claimed` (g + 1, owner, lease end) |
| yes | repeatable, idempotent | no | unknown `dispatch-interrupted: no retry left` |
| yes | queryable | any | unknown `dispatch-interrupted: lookup not available` |
| yes | unqueryable | any | unknown `dispatch-interrupted: unqueryable effect` |

## 4. Canonical texts (normative)

- Recovery records: `redispatch generation=<n> owner="<o>"` (the new generation) or
  `unknown reason="<r>"`. Quoted text escapes `\` and `"` with a backslash.
- Halt reasons: `outcome-unknown operation=<uuid>` and `retries-exhausted operation=<uuid>`.
- Observations: the C-P2.5 §4 texts.

## 5. Allowed paths

New: `src/Lockstep/Kernel/Recovery.hs`, `src/Lockstep/Effects/Executor.hs`,
`src/Lockstep/Effects/Scripted.hs`, `src/Lockstep/Application/Executor.hs`.

Changed:
- `src/Lockstep/Application/Ledger.hs` and `src/Lockstep/Persistence/Ledger.hs`: additions
  only; the C-P2.5 API and behaviour are unchanged.
- `src/Lockstep/Persistence/Migrations.hs`: append 0009.
- `lockstep.cabal` / `package.yaml`: module lists.
- `test/unit/**` and `test/integration/**`: new files and runner lines.
- `docs/architecture/ARCHITECTURE.md`, `docs/OPERATOR_GUIDE.md` (migration note) and
  `docs/gates/P2.6/**`.

Frozen tests are unchanged.

## 6. Production API the tests bind to

```haskell
-- Lockstep.Kernel.Recovery
data RecoveryInput = RecoveryInput { recoveryOwner :: Text, recoveryNow :: UTCTime, recoveryLeaseUntil :: UTCTime,
  recoverySubjectActive :: Bool }
data Recovery = RecoverRedispatch Intent | RecoverUnknown Intent
recoveryIntent :: Recovery -> Intent
recoverIntent :: Intent -> Command RecoveryInput -> Either RecoveryRefusal Recovery
renderRecovery :: Recovery -> Text                      -- §4
data RecoveryRefusal = RecoveryAgentAssertion | RecoveryAlreadySettled | RecoveryNotAuthorized Principal
  | NothingToRecover Text | RecoveryLeaseActive
recoveryRefusalCode :: RecoveryRefusal -> Text          -- the X7 codes

-- Lockstep.Effects.Executor
data DestinationAnswer = AnswerApplied Text | AnswerNotApplied Text
data EffectAdapter = EffectAdapter { adapterSpec :: EffectSpec, adapterRun :: OperationId -> Text -> IO DestinationAnswer }
invokeAdapter :: Int -> EffectAdapter -> OperationId -> Text -> IO Observation   -- timeout in milliseconds

-- Lockstep.Effects.Scripted
data ScriptedDestination; newScriptedDestination :: IO ScriptedDestination
data Application = Application { appliedOperation :: OperationId, appliedParameters :: Text }
destinationApplications :: ScriptedDestination -> IO [Application]               -- oldest first
data ScriptStep = StepApply Text | StepRefuse Text | StepApplyThenHang Text | StepHang | StepApplyThenFail | StepFail
  | StepMalformed
scriptedAdapter :: EffectSpec -> ScriptedDestination -> [ScriptStep] -> IO EffectAdapter

-- Lockstep.Application.Ledger (additions)
claimForExecution :: DatabaseRuntime -> Text -> Int -> OperationId -> IO (Either LedgerFailure Intent)
beginDispatch :: DatabaseRuntime -> OperationId -> Int -> IO (Either LedgerFailure Intent)
concludeIntent :: DatabaseRuntime -> OperationId -> Int -> Observation -> IO (Either LedgerFailure Intent)
recoverDispatched :: DatabaseRuntime -> Text -> Int -> OperationId -> IO (Either LedgerFailure Intent)
runnableIntents :: DatabaseRuntime -> IO (Either LedgerFailure [OperationId])
recoverableIntents :: DatabaseRuntime -> IO (Either LedgerFailure [OperationId])
data StoredRecovery = StoredRecovery { recoveredGeneration :: Int, recoveryDecision :: Text }
intentRecoveries :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure [StoredRecovery])   -- oldest first

-- Lockstep.Application.Executor
data Executor = Executor { executorOwner :: Text, executorLeaseSeconds :: Int, executorTimeoutMs :: Int,
  executorAdapters :: [EffectAdapter] }
data ExecutorFaults = ExecutorFaults { faultAfterClaim :: IO (), faultAfterDispatch :: IO (), faultAfterEffect :: IO () }
noExecutorFaults :: ExecutorFaults
data RunOutcome = RanApplied Text | RanNotApplied Text | RanExhausted Text | RanUnknown Text
executeIntent :: DatabaseRuntime -> Executor -> ExecutorFaults -> OperationId -> IO (Either LedgerFailure RunOutcome)
recoverAndExecute :: DatabaseRuntime -> Executor -> ExecutorFaults -> OperationId -> IO (Either LedgerFailure RunOutcome)
executeOnce :: DatabaseRuntime -> Executor -> ExecutorFaults -> IO (Either LedgerFailure (Maybe (OperationId, RunOutcome)))
```

`RunOutcome`: `RanApplied r` is settled-applied with result `r`; `RanNotApplied r` is
`confirmed-not-applied` with a retry left; `RanExhausted r` is settled-not-applied with the order
halted; `RanUnknown r` is `outcome-unknown` with the order halted (or already not active).

## 7. Tests (frozen before implementation)

Unit (`lockstep-unit`):

| Area | Cases |
|---|---|
| Recovery fixtures | the fixture builds a dispatched intent of every class through the real C-P2.5 `stepIntent`, and an intent in every other state |
| Recovery checks | `Agent` → `agent-assertion`; settled and abandoned → `already-settled`; Human and Scheduler → `not-authorized`; pending, claimed, confirmed-applied, confirmed-not-applied and unknown → `nothing-to-recover`; `now` one second before the lease end → `lease-active`; `now` equal to it recovers |
| Recovery table | every row of §3 for every class, budgets 0 and 1, and dispatch counts 1 and 2; a redispatch keeps the operation id, key, spec, parameters, digest and dispatch count, raises the generation by one, and takes the new owner and lease end; then a C-P2.5 `dispatch` with the new generation is accepted and the old one is `stale-claim` |
| Recovery texts | `renderRecovery` for a redispatch (with a quote and a backslash in the owner) and for each unknown reason; every refusal code |
| Invocation | applied and not applied with valid texts; empty, control-character and 4097-character texts → `malformed-answer`; a 50 ms timeout over a hanging adapter → `timeout` within 5 s; a throwing adapter → `adapter-failed`; an outer timeout over `invokeAdapter` with a long inner timeout still cancels it (an asynchronous exception is not turned into an observation) |
| Scripted | steps are consumed in order and then `StepApply "ok"`; applications recorded oldest first; refuse, hang and fail record nothing; apply-then-hang, apply-then-fail and malformed record the application; malformed → `malformed-answer`; idempotent: a repeat with the same parameters answers the first result and records nothing, also after an application whose answer was lost; with different parameters → `changed-parameters`; repeatable: every apply records |
| Adapter fixture | a hand-built adapter used by the other cases answers as written (passes before the implementation) |

Integration (`lockstep-integration`, real PostgreSQL, the C-P2.5 scenario through the real
binary, an active Work Order whose intents the test chooses):

| Case | Asserts |
|---|---|
| Scenario setup | an active order with four pending intents (repeatable budget 1, idempotent budget 1, queryable budget 1, unqueryable budget 0) through the real C-P2.5 ledger; the lease-ending SQL; a second order can be started after the first halts (passes before the implementation) |
| Each class applied | `executeIntent` → `RanApplied "ok"`; settled, generation 1, one dispatch, one accepted observation, one application each; the order stays active |
| Refusals before any write | `no-adapter`; `adapter-mismatch` (same name, another class); `invalid-record` for a lease of 0 and for a timeout not below the lease; `unknown-intent`; the intent stays pending with generation 0 and nothing is applied |
| Subject not active | after a Human halt, `executeIntent` → `subject-not-active` and the intent stays pending; a halt committed by the after-claim hook → `subject-not-active` at dispatch, the intent `claimed` with no dispatch; nothing is applied |
| Crash before dispatch | the after-claim hook throws: the exception propagates; `claimed`, no dispatch, nothing applied, not recoverable; another executor → `claim-held`; after the lease ends it is runnable, and executing it → `RanApplied`, generation 2, one dispatch, one application |
| Crash after dispatch, repeatable | the after-dispatch hook throws: `dispatched`, one dispatch, nothing applied; `executeIntent` → `dispatched-needs-recovery`; `recoverAndExecute` → `lease-active`; after the lease ends it is recoverable, and recovering → `RanApplied`, generation 2, two dispatches, one application, the recovery record `redispatch generation=2 owner="w2"` with generation 1 |
| Crash after the effect, repeatable | the after-effect hook throws: one application, no observation; recovery re-executes (class A permits it): two applications, settled |
| Crash after the effect, idempotent | recovery re-dispatches the same operation id; the destination deduplicates: **one** application; settled with the first result |
| Crash after the effect, queryable and unqueryable | recovery → `RanUnknown` with the X7 reason; one application each; the order halted with `outcome-unknown operation=<uuid>`; afterwards `executeIntent` → `outcome-unknown` (the intent's own refusal comes before the order check), `recoverAndExecute` → `nothing-to-recover`, `executeOnce` → nothing; still one application |
| Unqueryable crash after dispatch | recovery → unknown `dispatch-interrupted: unqueryable effect`, **never executed** (no application), the order halted |
| Ambiguous answers | a hang → `RanUnknown "timeout"`, nothing applied, the order halted, its other intents no longer runnable; apply-then-hang → unknown `timeout`, one application; a failure → `adapter-failed`, nothing applied; a malformed answer → `malformed-answer`, one application; each a stored, accepted no-answer observation (one order per answer, each halted) |
| Not applied, budgets | repeatable budget 1: refused → `RanNotApplied "busy"`, runnable, then applied at generation 2 with two dispatches and one application; unqueryable budget 0: refused → `RanExhausted "busy"`, settled not applied, the order halted with `retries-exhausted operation=<uuid>` |
| Duplicate claim | a second executor run from inside the first's after-claim hook → `claim-held`; the first → `RanApplied`; one application; a later run → `already-settled`, still one application |
| Delayed worker | inside w1's after-dispatch hook the lease is ended and `recoverDispatched` gives generation 2 to w2; w1 then runs its effect (one application) and its conclusion → `stale-claim`; the observation is stored at generation 1 with `accepted = false`, refusal `stale-claim`; the intent is `claimed` at generation 2 with one dispatch |
| Abandoned mid-flight | a Human abandon inside the after-effect hook; the conclusion → `already-settled` and the applied observation is stored with `accepted = false`, refusal `already-settled` |
| Restart pass | with the repeatable intent crashed after dispatch (lease ended) and the others pending, a new executor with the repeatable and idempotent adapters: `executeOnce` recovers the first, then executes the idempotent one, then returns nothing (no adapter for the other two, which stay pending) |
| Recovery records immutable | UPDATE, DELETE and TRUNCATE on `lockstep_effect_recoveries` fail with the trigger's message |
| No effect without a marker | in every case above, each application belongs to an intent with at least one committed dispatch |

## 8. Verification

Before the freeze:
- The tests compile against type-only stubs; format and lint are clean.
- The unit and integration baselines fail only in the new groups, and every earlier test passes.
- The setup is exercised on its own (R-P2.3-1 lesson): the unit recovery fixtures, the adapter
  fixture, and the integration scenario setup pass against the stubs.
- **Static rules** (R-P2.5-1 lesson): every new Kernel identifier, string and comment, and every
  new source, test and script line, is checked against the purity scan (`\bIO\b|unsafe` in
  `src/Lockstep/Kernel`), the forbidden-facility pattern, the provider-CLI names and the
  partial-function bans. The result is recorded in §10.

Acceptance:
- `scripts/check --integration` on the clean tree, and a Linux clone.
- Frozen digests P1.1–P2.6 unchanged.
- `check-kernel-boundary` covers `Recovery`.
- Licenses unchanged.

## 9. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a rule that contradicts DG-04
or a source document. Rollback: revert the P2.6 commits. Migration 0009 only adds a table; to
undo it, restore the pre-migration backup (ADR-0002).

## 10. Freeze record

Frozen 2026-10-19 by the writing agent (manual). Frozen files never change in P2.6 without the
protected-test amendment protocol.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/RecoveryTest.hs` | `ec69b944c7101ba6bfcf96d49f265150f3cb7fca7fb7c738d7ba77b4c7fe7ef6` |
| `test/unit/Lockstep/Effects/ExecutorTest.hs` | `d55956087ddd7ddb9212d6ed8f2d52c229d75e536a14940e489be83e8677f164` |
| `test/integration/Lockstep/ExecutorTest.hs` | `b4c14a1edb3b1bd62bafa6e777ae88036fe4ed1dc4834b23a045c919160488c9` |
| `test/unit/Main.hs` (runner, additive) | `f59d3b0ad18f4d8bdcec19e679e172a6e5cb130aa32766b4683179dc02a05ff7` |
| `test/integration/Main.hs` (runner, additive) | `51466782985475379d861d58cd210bd118a90af264de11fe48c774a603d73906` |

Runner changes: `test/unit/Main.hs` +4 lines, `test/integration/Main.hs` +2 lines; nothing removed.
The C-P2.5 support module `Lockstep.Support.Ledger` is reused unchanged.

Pre-freeze verification (§8), against type-only stubs (scratch, not committed): the §6 types,
refusing bodies; `scriptedAdapter` returns an adapter that always answers not applied; no
migration 0009.

- Build: library and both suites compile under `--pedantic`; fourmolu clean; hlint clean after
  one hint (an eta reduction).
- Unit baseline (`evidence/prefreeze-unit-baseline.log`): 25 of 550 fail, **all** in the two new
  groups; the 522 earlier tests pass. Passing against the stubs: the recovery fixtures (built
  through the real C-P2.5 lifecycle), the hand-built adapter fixture, and "the order's activity
  is checked after the lease", which a `lease-active` stub satisfies and which is paired with
  the failing table cases.
- Integration baseline (`evidence/prefreeze-integration-baseline.log`): 16 of 110 fail, every
  one at the first stub call; the 93 earlier tests pass. The **scenario setup case passes**. It
  runs the binary setup, `activeOrder` twice (the second after a Human halt), the lease-ending
  SQL against the real C-P2.5 claim, the halt-event query (`lastEvent`), `allAdapters`,
  `markerHolds`, `applications` and the trigger check. That covers every helper the other cases
  use except `haltedFor`, which is `showWorkOrder` plus `lastEvent`.
- Static rules (R-P2.5-1 lesson; the owner's carried-forward instruction): every new Kernel
  identifier, string and comment in `Lockstep.Kernel.Recovery` and in the §3/§4 texts was checked
  against the purity scan. `check-kernel-boundary` over the stubs: clean, 14 files. Every new
  source, test and Contract line was checked against the forbidden-facility pattern and the
  provider-CLI names (none), and the lint step passed: no partial function, all paths
  case-exact. The reason texts (`dispatch-interrupted: …`, `unqueryable effect`) contain neither
  `IO` as a word nor `unsafe`.
- The stubs cannot produce executor behaviour, so every expected state, generation, dispatch
  count, application count, text and code was checked against X1–X12 and §3–§4 by reading before
  the freeze. Two draft expectations were corrected in that reading: a stale conclusion on a
  settled intent is `already-settled` (C-P2.5 checks terminal states first), so the delayed-worker
  case fences w1 with a recovery and no settlement; and the claim and dispatch refusals of the
  intent itself come before the order check.
