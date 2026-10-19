# P2.5 Contract — Durable events, claims, effect intents and outbox

- Contract ID: `C-P2.5@v1`
- Status: **FROZEN** (2026-10-19)
- Basis: `v2` at `0c58280` (P2.4 `VERIFIED — awaiting human acceptance`); the C-P2.2 lifecycles; the
  C-P2.3 bindings; the C-P2.4 scheduler; the P1.5 no-op dispatcher (unchanged).
- Authority: `.local/plans/phase-02.md` §9 (P2.5) and §3; **DG-04 ACCEPTED with safety
  clarifications** (`docs/gates/P2.5/dg-04-decision-request.md`, Human decision, 2026-10-18):
  D-4.1–D-4.4, D-4.7–D-4.9 and binding requirements 1, 2, 3 (as declarations), 4, 7. The crash
  table (D-4.5) and restart recovery are C-P2.6; class-specific reconciliation, late-observation
  handling after reconciliation, human resolution (D-4.6, requirements 5 and 6) and cross-process
  contention are C-P2.7.
- Traces: FR-EXE-02 (durable intents before effects), PRD §6.2 (atomic state and intents; effects
  outside the transaction), PRD §4.1 (unknown outcome is its own category), Bible §38.
- Writer: the single writing agent (manual).

## 1. Objective

Make Tickets and Work Orders durable, and connect an authorized pure decision to its durable
consequences in **one PostgreSQL transaction**: the expected-revision check, the appended domain
event, the state projection and any effect intents. Give each intent a stable identity, a declared
effect class, a fenced claim and a durable outcome vocabulary, so a later dispatcher (C-P2.6) can
never execute an effect that was not durably authorized and claimed. Nothing in P2.5 executes an
effect: there is no dispatcher and no adapter yet.

The Phase 1 no-op job dispatcher, its tables and its lease rule are unchanged (D-4.8).

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| E1 | **Effect classes** (D-4.3) in `Lockstep.Kernel.Effect`: `repeatable` (A), `idempotent` (B), `queryable` (C), `unqueryable` (D). An effect spec has a name (`^[a-z][a-z0-9-]{0,63}$`), class terms and a retry budget. Requirement 2: class B terms are the destination's documented key lifetime in seconds (≥ 1) and whether the destination refuses a repeated key with different parameters; a spec whose destination does not refuse that is `idempotency-undocumented`. Requirement 3 (declaration only here): class C terms say whether a negative lookup is authoritative and whether it excludes a later application by an earlier in-flight attempt; C-P2.7 uses them. Requirement 7: the budget is 0–3 for A–C and must be 0 for D (`retry-budget-forbidden`); any other value is `invalid-effect-spec`. |
| E2 | **Stable intent identity** (requirement 1). An intent is created only by a decision. Its key is (subject, basis revision, effect key); the effect key (same pattern as names) is the decision's stable name for that effect, so distinct effects at one revision stay distinct and a repeated decision cannot create a second intent. Two requests with one key in a decision are `duplicate-effect-key`. The operation id is a UUID issued at the boundary. Parameters are text (1–4096 characters, no control characters; `invalid-effect-parameters`) and their SHA-256 digest is stored. No operation changes an intent's operation id, spec or parameters; every retry uses them unchanged. |
| E3 | **Intent lifecycle** (D-4.4), table in §3. States `pending`, `claimed`, `dispatched`, `confirmed-applied`, `confirmed-not-applied`, `outcome-unknown`, `settled`, `abandoned`. Inputs `claim` (owner, now, lease end), `dispatch` (generation, now), `observe` (generation, observation), `settle` (generation), `abandon` (reason). Check order: `Agent` → `agent-assertion`; `settled`/`abandoned` → `already-settled`; principal not permitted → `not-authorized` (claim, dispatch, observe and settle: `Supervisor`; abandon: `Human`); a generation-bearing input whose generation is not the intent's current one → `stale-claim`; then the cell. |
| E4 | **Fencing** (D-4.2, requirement 4). A claim raises the generation by one and records the owner and the lease end. Every later write carries the generation it claimed with; an older one is `stale-claim`. A lease end gates only a *new* claim and the dispatch marker (`lease-expired` when `now` ≥ the lease end: nothing may be dispatched on an expired lease). It never invalidates an observation from the current generation: an expired lease proves nothing about the effect. Fencing cancels nothing outside the database: a stale observation is refused for the state **and stored** as evidence (`accepted = false`, refusal `stale-claim`), never dropped. |
| E5 | **Dispatch marker.** `dispatch` commits `dispatched` (and counts one dispatch) **before** any effect may be attempted (C-P2.6 attempts the effect only after this commit). A `dispatched` intent cannot be claimed (`dispatched-needs-recovery`): what may follow depends on its class (C-P2.6/C-P2.7). |
| E6 | **Observations** (D-4.4). `destination-applied <result>` → `confirmed-applied`; `destination-not-applied <reason>` → `confirmed-not-applied`; `no-answer <reason>` (timeout, lost response, crash of the call) → `outcome-unknown`, never not-applied and never success. All P2.5 observations are destination-reported (`Supervisor`); human-attested outcomes are C-P2.7. |
| E7 | **Retry budget** (D-4.7). A `confirmed-not-applied` intent may be claimed again only while its dispatches ≤ its budget (`retries-exhausted` otherwise). Reclaiming a `claimed` intent whose lease ended consumes no budget (nothing was dispatched). `outcome-unknown` is never claimable (`outcome-unknown`). There is no other retry path. |
| E8 | **Settlement.** `settle` with the current generation turns `confirmed-applied` or `confirmed-not-applied` into `settled` with that outcome; `outcome-unknown` → `outcome-unknown`; a second settle → `already-settled`. `abandon` (Human) ends any unsettled intent. |
| E9 | **Durable subjects** (D-4.1). A subject (Ticket or Work Order) has a revision equal to its number of events (creation is event 1) and a projected state name. Events are append-only (trigger-refused UPDATE/DELETE/TRUNCATE): sequence, principal, canonical command, state after. The current state is **rebuilt by replaying** the events through the C-P2.2 step function; a projection that differs from the replay is an integrity failure (`LedgerIntegrity`), never used. |
| E10 | **Event codec** (`Lockstep.Kernel.EventCodec`, §4). Canonical command texts for the durable inputs. Inputs that carry another lifecycle's opaque evidence (Work Order `complete` with Work Units; Ticket `work-accepted`, `integrated`) are not durable in Phase 2 (`not-durable`): Work Units and Deliveries become durable lifecycles later. `complete` without Work Units (kinds that complete without them) is durable. |
| E11 | **One decision, one transaction.** `decideTicket` / `decideWorkOrder` lock the subject row, check the expected revision (`stale-revision`: nothing but the refusal evidence is written), replay, step, then write the event, the projection and the intents. A refused step writes only a refusal row (subject, expected revision, principal, command, code). Intents are permitted only with a Work Order `start` or `resume` by `Supervisor` (`intents-not-authorized`). A fault injected after the event or after the intents (library-only `Faults`, §6) rolls everything back: neither the event nor any intent remains, and the hook's exception propagates to the caller. Intents with any other input are refused before the step. |
| E12 | **Tickets.** `createTicket` (the operator, `Human`) with a title (1–200 characters, no control characters; `invalid-record`) → `proposed`, content revision 1. `reviseTicket` (Human, expected revision) changes the title and raises the **content revision**; it is an event (`revise`) that leaves the lifecycle state unchanged. The content revision is a Work Order's source revision (C-P2.4 `source-stale`). |
| E13 | **Work Orders.** `createWorkOrder` (the operator): the Ticket must exist (`unknown-ticket`) and be `ready` or `in-progress` (`ticket-not-ready`); the Engineer must exist (`unknown-engineer`) and own a repository (`engineer-has-no-repository`) with a default Profile (`repository-default-profile-unset`); the facts are validated as in C-P2.3 F6–F7 (`invalid-facts` and the Kernel codes); the priority is set by the human operator (C-P2.4 S2 codes); each dependency must be an existing Work Order (`unknown-dependency`). The effective Profile is resolved from the stored default and its latest specializations (C-P2.3 F5) and bound by `Human` with approver `operator` **in the same transaction** as the Work Order's creation event. No overrides or exception receipts are durable in Phase 2. The binding is stored as its sources (level, id, version, digest), facts and digests; loading a Work Order re-resolves it from the stored definitions, and a digest that differs is an integrity failure. |
| E14 | **Gate evidence.** `recordGateEvidence` (Human or Supervisor; `not-authorized` otherwise) appends one row: Work Order, artifact, digest (64 lowercase hex), verifiers, approval. The scheduler reads all rows of an order. |
| E15 | **Scheduling run.** `scheduleOnce` takes an exclusive lock, loads every Work Order (replayed), the repository owners, current defaults, the latest Profile refs, gate evidence, Ticket content revisions (no resources exist in Phase 2: an order requires none), decides with C-P2.4, applies its `mark-eligible`/`mark-ineligible` commands as events, and — if one is selected — appends `claim` with `Claim engineer (1 + the highest claim generation the order ever had)` by `Scheduler`. All in one transaction, with the decision's rendering and digest stored (append-only). A refused scheduler input is `conflicting-input` with nothing written. |
| E16 | **Work Unit admission** (plan-less, C-P2.1 I7). `admitWorkUnit` for a `claimed` or `active` Work Order (`work-order-not-active`), against current ownership (`repository-not-owned`), with an optional plan reference, records the Work Unit (id, Work Order, Ticket, repository, Engineer, plan reference). |
| E17 | **Intent operations.** `claimIntent` (owner, lease seconds 1–3600), `dispatchIntent`, `observeIntent`, `settleIntent` (generation-bearing) and `abandonIntent` (Human) each run in one transaction that locks the intent row and uses the database clock (`now()`) as the Kernel's `now`. A refusal changes nothing, except that a `stale-claim` observation is stored as evidence (E4). |
| E18 | **Migration 0008** (forward-only, adds tables only): `lockstep_subjects`, `lockstep_tickets`, `lockstep_work_orders`, `lockstep_work_order_dependencies`, `lockstep_work_order_profile_sources`, `lockstep_events`, `lockstep_decision_refusals`, `lockstep_effect_intents` (unique (subject, basis revision, effect key)), `lockstep_effect_observations`, `lockstep_gate_evidence`, `lockstep_schedule_decisions`, `lockstep_work_units`. Every table has an `id` column; every append-only table has a `recorded_at timestamptz` column (the immutability tests update it, which only the trigger can refuse: an identity `id` cannot be updated at all). Columns the tests use: `lockstep_subjects.state` (projected state name), `lockstep_events.subject_id`, `lockstep_effect_intents.operation_id` and `.lease_until`, `lockstep_work_order_profile_sources.digest`, `lockstep_schedule_decisions.rendering` and `.digest`, `lockstep_work_units.plan_ref`, `lockstep_engineers.name` (existing). Events, refusals, observations, evidence, schedule decisions and the Profile sources refuse UPDATE, DELETE and TRUNCATE through `lockstep_refuse_change()` (message `… rows are immutable`). |
| E19 | **No effects, no new commands.** P2.5 adds library functions only; the binary gains no command and no fault plan (C-P1.7 guard unchanged). Operator commands for these records are C-P2.8. |

## 3. Intent lifecycle (normative)

`g` is the intent's current generation (0 before any claim), `d` its dispatch count, `b` its
budget. Cells name the result; `—` is `illegal-intent-transition`. Principals and the checks before
the cell are E3.

| State | `claim o now t` | `dispatch g' now` | `observe g' obs` | `settle g'` | `abandon r` |
|---|---|---|---|---|---|
| `pending` | `claimed` (g+1, o, t) | — | — | — | `abandoned` |
| `claimed` (lease t) | now ≥ t: `claimed` (g+1, o, t'); else `claim-held` | now ≥ t: `lease-expired`; else `dispatched`, d+1 | — | — | `abandoned` |
| `dispatched` | `dispatched-needs-recovery` | — | per E6 | — | `abandoned` |
| `confirmed-applied` | `already-observed` | — | `already-observed` | `settled` (applied) | `abandoned` |
| `confirmed-not-applied` | d ≤ b: `claimed` (g+1); else `retries-exhausted` | — | `already-observed` | `settled` (not applied) | `abandoned` |
| `outcome-unknown` | `outcome-unknown` | — | `already-observed` | `outcome-unknown` | `abandoned` |

## 4. Canonical texts (normative)

Quoted text escapes `\` and `"` with a backslash. Principals: `human`, `supervisor`, `scheduler`,
`delivery-adapter` (an `agent` event is never written).

Work Order commands: `mark-eligible`, `mark-ineligible`, `claim engineer=<uuid> generation=<n>`,
`release …`, `start …`, `resume …` (the same two fields), `wait engineer=<uuid> generation=<n>
reason="<r>"`, `complete engineer=<uuid> generation=<n>` (no Work Units), `halt reason="<r>"`,
`requeue`, `supersede by=<uuid>`, `cancel`, and the creation event `create`.

Ticket commands: `create title="<t>"`, `revise title="<t>"`, `accept`, `start-work`,
`review-requested`, `changes-requested`, `signoff by="<s>"`, `cancel by="<s>"`,
`block reason="<r>"`, `unblock`.

Stored observations: `applied result="<r>"`, `not-applied reason="<r>"`, `no-answer reason="<r>"`.

`decodeWorkOrderEvent <$> encodeWorkOrderEvent e == Right (Just e)` and likewise for Tickets,
for every durable event; any other text decodes to `Nothing`. Every encoding is one line.

## 5. Allowed paths

`src/Lockstep/Kernel/Effect.hs`, `src/Lockstep/Kernel/EventCodec.hs`,
`src/Lockstep/Application/Ledger.hs`, `src/Lockstep/Persistence/Ledger.hs` (new),
`src/Lockstep/Persistence/Migrations.hs` (append 0008), `test/unit/**`, `test/integration/**`
(new files and runner lines), `docs/architecture/ARCHITECTURE.md`, `docs/OPERATOR_GUIDE.md`
(migration note), `docs/gates/P2.5/**`. Earlier modules otherwise unchanged; frozen tests
unchanged.

## 6. Production API the tests bind to

```haskell
-- Lockstep.Kernel.Effect
data EffectClass = Repeatable | Idempotent | Queryable | Unqueryable; effectClassName :: EffectClass -> Text
data IdempotencyTerms = IdempotencyTerms { keyLifetimeSeconds :: Integer, refusesChangedParameters :: Bool }
data LookupTerms = LookupTerms { lookupAuthoritative :: Bool, lookupExcludesLateApplication :: Bool }
data ClassTerms = TermsRepeatable | TermsIdempotent IdempotencyTerms | TermsQueryable LookupTerms | TermsUnqueryable
data EffectSpec; mkEffectSpec :: Text -> ClassTerms -> Int -> Either EffectRefusal EffectSpec
effectSpecName :: EffectSpec -> Text; effectSpecClass :: EffectSpec -> EffectClass
effectSpecTerms :: EffectSpec -> ClassTerms; effectSpecBudget :: EffectSpec -> Int
data EffectKey; mkEffectKey :: Text -> Either EffectRefusal EffectKey; effectKeyText :: EffectKey -> Text
newtype OperationId = OperationId Uuid
data SubjectRef = SubjectTicket TicketId | SubjectWorkOrder WorkOrderId
data IntentRequest = IntentRequest { requestKey :: EffectKey, requestSpec :: EffectSpec, requestParameters :: Text }
data Lease = Lease { leaseOwner :: Text, leaseGeneration :: Int, leaseUntil :: UTCTime }
data Observation = DestinationApplied Text | DestinationNotApplied Text | NoAnswer Text
data Settlement = SettledApplied Text | SettledNotApplied Text
data IntentState = IntentPending | IntentClaimed Lease | IntentDispatched Lease | IntentApplied Text
  | IntentNotApplied Text | IntentUnknown Text | IntentSettled Settlement | IntentAbandoned Text
data Intent = Intent { intentOperation :: OperationId, intentSubject :: SubjectRef, intentBasisRevision :: Int,
  intentKey :: EffectKey, intentSpec :: EffectSpec, intentParameters :: Text, intentParametersDigest :: ContentDigest,
  intentState :: IntentState, intentGeneration :: Int, intentDispatches :: Int }
newIntents :: Hasher -> SubjectRef -> Int -> [(OperationId, IntentRequest)] -> Either EffectRefusal [Intent]
data IntentInput = IntentClaim Text UTCTime UTCTime | IntentDispatch Int UTCTime | IntentObserve Int Observation
  | IntentSettle Int | IntentAbandon Text
stepIntent :: Intent -> Command IntentInput -> Either EffectRefusal Intent
intentStateName :: IntentState -> Text
data EffectRefusal = InvalidEffectSpec Text | IdempotencyUndocumented | UnsafeRetryBudget | InvalidEffectKey Text
  | InvalidEffectParameters | DuplicateEffectKey EffectKey | EffectAgentAssertion | EffectAlreadySettled
  | EffectNotAuthorized Principal | StaleClaim | IllegalIntentTransition Text Text | ClaimHeld | LeaseExpired
  | DispatchedNeedsRecovery | AlreadyObserved | OutcomeUnknownBlocks | RetriesExhausted
effectRefusalCode :: EffectRefusal -> Text

-- Lockstep.Kernel.EventCodec
principalName :: Principal -> Text; parsePrincipal :: Text -> Maybe Principal   -- "agent" never parses
data WorkOrderEvent = WorkOrderCreated | WorkOrderStep WorkOrderInput
data TicketEvent = TicketCreated Text | TicketRevised Text | TicketStep TicketInput
encodeWorkOrderEvent :: WorkOrderEvent -> Either Text Text; decodeWorkOrderEvent :: Text -> Maybe WorkOrderEvent
encodeTicketEvent :: TicketEvent -> Either Text Text; decodeTicketEvent :: Text -> Maybe TicketEvent
-- Left: the input is not durable in Phase 2 (E10)

-- Lockstep.Application.Ledger
data LedgerFailure = LedgerRefused Text Text | LedgerIntegrity Text | LedgerUnavailable Text
ledgerFailureCode :: LedgerFailure -> Text    -- the refusal code, "integrity" or "unavailable"
data Faults = Faults { faultAfterEvent :: IO (), faultAfterIntents :: IO () }; noFaults :: Faults
data Receipt = Receipt { receiptRevision :: Int, receiptState :: Text, receiptOperations :: [OperationId] }
data SubjectView = SubjectView { viewRevision :: Int, viewState :: Text, viewContentRevision :: Int }
createTicket :: DatabaseRuntime -> Text -> IO (Either LedgerFailure TicketId)
reviseTicket :: DatabaseRuntime -> TicketId -> Int -> Text -> IO (Either LedgerFailure Receipt)
decideTicket :: DatabaseRuntime -> Faults -> TicketId -> Int -> Command TicketInput -> IO (Either LedgerFailure Receipt)
showTicket :: DatabaseRuntime -> TicketId -> IO (Either LedgerFailure SubjectView)
data NewWorkOrder = NewWorkOrder { newTicket :: TicketId, newEngineer :: Text, newKind :: WorkOrderKind, newPriority :: Int,
  newDependencies :: [WorkOrderId], newClasses :: [Text], newPathClasses :: [Text], newNonBehavioural :: Maybe Text }
createWorkOrder :: DatabaseRuntime -> NewWorkOrder -> IO (Either LedgerFailure WorkOrderId)
decideWorkOrder :: DatabaseRuntime -> Faults -> WorkOrderId -> Int -> Command WorkOrderInput -> [IntentRequest]
  -> IO (Either LedgerFailure Receipt)
data WorkOrderView = WorkOrderView { woRevision :: Int, woState :: WorkOrderState, woBindingDigest :: Text }
showWorkOrder :: DatabaseRuntime -> WorkOrderId -> IO (Either LedgerFailure WorkOrderView)
recordGateEvidence :: DatabaseRuntime -> Principal -> WorkOrderId -> GateEvidence -> IO (Either LedgerFailure ())
data ScheduleReceipt = ScheduleReceipt { scheduleRendering :: Text, scheduleDigestText :: Text,
  scheduleClaimed :: Maybe (WorkOrderId, Claim) }
scheduleOnce :: DatabaseRuntime -> IO (Either LedgerFailure ScheduleReceipt)
admitWorkUnit :: DatabaseRuntime -> WorkOrderId -> Maybe Text -> IO (Either LedgerFailure WorkUnitId)
loadIntent :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure Intent)
claimIntent :: DatabaseRuntime -> Text -> Int -> OperationId -> IO (Either LedgerFailure Intent)
dispatchIntent :: DatabaseRuntime -> OperationId -> Int -> IO (Either LedgerFailure Intent)
observeIntent :: DatabaseRuntime -> OperationId -> Int -> Observation -> IO (Either LedgerFailure Intent)
settleIntent :: DatabaseRuntime -> OperationId -> Int -> IO (Either LedgerFailure Intent)
abandonIntent :: DatabaseRuntime -> OperationId -> Text -> IO (Either LedgerFailure Intent)
data StoredObservation = StoredObservation { storedGeneration :: Int, storedObservation :: Text, storedAccepted :: Bool,
  storedRefusal :: Maybe Text }
intentObservations :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure [StoredObservation])   -- oldest first
```

`LedgerRefused code message`: `code` is the Kernel refusal code (`transitionRefusalCode`,
`effectRefusalCode`, `profileRefusalCode`, `schedulerRefusalCode`) or one of E11–E16.

## 7. Tests (frozen before implementation)

Unit (`lockstep-unit`, pure):

| Area | Cases |
|---|---|
| Specs | each class accepted with budget 0–3 (D only 0); budget 4 and -1 → `invalid-effect-spec`; D with budget 1 → `retry-budget-forbidden`; B with lifetime 0 → `invalid-effect-spec`; B whose destination does not refuse changed parameters → `idempotency-undocumented`; bad names → `invalid-effect-spec` |
| Identity | `newIntents` gives `pending`, generation 0, no dispatches, the parameters' SHA-256; two keys at one revision → two intents; one key twice → `duplicate-effect-key`; empty or control-character parameters → `invalid-effect-parameters`; bad keys → `invalid-effect-key` |
| Lifecycle table | every (state, input) cell of §3 for an A spec, including the `now`/lease boundary (equal is expired); `Agent` → `agent-assertion` everywhere; wrong principals → `not-authorized`; terminal states → `already-settled`; every stale generation → `stale-claim` |
| Fencing | a reclaim after expiry raises the generation; the old owner's dispatch, observation and settle → `stale-claim`; the current owner's observation after its lease ended is accepted |
| Observations | applied, not applied and no-answer map to E6; a no-answer is never `confirmed-not-applied` |
| Budget | budget 1: not-applied → claim → dispatch → not-applied → claim refused `retries-exhausted`; budget 0 (any class) cannot be reclaimed after not-applied; unknown is never claimable |
| Codec | round-trip for every durable Work Order and Ticket input (including quotes and backslashes); `complete` with Work Units, `work-accepted` and `integrated` → `not-durable`; malformed texts → `Nothing`; principals round-trip and `agent` is refused |

Integration (`lockstep-integration`, real PostgreSQL; library calls against a migrated database,
with Engineers, repositories and Profiles set up through the real binary):

| Case | Asserts |
|---|---|
| Tickets | create → `proposed`, revision 1; accept with expected revision 1 → `ready`, revision 2; a stale expected revision → `stale-revision`, nothing changes, one refusal row; an illegal input → `illegal-transition` recorded; revise raises the content revision and keeps the state |
| Work Order creation | from a ready Ticket → `pending`, revision 1, a binding digest; the Profile sources are stored; each refusal of E13 |
| Atomicity | `start` with two intents commits the event and both intents; a fault after the event, and one after the intents, leaves neither the event nor any intent (revision unchanged); the same decision repeated → `stale-revision`, still two intents; intents with `claim` → `intents-not-authorized` |
| Replay integrity | the projection rebuilt from events equals the stored one; a projection changed by SQL → `LedgerIntegrity`; a Profile source tampered by SQL (trigger disabled by the test) → `LedgerIntegrity` |
| Scheduling | an order with satisfied evidence is claimed by `scheduleOnce` with generation 1 and the stored decision digest is the SHA-256 of the stored rendering; an order missing evidence stays pending with `prerequisite-blocked` in the rendering; after a halt and requeue the next claim has generation 2; a revised Ticket makes its order `source-stale` |
| Work Units | admission for a claimed order records a plan-less Work Unit; for a pending order → `work-order-not-active` |
| Claims and fencing | two threads claiming one intent: exactly one succeeds, the other `claim-held`; after the lease ends (set by SQL) a reclaim gives generation 2; the old generation's dispatch → `stale-claim`; its observation → `stale-claim` and is stored with `accepted = false`; the new generation dispatches, observes `no-answer` → `outcome-unknown`, a claim → `outcome-unknown`, settle → `outcome-unknown`; abandon by the operator ends it |
| Retry budget | budget 1: not-applied, reclaim, dispatch, not-applied, claim → `retries-exhausted` |
| Immutability | UPDATE and DELETE on events, refusals, observations, evidence, schedule decisions and Profile sources fail |

## 8. Verification

Pre-freeze: the tests compile against type-only stubs; format and lint clean; the unit and
integration baselines fail only in the new groups and every earlier test passes; **the test
setup is exercised on its own**: a fixture test in each new unit file, and an integration
"scenario setup" case that runs the binary setup (migrate, Engineer, repository, Profile, default)
and reads the database through the support helpers, which passes against the stubs (R-P2.3-1
lesson). Acceptance: `scripts/check --integration` on the clean tree; a Linux clone; frozen
digests P1.1–P2.5; `check-kernel-boundary` covers `Effect` and `EventCodec`; licenses unchanged.

## 9. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a rule that contradicts DG-04
or a source document. Rollback: revert the P2.5 commits; migration 0008 only adds tables (restore
the pre-migration backup to undo, ADR-0002).

## 10. Freeze record

Frozen 2026-10-19 by the writing agent (manual). Frozen files never change in P2.5 without the
protected-test amendment protocol.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/EffectTest.hs` | `da22e6abf955ae6d25ef9a92fc8e5cacba887e6bf635b058cb9d2a4a40992f28` |
| `test/unit/Lockstep/Kernel/EventCodecTest.hs` | `a037e714a215cffaf25013e0ab80804dc670d643193d3cc8e996018301c06c38` |
| `test/integration/Lockstep/LedgerTest.hs` | `45e4c3f26abe7d6316d3cbd884c6ee11574cc462a340443b132fe2cef1b20654` |
| `test/integration/Lockstep/Support/Ledger.hs` | `1f0ecbe4e236b2bd180f952bd619f251259986707a0fb17572ed458aa40cd243` |
| `test/unit/Main.hs` (runner, additive) | `cd145cfddcaa5d341c9333042da5ea6d53fa5d6155de34b02005c113e9e427e1` |
| `test/integration/Main.hs` (runner, additive) | `fc2a565d4c0a2b603cbd006b615257617a8f27941aca9ea7c5e426e4921adcef` |

Runner changes: `test/unit/Main.hs` +4 lines, `test/integration/Main.hs` +2 lines; nothing removed.

Pre-freeze verification (§8), against type-only stubs of `Kernel.Effect`, `Kernel.EventCodec` and
`Application.Ledger` (scratch; refusing bodies; `mkEffectSpec` and `mkEffectKey` real, being leaf
validators the fixtures need; no migration 0008):

- Build: library and suites compile under `--pedantic`; fourmolu and hlint clean.
- Unit baseline (`evidence/prefreeze-unit-baseline.log`): 27 of 522 fail, **all** in the two new
  groups; the 489 earlier tests pass. Passing against the stubs: both fixture tests, the spec
  acceptance case (real validator) and three codec cases a refuse-everything stub satisfies
  (non-durable inputs, malformed texts), each paired with failing positive cases.
- Integration baseline (`evidence/prefreeze-integration-baseline.log`): 13 of 14 fail, every one at
  the stub's first ledger call. The **scenario setup case passes**: it runs the binary setup and
  every support helper and SQL idiom the other cases use (`sql`, `sqlFails`, the trigger-refusal
  check, the three-call trigger toggle, `sha256()` and interval arithmetic in SQL, `queryTexts`,
  `count` with a condition, a forked thread reporting through an `MVar`).
- That setup run found a defect in my own first draft, before the freeze: the immutability check
  updated `id`, which PostgreSQL refuses for identity columns whatever the trigger does, so the
  check would have passed for the wrong reason. The tests now update `recorded_at` and require the
  trigger's own message (`rows are immutable`), exercised on an existing immutable table first.
- The stubs cannot produce ledger behaviour, so every expected state, revision, count, code and
  text was checked against §2–§4 by reading before the freeze.

### 10.1 Amendment R-P2.5-1 (approved by the human owner, 2026-10-19)

The owner approved R-P2.5-1 as written (`r-p2.5-1-amendment-request.md`): the exact two-literal
diff in `evidence/r-p2.5-1.diff`, applied byte for byte with `git apply`. The class-D budget refusal
code `unsafe-retry-budget` became `retry-budget-forbidden` in the two `EffectTest` literals, in the
matching string in `Lockstep.Kernel.Effect`, and in E1 and §7 above. The old name could not appear
in Kernel source under the frozen C-P2.1 purity scan (`grep -E '\bIO\b|unsafe'`). Every case, input
and other assertion is unchanged; the constructor `UnsafeRetryBudget` and the test title are
unchanged. Re-frozen digest:

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/EffectTest.hs` | `4ccf32bdbcb1037b228d2af09fb9fe444689255610445d793f9a307ae43d7bb6` (was `da22e6ab…`) |

The other five digests above are unchanged. Process improvement carried forward: before a freeze,
every new Kernel identifier, code string and comment is checked against the existing static
enforcement rules (the purity scan, the partial-function ban list, the forbidden-facilities list);
the rules are never weakened or circumvented to fit a name.
