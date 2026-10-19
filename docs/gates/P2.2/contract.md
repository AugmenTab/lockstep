# P2.2 Contract — Pure domain states and transitions

- Contract ID: `C-P2.2@v1`
- Status: **FROZEN** (2026-10-18)
- Basis: `v2` at `e6af76e` (P2.1 `VERIFIED — awaiting human acceptance` at `2eb97c5`).
- Authority: `.local/plans/phase-02.md` §6 (P2.2) and §3; the owner's instruction of 2026-10-18 to
  proceed through the dependency-ordered handoff. No decision gate applies to P2.2 (DG-05 begins at
  P2.3). PRD §3.2 says status names are examples and that "the final Haskell constructors … must be
  frozen at a design gate". This Contract freezes them for Phase 2, and the human owner's Gate B
  decision accepts or amends them. Nothing here is persisted: storage and effect intents are P2.5.
- Traces: FR-WRK-04 (separate Ticket, Work Order, Work Unit and Delivery state machines with
  validated transitions; property-based and negative tests reject invalid cross-effects), FR-EXE-01
  (pure transition/authority core; invalid state/evidence combinations unrepresentable or refused);
  PRD §3.2; Bible §9, §16.2, §37, §37.1; ARCHITECTURE §2.
- Writer: the single writing agent (manual).

## 1. Objective

Four separate, pure Haskell lifecycles in `Lockstep.Kernel`. There is no shared status enum. Each
lifecycle has distinct constructors that carry their prerequisite evidence, typed inputs submitted
by a typed principal, a total step function that returns the next state or a typed refusal, and a
deterministic replay. Evidence crosses domains only through smart constructors:

- a Ticket reaches Code Complete only with accepted Work Unit evidence, which can only be
  obtained from an Accepted Work Unit;
- a Ticket reaches Ready for Signoff only with integration evidence, which can only be obtained
  from an Integrated Delivery;
- a Ticket reaches Done only by a human signoff.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| T1 | **Principals.** `Principal = Human \| Supervisor \| Scheduler \| DeliveryAdapter \| Agent`. Every input arrives as `Command principal input`. The boundary authenticates the principal (Human = the CLI/session trust of P1.3). An **`Agent` principal is never accepted** for any input in any domain (refusal `agent-assertion`). An agent's or model's claim becomes evidence only after the Supervisor validates it into a typed observation. |
| T2 | **Refusals.** `TransitionRefusal = AgentAssertion \| AlreadyTerminal Text \| NotAuthorized Principal Text \| IllegalTransition Text Text \| ClaimMismatch \| BasisMismatch Text \| KindForbids Text \| AttemptBudgetExhausted \| GatesPending`, checked in this order: agent principal; terminal state; the (state, input) pair is not in the §3 table (`illegal-transition`); the principal is not permitted for that pair (`not-authorized`, which may differ by state and mode); then the evidence checks of the cell. A refusal never changes state. Codes: `agent-assertion`, `already-terminal`, `not-authorized`, `illegal-transition`, `claim-mismatch`, `basis-mismatch`, `kind-forbids`, `attempt-budget-exhausted`, `gates-pending`. |
| T3 | **Replay.** `replay step initial commands` folds and stops at the first refusal, returning its index; `replayTrace` returns every accepted `(from, input, principal, to)` step and every refusal, continuing from the unchanged state. Both are pure and deterministic. |
| T4 | **Ticket** (§3.1): business intent and the final human disposition. A Ticket state grants no code-mutation authority. |
| T5 | **Work Order** (§3.2): scheduling, claim and execution authorization. The kind fixes the effect class. Only `Engineering` and `PrRework` may complete with Work Units; other kinds must complete with none. Claim-bearing inputs must name the current claim exactly (engineer and generation). An `Active` or `Claimed` order cannot be canceled before it is halted. |
| T6 | **Work Unit** (§3.3): bounded engineering, following Bible §37.1. `Verifying` carries the observed commit, `Verified` carries passing verification for that commit plus the post-verification gates still pending, and `Accepted` carries the contract, commit, verification and approving review. A verification with any `CheckFailed` goes to rework while attempts remain, and to `Halted attempts-exhausted` when none remain. A verification with no failure but any `CheckNotRun` or `CheckUnknown` halts as `verification-inconclusive`: uncertain is never passed. Review is accepted only after every frozen post-verification gate has passed (`gates-pending`). |
| T7 | **Delivery** (§3.4): integration and downstream completion, with no Done state. In `PullRequest` mode integration requires an approval of the exact integrated commit; a push after approval makes the approval stale. In `LocalOnly` mode the Supervisor integrates locally and publication is `kind-forbids`. An unknown outcome moves to `NeedsReconciliation` and keeps the prior state. |
| T8 | **Evidence types.** `CommitId` is 40 lowercase hex (`mkCommitId`). `AcceptedWorkUnit` (abstract) is obtainable only through `acceptedWorkUnit :: WorkUnit -> Maybe AcceptedWorkUnit`. `IntegrationEvidence` (abstract) is obtainable only through `integrationEvidence :: Delivery -> Maybe IntegrationEvidence`. `HumanSignoff` carries a non-empty receipt text supplied by the boundary. |
| T9 | **Purity.** All modules are under `Lockstep.Kernel` and subject to C-P2.1 I2 (Henforcer rows, purity scan). No change to the Henforcer configuration. |
| T10 | **Test dependency.** `tasty-quickcheck` (lts-24.12; QuickCheck 2.15.0.1 is already in the dependency tree) for `lockstep-unit` only; it is not linked into the binary. Properties run with a fixed seed (`QuickCheckReplay`) and 2000 cases each, so a failure is reproducible. |

## 3. Transition tables (normative; the tests encode them)

Each table cell lists the permitted principals and the resulting state. Any combination not
listed is refused (T2). The terminal states refuse every input with `already-terminal`.

### 3.1 Ticket — `TicketState`

States: `Proposed`, `Ready`, `InProgress`, `CodeComplete (NonEmpty AcceptedWorkUnit)`,
`AwaitingReview (NonEmpty AcceptedWorkUnit)`, `ReadyForSignoff IntegrationEvidence`,
`Done HumanSignoff` (terminal), `Canceled HumanSignoff` (terminal), `Blocked Text TicketState`
(the prior state, never `Blocked` or terminal).

| Input | From | Principals | To |
|---|---|---|---|
| `TicketAccept` | Proposed | Human | Ready |
| `TicketStartWork` | Ready | Supervisor | InProgress |
| `TicketWorkAccepted ws` | InProgress | Supervisor | CodeComplete ws |
| `TicketReviewRequested` | CodeComplete ws | DeliveryAdapter | AwaitingReview ws |
| `TicketChangesRequested` | CodeComplete, AwaitingReview | DeliveryAdapter | InProgress |
| `TicketIntegrated e` | CodeComplete ws, AwaitingReview ws | Supervisor, DeliveryAdapter | ReadyForSignoff e — **`basis-mismatch`** unless every Work Unit in `ws` is among `e`'s |
| `TicketSignoff h` | ReadyForSignoff | Human | Done h |
| `TicketCancel h` | every non-terminal state (including Blocked) | Human | Canceled h |
| `TicketBlock r` | every non-terminal, non-Blocked state | Human, Supervisor | Blocked r prior |
| `TicketUnblock` | Blocked r prior | Human | prior |

### 3.2 Work Order — `WorkOrder { workOrderId, workOrderKind, workOrderState }`

Kinds: `Engineering`, `Investigate`, `PrRework`, `Integrate`, `Plan`, `PublishReport`,
`SkillInstall`. `Claim { claimEngineer :: EngineerId, claimGeneration :: Int }`.
States: `Pending`, `Eligible`, `Claimed Claim`, `Active Claim`, `Waiting Claim Text`,
`Halted Text`, `Completed Claim [AcceptedWorkUnit]` (terminal), `Superseded WorkOrderId`
(terminal), `Canceled` (terminal).

| Input | From | Principals | To |
|---|---|---|---|
| `WoMarkEligible` | Pending | Scheduler | Eligible |
| `WoMarkIneligible` | Eligible | Scheduler | Pending |
| `WoClaim c` | Eligible | Scheduler | Claimed c |
| `WoRelease c` | Claimed c | Scheduler | Eligible (`claim-mismatch` unless c is the current claim) |
| `WoStart c` | Claimed c | Supervisor | Active c (same claim check) |
| `WoWait c r` | Active c | Supervisor | Waiting c r (same) |
| `WoResume c` | Waiting c r | Supervisor | Active c (same) |
| `WoComplete c ws` | Active c | Supervisor | Completed c ws (same; `kind-forbids` if ws is empty for Engineering/PrRework or non-empty for any other kind) |
| `WoHalt r` | Claimed, Active, Waiting | Human, Supervisor | Halted r |
| `WoRequeue` | Halted | Human | Pending |
| `WoSupersede w` | Pending, Eligible, Halted | Human | Superseded w |
| `WoCancel` | Pending, Eligible, Halted | Human | Canceled |

### 3.3 Work Unit — `WorkUnit { workUnitIdentity :: AdmittedWorkUnit, workUnitState }`

`FrozenContract { frozenContractId :: ContractId, frozenDigest :: Text, frozenAttemptBudget :: Int,
frozenGates :: [Text] }` (budget 1–10, digest 64 lowercase hex, gate names unique, else
`basis-mismatch` at freeze). `Attempt { attemptId :: AttemptId, attemptNumber :: Int }`.
`Verification { verifiedCommit :: CommitId, verifiedChecks :: NonEmpty (Text, CheckOutcome) }`,
`CheckOutcome = CheckPassed | CheckFailed | CheckNotRun | CheckUnknown`.
`ReviewVerdict = ReviewApproved | ReviewChangesRequested Text`.
States: `Candidate`, `Frozen FrozenContract`, `Implementing FrozenContract Attempt`,
`Verifying FrozenContract Attempt CommitId`, `Verified FrozenContract Attempt Verification [Text]`
(the pending gates), `Rework FrozenContract Int Text` (attempts used, reason),
`Accepted FrozenContract CommitId Verification` (terminal), `Halted Text` (terminal).

| Input | From | Principals | To |
|---|---|---|---|
| `WuFreeze fc` | Candidate | Supervisor | Frozen fc |
| `WuStartAttempt a` | Frozen fc (a number 1); Rework fc n (a number n+1) | Supervisor | Implementing fc a — `basis-mismatch` for another number; `attempt-budget-exhausted` past the budget |
| `WuImplementationObserved c` | Implementing fc a | Supervisor | Verifying fc a c |
| `WuVerificationObserved v` | Verifying fc a c | Supervisor | all passed → Verified fc a v gates(fc); any failed → Rework fc n "verification-failed" or Halted "attempts-exhausted" at the budget; otherwise → Halted "verification-inconclusive"; `basis-mismatch` if `verifiedCommit v` ≠ c |
| `WuGatePassed g` | Verified fc a v gs, g ∈ gs | Supervisor | Verified fc a v (gs without g); `basis-mismatch` if g ∉ gs |
| `WuGateFailed g r` | Verified fc a v gs, g ∈ gs | Supervisor | Rework fc n ("gate-failed") or Halted "attempts-exhausted"; `basis-mismatch` if g ∉ gs |
| `WuReviewObserved d` | Verified fc a v [] | Supervisor | Approved → Accepted fc (commit v) v; ChangesRequested → Rework fc n "review-changes-requested" or Halted "attempts-exhausted"; `gates-pending` if gates remain |
| `WuHalt r` | every non-terminal state | Human, Supervisor | Halted r |

### 3.4 Delivery — `Delivery { deliveryMode :: DeliveryMode, deliveryState }`

`DeliveryMode = LocalOnly | PullRequest`. `PullRequestRef` is non-empty text.
States: `LocallyAccepted (NonEmpty AcceptedWorkUnit)`, `Published ws PullRequestRef CommitId`,
`Approved ws pr CommitId`, `ChangesRequested ws pr`, `StaleApproval ws pr CommitId`,
`Integrated ws CommitId` (terminal), `ClosedWithoutMerge ws pr` (terminal),
`NeedsReconciliation DeliveryState Text` (the prior state).

| Input | From | Principals | To |
|---|---|---|---|
| `DelPublish pr c` | LocallyAccepted ws | DeliveryAdapter | Published ws pr c (`kind-forbids` in LocalOnly) |
| `DelApprove c` | Published ws pr c', StaleApproval ws pr c' | DeliveryAdapter | Approved ws pr c' (`basis-mismatch` unless c = c') |
| `DelRequestChanges` | Published, Approved, StaleApproval | DeliveryAdapter | ChangesRequested ws pr |
| `DelPush c` | ChangesRequested ws pr | DeliveryAdapter | Published ws pr c |
| `DelPush c` | Approved ws pr c' | DeliveryAdapter | StaleApproval ws pr c (`basis-mismatch` if c = c') |
| `DelIntegrate c` | Approved ws pr c' (PullRequest) | DeliveryAdapter | Integrated ws c (`basis-mismatch` unless c = c') |
| `DelIntegrate c` | LocallyAccepted ws (LocalOnly) | Supervisor | Integrated ws c |
| `DelClose` | Published, Approved, ChangesRequested, StaleApproval | DeliveryAdapter | ClosedWithoutMerge ws pr |
| `DelOutcomeUnknown r` | every non-terminal, non-reconciling state | DeliveryAdapter, Supervisor | NeedsReconciliation prior r |
| `DelReconciled` | NeedsReconciliation prior r | Supervisor | prior |

In PullRequest mode `DelIntegrate` from LocallyAccepted is `illegal-transition`. In LocalOnly mode
`DelIntegrate` from Approved cannot occur, because the order is never published.

## 4. Allowed paths

`src/Lockstep/Kernel/**` (new modules `Transition`, `Evidence`, `Ticket`, `WorkOrder`,
`WorkUnitLifecycle`, `Delivery`; `AcceptedWorkUnit` and `IntegrationEvidence` are defined in the
modules whose states produce them and exported without constructors), `test/unit/**` (new files plus runner lines), `package.yaml` and
`lockstep.cabal` (the T10 test dependency only), `docs/gates/P2.2/**`. P2.1 modules unchanged
except new exports. Not allowed: persistence, migrations, CLI, Web, Henforcer configs, frozen tests.

## 5. Production API the tests bind to

```haskell
-- Lockstep.Kernel.Transition
data Principal = Human | Supervisor | Scheduler | DeliveryAdapter | Agent   -- Eq, Ord, Show, Enum, Bounded
data Command i = Command { commandPrincipal :: Principal, commandInput :: i }
data TransitionRefusal = AgentAssertion | AlreadyTerminal Text | NotAuthorized Principal Text
  | IllegalTransition Text Text | ClaimMismatch | BasisMismatch Text | KindForbids Text
  | AttemptBudgetExhausted | GatesPending
transitionRefusalCode :: TransitionRefusal -> Text
data TraceStep s i = StepAccepted s (Command i) s | StepRefused s (Command i) TransitionRefusal
replay :: (s -> Command i -> Either TransitionRefusal s) -> s -> [Command i] -> Either (Int, TransitionRefusal) s
replayTrace :: (s -> Command i -> Either TransitionRefusal s) -> s -> [Command i] -> (s, [TraceStep s i])

-- Lockstep.Kernel.Evidence
data CommitId; mkCommitId :: Text -> Maybe CommitId; commitIdText :: CommitId -> Text
data HumanSignoff; mkHumanSignoff :: Text -> Maybe HumanSignoff
-- Lockstep.Kernel.WorkUnitLifecycle (abstract: only an Accepted Work Unit yields one)
data AcceptedWorkUnit; acceptedWorkUnitId :: AcceptedWorkUnit -> WorkUnitId; acceptedCommit :: AcceptedWorkUnit -> CommitId
-- Lockstep.Kernel.Delivery (abstract: only an Integrated Delivery yields one)
data IntegrationEvidence; integratedWorkUnits :: IntegrationEvidence -> NonEmpty WorkUnitId; integratedCommit :: IntegrationEvidence -> CommitId

-- Lockstep.Kernel.Ticket / WorkOrder / WorkUnitLifecycle / Delivery
-- the state, input and record types of §3; for each domain:
stepTicket :: TicketState -> Command TicketInput -> Either TransitionRefusal TicketState
stepWorkOrder :: WorkOrder -> Command WorkOrderInput -> Either TransitionRefusal WorkOrder
stepWorkUnit :: WorkUnit -> Command WorkUnitInput -> Either TransitionRefusal WorkUnit
stepDelivery :: Delivery -> Command DeliveryInput -> Either TransitionRefusal Delivery
ticketStateName, workOrderStateName, workUnitStateName, deliveryStateName :: … -> Text   -- the §3 names, kebab-case
ticketInputName, workOrderInputName, workUnitInputName, deliveryInputName :: … -> Text
mayCompleteWithWorkUnits :: WorkOrderKind -> Bool
acceptedWorkUnit :: WorkUnit -> Maybe AcceptedWorkUnit
integrationEvidence :: Delivery -> Maybe IntegrationEvidence
newDelivery :: DeliveryMode -> NonEmpty AcceptedWorkUnit -> Delivery
newWorkUnit :: AdmittedWorkUnit -> WorkUnit                                   -- Candidate
newWorkOrder :: WorkOrderId -> WorkOrderKind -> WorkOrder                     -- Pending
mkFrozenContract :: ContractId -> Text -> Int -> [Text] -> Maybe FrozenContract
mkPullRequestRef :: Text -> Maybe PullRequestRef
```

## 6. Tests (frozen before implementation)

Unit only (`lockstep-unit`; pure):

| Area | Cases |
|---|---|
| Exhaustive tables | For each domain: every representative state (one per constructor; Work Unit `Verified` with and without pending gates; Delivery in both modes) × every representative input (at least one per constructor, with matching and mismatching evidence where a cell checks evidence) × every principal is compared with the §3 table, written as explicit rows in the test. A listed row gives its next state (by name) or its evidence refusal for its permitted principals, `not-authorized` for the others and `agent-assertion` for Agent. Every unlisted combination is `agent-assertion` for Agent, `already-terminal` from a terminal state and `illegal-transition` otherwise. |
| Evidence refusals | Ticket integrated with evidence missing a Work Unit → `basis-mismatch`. Work Order wrong claim engineer or generation → `claim-mismatch`; Engineering complete with no Work Units and Investigate with some → `kind-forbids`. Work Unit wrong attempt number → `basis-mismatch`; past the budget → `attempt-budget-exhausted`; verification of another commit → `basis-mismatch`; unknown gate → `basis-mismatch`; review with gates pending → `gates-pending`. Delivery approval or integration of another commit → `basis-mismatch`; publish in LocalOnly → `kind-forbids`; push equal to the approved commit → `basis-mismatch` |
| Work Unit outcomes | all passed → Verified; failed with attempts left → Rework; failed at the budget → Halted `attempts-exhausted`; NotRun or Unknown with no failure → Halted `verification-inconclusive` (never Verified); a full happy path to Accepted; gates passed one by one |
| Cross-domain | the only way to obtain `AcceptedWorkUnit` is an Accepted Work Unit (`acceptedWorkUnit` is `Nothing` for every other state); `integrationEvidence` is `Nothing` except for Integrated; an end-to-end path Ticket → Work Order → Work Unit → Delivery → Ticket Ready for Signoff → human Done; Delivery has no Done state, and Integrated moves the Ticket only to Ready for Signoff |
| Smart constructors | `mkCommitId` 40 lowercase hex only; `mkHumanSignoff` non-empty and no control characters; `mkFrozenContract` budget 1–10, 64-hex digest, unique gates; `mkPullRequestRef` non-empty |
| Replay | `replay` stops at the first refusal with its index; `replayTrace` continues from the unchanged state; replaying the same commands twice gives equal results |
| Properties (seeded, 2000 cases each) | for random command sequences over each domain's inputs and all principals: no accepted step has the Agent principal; a terminal state never changes; every refusal leaves the state unchanged; Ticket: every accepted step into Done is a Human Signoff from ReadyForSignoff; Work Order: Completed only from Active and every accepted claim-bearing step names the current claim; Work Unit: Accepted only from Verified with no pending gates, attempt numbers never exceed the budget, and no inconclusive verification reaches Verified; Delivery: in PullRequest mode Integrated only from Approved with the same commit; replay is deterministic |

## 7. Verification

Pre-freeze: the tests compile against type-only stubs under `--pedantic`; format and lint clean;
the unit baseline fails only in the new groups, and earlier tests pass. Acceptance:
`scripts/check --integration` on the clean tree; a Linux clone; frozen digests P1.1–P2.2;
`check-kernel-boundary` covering the new modules; licenses unchanged (test-only dependency).

## 8. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a §3 rule that contradicts a
source document or makes a frozen expectation impossible, or on any need for persistence. Rollback:
revert the P2.2 commits (pure code, no migration).

## 9. Freeze record

Frozen 2026-10-18 by the writing agent (manual). Frozen files never change in P2.2 without the
protected-test amendment protocol.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/LifecycleFixtures.hs` (test support) | `d965b6a1c20fbd8dc26498137097aa5e0b41d77f0e000c139ce2e09602a1f338` |
| `test/unit/Lockstep/Kernel/TransitionTest.hs` | `70a98f2cdc6d12ceaecdb98fb3445ec02d8a986ee8ca43ca04772aa2d6e17e2a` |
| `test/unit/Lockstep/Kernel/TicketTest.hs` | `6b93d6475ae042ebaf104076d083b53d0778271557315e022793188d28b7324c` |
| `test/unit/Lockstep/Kernel/WorkOrderTest.hs` | `ae46858499b80b8801d07916776de8d4690b29913c90b94b5317717963309140` |
| `test/unit/Lockstep/Kernel/WorkUnitLifecycleTest.hs` | `9299e9807f6cb0db5f4f0bb6587a57540ce0598cc185d4a2da18f6a43ba6b074` |
| `test/unit/Lockstep/Kernel/DeliveryTest.hs` | `1f4f100e241e2dbb380cae0dea8373ccc12f0664281544ae6f14a8be6619fc6d` |
| `test/unit/Lockstep/Kernel/LifecyclePropertyTest.hs` | `6c19659cbb4d675ca81574c9e1b9d0b16d243c52fe08c38bcf0bdf627d2ad324` |
| `test/unit/Main.hs` (runner, additive) | `6fdc91a5532ce75f3f4894ac9b6afc52ce2a5029b24a338f65e5690f39431178` |

Runner change: `test/unit/Main.hs` gains six imports and six list entries (12 added lines, 0
removed). `package.yaml` gains `QuickCheck` and `tasty-quickcheck` for `lockstep-unit` only (T10).

Pre-freeze verification (§7), against type-only stubs (scratch, not committed: the six Kernel
modules with refusing or empty bodies):

- Build: library and both suites compile under `--pedantic`. hlint on the tests: no hints, after
  four hints were applied (move a guard forward, `fromRight`, `second`, `isJust`).
- Unit baseline (`evidence/prefreeze-unit-baseline.log`): 37 of 368 fail, **all** in the six new
  groups; the 330 earlier tests pass. The one new test passing against the stubs is "replaying
  the same commands twice gives equal results", which a no-op replay satisfies trivially; the
  replay tests next to it do not. The four properties fail at their first case on "fixtures could
  not be built" (the stub smart constructors refuse everything), which is the missing feature,
  not a helper defect.
- Because the stubs cannot exercise the frozen helpers (`exhaustive`, the guided generator, the
  trace-chain invariant), every table row and property predicate was checked against §3 by
  reading, before the freeze.
