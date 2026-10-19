# P2.7 Contract — Reconciliation and fencing

- Contract ID: `C-P2.7@v1`
- Status: **FROZEN** (2026-10-19)
- Basis: `v2` at `837fa40` (P2.6 `VERIFIED — awaiting human acceptance`); C-P2.5 (intent
  lifecycle, fencing) and C-P2.6 (executor, recovery), unchanged except where §2 R9 says.
- Authority: `.local/plans/phase-02.md` §11 (P2.7); **DG-04 ACCEPTED with safety clarifications**
  (`docs/gates/P2.5/dg-04-decision-request.md`): D-4.2, D-4.5 (class C row), D-4.6 and binding
  requirements 3, 4, 5, 6 and 8.
- Traces: PRD §6.2 (reconcile from the authoritative destination; `RECOVERY_REQUIRED` and a
  human when unprovable; an old worker's late observation is rejected), FR-EXE-07 (a duplicate
  answer cannot relaunch), Bible §38.
- Writer: the single writing agent (manual).

## 1. Objective

When an effect's outcome is uncertain, resolve it only from evidence that can prove it:
- a lookup at the destination, for a queryable effect, under the destination's declared terms;
- otherwise, an explicit, recorded human decision.

Fencing never cancels external work, so evidence that a fenced worker completed an effect is
always kept. When that evidence contradicts the durable state, it halts the work. Real
separate processes contending for the same intents must never produce an unintended duplicate
application.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| R1 | **Lookups** (`Lockstep.Effects.Reconciler`). An `EffectReconciler` declares the exact spec it serves and a lookup from (operation id, parameters) to `LookupApplied result` or `LookupAbsent`, as the destination reports. `invokeLookup timeoutMs` runs it once: applied with a valid text (1–4096 characters, no control characters) → `LookupFound`; absent → `LookupNotFound`; an invalid text → `LookupFailed "malformed-answer"`; no answer in time → `LookupFailed "timeout"`; a synchronous exception → `LookupFailed "lookup-failed"`; asynchronous exceptions propagate. |
| R2 | **Scripted lookups** (`Lockstep.Effects.Scripted`, additions). `scriptedReconciler spec destination steps`: `LookupTruthful` answers from the destination's record (the operation's recorded result if it was applied, else absent); `LookupHang` hangs for an hour; `LookupFail` throws. After the script, every call is truthful. Results recorded for apply-then-fail and malformed steps are `applied`. |
| R3 | **Reconciliation** (`Lockstep.Kernel.Reconciliation`, pure; D-4.5 class C, requirement 3). Check order: `Agent` → `agent-assertion`; settled or abandoned → `already-settled`; not `Supervisor` → `not-authorized`; not `queryable` → `not-queryable`; then the state: `outcome-unknown` is reconcilable; `dispatched` is reconcilable when `now ≥` its lease end (`lease-active` otherwise); any other state → `nothing-to-reconcile`. An accepted reconciliation raises the generation by one, which fences out every earlier worker, and sets: found `r` → `confirmed-applied r`; not found, with terms authoritative **and** excluding a late application → `confirmed-not-applied "lookup: not found"`; not found, authoritative but not excluding it → unknown `lookup: not found, late application not excluded`; not found, not authoritative → unknown `lookup: not found, not authoritative`; failed `r` → unknown `lookup failed: r`. The dispatch count is unchanged. |
| R4 | **Reconciliation, durable** (`Application.Reconciler`). The executor reads the intent and runs the Kernel's checks without writing anything (`prepareLookup`, which returns the generation). It then performs the lookup outside any transaction, and applies the result in one transaction (`applyLookup`), which locks the Work Order and then the intent. The generation must still be the one the lookup was made against (`stale-claim` otherwise; nothing written). It writes the intent and one resolution record (basis `lookup`; that generation; the §4 text). Then, as C-P2.6 X6 does: found → settled (applied); not found and not applied with `dispatches > budget` → settled (not applied) and the order halts with `retries-exhausted operation=<uuid>`; unknown → the order halts with `outcome-unknown operation=<uuid>` when its lifecycle accepts a halt. A not-applied intent with a retry left stays claimable under C-P2.5 E7: a halted order must be requeued by a Human first. Configuration: a timeout of 1–600000 ms and at most one reconciler per spec name (`invalid-record`); no reconciler with the intent's spec name → `no-reconciler`; one whose spec differs → `reconciler-mismatch`. `reconcileOnce` reconciles the oldest reconcilable intent (`reconcilableIntents`: queryable, and `outcome-unknown` or `dispatched` with an ended lease) that it has a reconciler for, and returns nothing if there is none. |
| R5 | **Human resolution** (Kernel `resolveIntent`; Ledger `resolveOutcome`, always `Human`; D-4.6, requirements 5 and 6). It is bound to the exact intent and generation. Check order: `Agent` → `agent-assertion`; settled or abandoned → `already-settled`; not `Human` → `not-authorized`; another generation → `stale-claim`; not `outcome-unknown` → `not-unknown`. Then the choice: **attest applied** `e` → settled (applied) with result `human-attested: e`; **attest not applied** `e` → `confirmed-not-applied "human-attested: e"` when `dispatches ≤ budget`, else settled (not applied) with that text; **retry**: only with the duplication risk acknowledged (`duplication-risk-not-acknowledged` otherwise) → `pending`, with the same operation id, parameters, generation and dispatch count. A pending intent may be claimed whatever its budget, so a human retry is the only way past a budget, and each one takes its own explicit decision. Evidence text: 1–4096 characters, no control characters (`invalid-evidence`). Abandoning stays C-P2.5 `abandonIntent`. A second answer finds the intent no longer unknown (`not-unknown` or `already-settled`), so it can never relaunch the effect (FR-EXE-07). |
| R6 | **Attested is not observed** (requirement 6). A human resolution writes a resolution record (basis `human-attested`, or `human-retry` with the acknowledgement stored as `true`). It **never** writes an observation: observations are only what a destination reported. A settled result attested by a human always begins `human-attested: `. |
| R7 | **Late observations** (requirement 4; Kernel `judgeLateObservation`). An observation refused by the C-P2.6 conclusion is stored as before. A refused **applied** observation **conflicts** with the durable state: (a) for a queryable or unqueryable effect, in any state except `confirmed-applied` and settled (applied); (b) for a repeatable or idempotent effect, in `confirmed-not-applied`, settled (not applied) or `abandoned`. A conflict writes one resolution record (basis `late-observation`, the observation's generation, `late-application <observation text>`). It halts the order with `late-application operation=<uuid>` when its lifecycle accepts a halt. An intent that could still run (`pending`, `claimed`, `dispatched`, `confirmed-not-applied`) becomes unknown `late-application`, so it cannot be dispatched again until a human resolves it. Other refused observations, and applied ones that do not conflict, change nothing beyond being stored. |
| R8 | **Cross-process contention** (requirement 8). Real separate OS processes, each with its own connection pool, run the C-P2.6 executor against one real PostgreSQL database and one external destination. The destination is a pair of PostgreSQL tables owned by the test, written over separate connections. Its idempotent key is a primary key, so it is real and shared across processes. The worker processes are the integration test binary itself, started with a tasty pattern that selects a "contention worker role" case and an environment naming the role; outside such a child, that case does nothing. The shipped binary gains no command and no fault plan (the C-P1.7 guard is unchanged). |
| R9 | **Changes to C-P2.6:** the conclusion (X6) also applies R7. Nothing else changes, and the frozen C-P2.6 tests still hold. |
| R10 | **Migration 0010** (forward-only, adds one table): `lockstep_effect_resolutions` (`id`, `operation_id` → intents, `generation`, `basis` ∈ `lookup`, `human-attested`, `human-retry`, `late-observation`, `decision`, `duplication_acknowledged` boolean, `recorded_at`), refusing UPDATE, DELETE and TRUNCATE through `lockstep_refuse_change()`. |
| R11 | **No new commands.** Library functions only; operator commands and views are C-P2.8. |

## 3. Tables (normative)

Reconciliation (after the R3 checks; `g` the generation; the result has `g + 1`):

| Lookup | Terms: authoritative, excludes late | Result |
|---|---|---|
| found `r` | any | `confirmed-applied r` |
| not found | yes, yes | `confirmed-not-applied "lookup: not found"` |
| not found | yes, no | unknown `lookup: not found, late application not excluded` |
| not found | no, any | unknown `lookup: not found, not authoritative` |
| failed `r` | any | unknown `lookup failed: r` |

Late applied observation (R7):

| State at the conclusion | repeatable, idempotent | queryable, unqueryable |
|---|---|---|
| `pending`, `claimed`, `dispatched` | consistent | conflict; the intent becomes unknown `late-application` |
| `confirmed-not-applied` | conflict; unknown `late-application` | conflict; unknown `late-application` |
| `outcome-unknown` | consistent | conflict; the intent stays unknown |
| `confirmed-applied`, settled (applied) | consistent | consistent |
| settled (not applied), `abandoned` | conflict; unchanged | conflict; unchanged |

## 4. Canonical texts (normative)

Quoted text escapes `\` and `"` with a backslash.

- Lookup records: `found result="<r>"`, `not-found`, `failed reason="<r>"`.
- Human records: `attested-applied evidence="<e>"`, `attested-not-applied evidence="<e>"`,
  `retry duplication-acknowledged`.
- Late-observation records: `late-application ` followed by the C-P2.5 observation text.
- Halt reason: `late-application operation=<uuid>`. The C-P2.6 halt reasons also apply.

## 5. Allowed paths

New: `src/Lockstep/Kernel/Reconciliation.hs`, `src/Lockstep/Effects/Reconciler.hs`,
`src/Lockstep/Application/Reconciler.hs`.

Changed:
- `src/Lockstep/Effects/Scripted.hs`, `src/Lockstep/Application/Ledger.hs` and
  `src/Lockstep/Persistence/Ledger.hs`: additions, plus the R9 change.
- `src/Lockstep/Persistence/Migrations.hs`: append 0010.
- Module lists.
- `test/unit/**` and `test/integration/**`: new files and runner lines.
- `docs/architecture/ARCHITECTURE.md`, `docs/OPERATOR_GUIDE.md` and `docs/gates/P2.7/**`.

Frozen tests are unchanged.

## 6. Production API the tests bind to

```haskell
-- Lockstep.Kernel.Reconciliation
data LookupResult = LookupFound Text | LookupNotFound | LookupFailed Text
data ReconcileInput = ReconcileInput { reconcileNow :: UTCTime, reconcileLookup :: LookupResult }
reconcileIntent :: Intent -> Command ReconcileInput -> Either ReconcileRefusal Intent
data Resolution = AttestApplied Text | AttestNotApplied Text | RetryAcknowledgingDuplication Bool
resolveIntent :: Intent -> Command (Int, Resolution) -> Either ReconcileRefusal Intent   -- (generation, choice)
data LateVerdict = LateConsistent | LateConflict Intent
judgeLateObservation :: Intent -> Observation -> LateVerdict
renderLookup :: LookupResult -> Text; renderResolution :: Resolution -> Text            -- §4
data ReconcileRefusal = ReconcileAgentAssertion | ReconcileAlreadySettled | ReconcileNotAuthorized Principal
  | NotQueryable | NothingToReconcile Text | ReconcileLeaseActive | ReconcileStaleClaim | NotUnknown Text
  | InvalidEvidence | DuplicationNotAcknowledged
reconcileRefusalCode :: ReconcileRefusal -> Text

-- Lockstep.Effects.Reconciler
data LookupAnswer = LookupApplied Text | LookupAbsent
data EffectReconciler = EffectReconciler { reconcilerSpec :: EffectSpec, reconcilerLookup :: OperationId -> Text -> IO LookupAnswer }
invokeLookup :: Int -> EffectReconciler -> OperationId -> Text -> IO LookupResult

-- Lockstep.Effects.Scripted (additions)
data LookupStep = LookupTruthful | LookupHang | LookupFail
scriptedReconciler :: EffectSpec -> ScriptedDestination -> [LookupStep] -> IO EffectReconciler

-- Lockstep.Application.Ledger (additions)
prepareLookup :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure Int)
applyLookup :: DatabaseRuntime -> OperationId -> Int -> LookupResult -> IO (Either LedgerFailure Intent)
resolveOutcome :: DatabaseRuntime -> OperationId -> Int -> Resolution -> IO (Either LedgerFailure Intent)
reconcilableIntents :: DatabaseRuntime -> IO (Either LedgerFailure [OperationId])
data StoredResolution = StoredResolution { resolvedGeneration :: Int, resolutionBasis :: Text, resolutionDecision :: Text,
  resolutionAcknowledged :: Bool }
intentResolutions :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure [StoredResolution])   -- oldest first

-- Lockstep.Application.Reconciler
data Reconciliation = Reconciliation { reconciliationTimeoutMs :: Int, reconciliationReconcilers :: [EffectReconciler] }
data ReconcileOutcome = ReconciledApplied Text | ReconciledNotApplied Text | ReconciledExhausted Text | StillUnknown Text
reconcileEffect :: DatabaseRuntime -> Reconciliation -> OperationId -> IO (Either LedgerFailure ReconcileOutcome)
reconcileOnce :: DatabaseRuntime -> Reconciliation -> IO (Either LedgerFailure (Maybe (OperationId, ReconcileOutcome)))
```

## 7. Tests (frozen before implementation)

Unit (`lockstep-unit`):

| Area | Cases |
|---|---|
| Fixtures | queryable intents that are unknown and dispatched, and intents of every other class and state, built through the real C-P2.5 `stepIntent` (passes before the implementation) |
| Reconcile checks | `Agent`, terminal, Human and Scheduler, each other class (`not-queryable`), each non-reconcilable state, the lease boundary (one second before is `lease-active`, equal reconciles) |
| Reconcile table | every §3 row for an unknown and a dispatched intent; generation + 1; operation id, parameters and dispatch count kept; after it, a C-P2.5 observation of the old generation is `stale-claim` |
| Resolve | the check order; attest applied; attest not applied with a retry left and without one; retry unacknowledged (refused) and acknowledged (`pending`, generation and dispatch count kept, then claimable by C-P2.5 although the budget is spent); invalid evidence (empty, control character, 4097 characters) |
| Late table | every cell of the §3 late table for the four classes, and a not-applied and a no-answer observation, which never conflict |
| Texts and codes | every §4 text (with a quote and a backslash), every refusal code |
| Lookup invocation | found, absent, malformed, timeout within 5 s, failure, an outer cancellation not turned into a result |
| Scripted lookups | truthful before and after an application (with the recorded result), for apply-then-hang and malformed steps (`applied`); hang and fail; truthful after the script |

Integration (`lockstep-integration`, real PostgreSQL, the C-P2.5 scenario through the real
binary; an active order with six intents: `alpha` repeatable 1, `bravo` idempotent 1, `charlie`
queryable (authoritative, excludes late) 1, `delta` unqueryable 0, `echo` queryable
(authoritative, not excluding late) 1, `foxtrot` queryable (not authoritative) 1):

| Case | Asserts |
|---|---|
| Scenario setup | six pending intents; the destination tables, their adapter (an application, an idempotent repeat) and lookup; a child worker process in the `probe` role connects, reads an intent and reports; the lease SQL; requeue and restart of a halted order; the polling helper (passes before the implementation) |
| Lookup found | `charlie` apply-then-hang → unknown; reconciliation → `ReconciledApplied`, settled with the recorded result, generation 2; one `lookup` record `found result=…` at generation 1; observations unchanged; the order stays halted |
| Authoritative not found, then retried | `charlie` hang → unknown; reconciliation → `ReconciledNotApplied "lookup: not found"` (generation 2); after a Human requeue and a restart, `executeIntent` applies it under generation 3 with the same operation id: one application, two dispatches |
| Non-authoritative not found | `echo` and `foxtrot` (one order each) → `StillUnknown` with the two §3 reasons; `executeIntent` → `outcome-unknown`; nothing applied |
| Lookup failures | a hanging lookup → `StillUnknown "lookup failed: timeout"`, then a failing one → `lookup failed: lookup-failed`; generations 2 and 3; two records |
| Dispatched, reconciled directly | `charlie` crashes after its effect; after the lease ends it is reconcilable, and reconciliation → `ReconciledApplied`; no recovery record; the order stays active |
| Refusals | `not-queryable`, `nothing-to-reconcile`, `lease-active`, `no-reconciler`, `reconciler-mismatch`, `invalid-record`; nothing written |
| Human: attest applied | `delta` apply-then-hang → unknown; `resolveOutcome` with generation 0 → `stale-claim`; with generation 1 → settled `human-attested: …`; one `human-attested` record; observations are only the destination's; a second answer → `already-settled` |
| Human: attest not applied | `bravo` (a retry left) → `confirmed-not-applied "human-attested: …"`; `delta` on another order (no retry left) → settled not applied |
| Human: retry | `delta` hang → unknown; retry unacknowledged → `duplication-risk-not-acknowledged`; acknowledged → `pending`, a `human-retry` record with the acknowledgement; a second answer → `not-unknown`; after a requeue and a restart, `executeIntent` applies it under generation 2 with the same operation id |
| Late application | inside w1's after-dispatch hook, `charlie` is reconciled not found (authoritative, generation 2); w1 then applies and its conclusion → `stale-claim`; the intent becomes unknown `late-application`, the order halts with `late-application operation=…`, and the records are the lookup then the late observation; `executeIntent` → `outcome-unknown`; one application |
| Abandoned, then applied | the C-P2.6 abandoned-mid-flight scenario is now a conflict: the order halts with `late-application operation=…`, with one late-observation record |
| Records immutable | UPDATE, DELETE and TRUNCATE on `lockstep_effect_resolutions` fail with the trigger's message |
| Two processes drain one order | two worker processes run `executeOnce` until nothing is left, over adapters that each take 300 ms: every intent is applied exactly once and settled |
| Two processes recover one idempotent intent | `bravo` crashed after dispatch; two worker processes recover it at once: exactly one applies, the other is refused; one application |
| Two processes recover one unqueryable intent | `delta` crashed after its effect; two worker processes recover it at once: one finds it unknown, the other `nothing-to-recover`; still one application |
| A stalled process completes late | a worker process stalls after its dispatch until it is fenced; meanwhile the test ends its lease and reconciles `echo` (not found, late application not excluded → unknown, generation 2); the worker then applies and its conclusion → `stale-claim`; a late-observation conflict is recorded; one application; the intent stays unknown |

## 8. Verification

Before the freeze:
- The tests compile against type-only stubs; format and lint are clean.
- The baselines fail only in the new groups, and every earlier test passes.
- The setup is exercised on its own (R-P2.3-1): the unit fixtures, and the integration scenario
  setup with a real child process, pass against the stubs.
- Static rules (R-P2.5-1): every new Kernel identifier, string and comment is checked against
  the purity scan, and every new line against the forbidden-facility pattern, the provider-CLI
  names and the partial-function bans. The result is recorded in §10.

Acceptance:
- `scripts/check --integration` on the clean tree, and a Linux clone.
- Frozen digests P1.1–P2.7 unchanged; the C-P2.6 tests still pass (R9).
- `check-kernel-boundary` covers `Reconciliation`.
- Licenses unchanged.

## 9. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a rule that contradicts DG-04
or a source document, or if real cross-process contention shows a duplicate application.
Rollback: revert the P2.7 commits. Migration 0010 only adds a table (restore the pre-migration
backup to undo it, ADR-0002).

## 10. Freeze record

Frozen 2026-10-19 by the writing agent (manual). Frozen files never change in P2.7 without the
protected-test amendment protocol.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/ReconciliationTest.hs` | `2f121ec68dccd9c69488dfe8d34e94740ff4ddb206ae0cc92a7f43fe006100c6` |
| `test/unit/Lockstep/Effects/ReconcilerTest.hs` | `ac383fb7f2a871227b3e5ade270c0b5f7365658444e3756f6517063eb7e30c87` |
| `test/integration/Lockstep/ReconciliationTest.hs` | `51e5edef534d007f26c1fd68af12d7703aacba6845b1ac72cf53587b2486aac1` |
| `test/unit/Main.hs` (runner, additive) | `8586c722742f72d1960f35ee5376cb8159f62556164adac9644f5b1eb034349a` |
| `test/integration/Main.hs` (runner, additive) | `7308e781d73fa0c11528f6322a015e26866785420e103cc5d71bb4062f783f0c` |

Runner changes: `test/unit/Main.hs` +4 lines, `test/integration/Main.hs` +2 lines; nothing removed.

Pre-freeze verification (§8), against type-only stubs (scratch, not committed): the §6 types,
with refusing bodies. `judgeLateObservation` always answers consistent, and `scriptedReconciler`
always answers absent. No migration 0010.

- Build: library and both suites compile under `--pedantic`. Fourmolu is clean. hlint is clean
  after three hints: two eta reductions and one `traverse_`.
- Unit baseline (`evidence/prefreeze-unit-baseline.log`): 27 of 579 fail, **all** in the two new
  groups, and the 550 earlier tests pass. Two new cases pass against the stubs:
  - the fixture, every state of every class built through the real C-P2.5 lifecycle;
  - "a late not-applied or no-answer observation never conflicts", which a consistent-only stub
    satisfies; it is paired with the two failing late-table cases.
- Integration baseline (`evidence/prefreeze-integration-baseline.log`): 13 of 128 fail, and the
  110 earlier tests pass. Every failure is at the first stub call, except "abandoned, then
  applied", which passes its C-P2.6 part and fails only at the R9 halt that is not yet
  implemented. These new cases pass against the stubs:
  - The **scenario setup** passes. It runs the destination tables and their adapter, the
    idempotent repeat, the lookup, a real **child worker process** (`probe`), the lease SQL, a
    Human halt with requeue and restart, the last-event query and the polling helper.
  - The worker-role case passes; in the suite itself it does nothing.
  - **The three cross-process contention cases pass**: two processes draining one order, and
    two recovering an idempotent and an unqueryable intent. They exercise only the C-P2.6
    executor and recovery, which already exist, under real contention, so they pass before any
    P2.7 code. That is the requirement-8 evidence that the C-P2.6 protocol holds across
    processes. They are frozen as regression tests.
  - The stalled-process case got its child to the dispatch against the stubs before failing at
    the stub reconciliation, so the stall handshake (spawn, dispatch, polling) is exercised.
- Static rules (R-P2.5-1): every new identifier, string and comment in
  `Lockstep.Kernel.Reconciliation` and in the §3 and §4 texts was checked against the purity
  scan: `check-kernel-boundary` is clean over 15 files. Every new source, test and Contract line
  was checked against the forbidden-facility pattern and the provider-CLI names (none). The lint
  step passed: no partial function, all paths case-exact.
- The stubs cannot produce reconciliation behaviour, so every expected state, generation,
  record, text and code was checked against R1–R10 and §3–§4 by reading before the freeze.
