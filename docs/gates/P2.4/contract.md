# P2.4 Contract — Deterministic Work Order scheduler

- Contract ID: `C-P2.4@v1`
- Status: **DRAFT** (frozen when §10 is filled in)
- Basis: `v2` after P2.3 (`VERIFIED — awaiting human acceptance`); C-P2.2 Work Order lifecycle;
  C-P2.3 Profile bindings.
- Authority: `.local/plans/phase-02.md` §8 (P2.4) and §3; **DG-05 ACCEPTED with clarifications**
  (`docs/gates/P2.3/dg-05-decision-request.md`, Human decision, 2026-10-18), D-5.7–D-5.11 and
  clarifications 1 and 3.
- Traces: FR-WRK-03 (eligibility and deterministic selection), PRD §5.1 (filters, ordering,
  unknown quotas are not numbers), Bible §3.5 and §31.2 (one mutating Implementer per repository).
- Writer: the single writing agent (manual).

## 1. Objective

A pure scheduler in `Lockstep.Kernel.Scheduler`. Given the authoritative facts about known Work
Orders, repository ownership, Profile sources, resources and source revisions, it decides, for
every queued Work Order, whether it is eligible and why not, ranks the eligible ones, and selects
at most one. The decision has a canonical rendering and a digest, so the same inputs always give
the same evidence. No model, no I/O, no ranking authority beyond the human-approved priority.

Out of scope here: persisting Work Orders and decisions, claiming (claims and their fencing
generations are C-P2.5), and running the scheduler from the service (C-P2.6). The scheduler
produces the Scheduler's lifecycle commands (`mark-eligible`, `mark-ineligible`) for the caller to
apply; it never claims.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| S1 | **Candidates.** Only orders in `pending` or `eligible` are candidates. Orders in any other state are context only (reservations and dependencies) and never appear as eligible, ineligible or selected. |
| S2 | **Priority** (D-5.8). `mkPriority :: Principal -> Int -> Either SchedulerRefusal Priority`: only `Human` may set one (`priority-not-human` otherwise, including `Agent`, `Scheduler` and `Supervisor`); the value is 0–999, higher first (`invalid-priority` otherwise). There is no urgency class (D-5.9a). |
| S3 | **Eligibility checks** (D-5.7), every reason collected, rendered in this order: (1) `binding-mismatch` — the binding names another Work Order (then checks 2–3 are skipped: the binding cannot be trusted); (2) `profile-default-unset` when the repository has no current default, otherwise `profile-changed <ids>` when `bindingFreshness` (C-P2.3 F10) is not `Fresh`; (3) `prerequisite-blocked <gate> <block>` for each applicable `before-execution` gate (`executionPrerequisites`) whose `evaluateGate` is `GateBlocked`, by gate id, block one of `missing-artifact`, `ambiguous-evidence`, `unverified`, `needs-approval` with its artifact; a `GateExcepted` gate is satisfied; (4) per dependency, by id: `dependency-unknown` (not among the known orders), `dependency-unsatisfiable` (superseded or canceled), `dependency-incomplete` (any other state but `completed`); (5) `repository-not-owned` (no active owner); (6) `repository-reserved <holder>` for each other order holding an active reservation of the same repository, by id; (7) per required resource, by name: `resource-unknown` (absent or reported unknown) or `resource-unavailable`; (8) `source-unknown` (no current revision for the source Ticket) or `source-stale` (the order's basis revision differs from the current one). An order with no reason is eligible. |
| S4 | **Clarification 1.** Only `before-execution` gates are scheduling prerequisites. An unsatisfied `before-acceptance` or `before-completion` gate (for example missing `verification-record`, which only execution can produce) never blocks scheduling. |
| S5 | **Clarification 3.** An active reservation is held only by an order in `claimed`, `active` or `waiting`. A `pending` or `eligible` order (queued work) holds none, so two queued orders for one repository can both be eligible; only one can be selected per decision, and once it is claimed the other is `repository-reserved`. `halted`, `completed`, `superseded` and `canceled` orders hold no reservation (C-P2.2 `Halted` carries no claim; an unresolved effect blocking its repository is C-P2.7). |
| S6 | **Unknown resources** (D-5.10). A resource is a name (`^[a-z][a-z0-9-]{0,63}$`, `invalid-resource` otherwise) with availability `available`, `unavailable` or `unknown`. A name absent from the input is unknown. No quantity is modelled or invented. |
| S7 | **Ordering** (D-5.8). Eligible orders are ranked by priority (highest first), then admission time (oldest first), then `WorkOrderId` (smallest first; the order of the canonical UUID text). The first is selected, with its repository's owning Engineer (for the C-P2.5 claim). A blocked order is never selected, whatever its priority; it is reported with its reasons. |
| S8 | **Input integrity.** Two orders with one id, two owners for one repository, two defaults for one repository, two availabilities for one resource, two current revisions for one Ticket, or one order listing a resource or dependency twice is `conflicting-input <what>`, refusing the whole decision. Nothing else depends on the order of any input list. |
| S9 | **Safe boundaries** (D-5.11). An order in `claimed`, `active` or `waiting` is never preempted or reported; a priority change takes effect at the next decision because priority is an input. Emergency interruption remains the human `halt` (C-P2.2). |
| S10 | **Commands.** `schedulingCommands` gives, by id, `Command Scheduler WoMarkEligible` for each eligible `pending` order and `Command Scheduler WoMarkIneligible` for each ineligible `eligible` order; nothing else. Each is legal for `stepWorkOrder`. |
| S11 | **Rendering and digest.** `renderScheduleDecision` (§3); `scheduleDigest :: Hasher -> ScheduleDecision -> ContentDigest` is the hash of the rendering (SHA-256 with `sha256Hasher`). |

## 3. Canonical rendering (normative; lines end with `\n`)

```
lockstep-schedule 1
selected <uuid> engineer <uuid>                     (or: selected none)
eligible <rank> <uuid> priority=<p> admitted-at=<iso>          (rank from 1, in rank order)
ineligible <uuid> <code>[ <detail>]                 (by order id, then the S3 order; one line per reason)
```

Details: `profile-changed` lists the changed Profile ids comma-joined (sorted);
`prerequisite-blocked` is `<gate> <block> <artifact>` (artifact kind names as C-P2.3 F1);
`repository-reserved` the holder's uuid; dependency reasons the dependency's uuid; resource
reasons the resource name; the others have none. Timestamps are ISO 8601 UTC (`iso8601Show`).

## 4. Production API the tests bind to

```haskell
-- Lockstep.Kernel.Scheduler
data Priority; mkPriority :: Principal -> Int -> Either SchedulerRefusal Priority; priorityValue :: Priority -> Int
data ResourceName; mkResourceName :: Text -> Either SchedulerRefusal ResourceName; resourceNameText :: ResourceName -> Text
data Availability = ResourceAvailable | ResourceUnavailable | ResourceUnknown
data SourceBasis = SourceBasis { sourceTicket :: TicketId, sourceRevision :: Int }
data ScheduledOrder = ScheduledOrder
  { orderWorkOrder :: WorkOrder, orderRepository :: RepositoryId, orderPriority :: Priority
  , orderAdmittedAt :: UTCTime, orderDependencies :: [WorkOrderId], orderBinding :: ProfileBinding
  , orderConfirmations :: [ProfileConfirmation], orderEvidence :: [GateEvidence]
  , orderResources :: [ResourceName], orderSource :: SourceBasis }
data SchedulerInput = SchedulerInput
  { inputOrders :: [ScheduledOrder], inputOwners :: [(RepositoryId, EngineerId)]
  , inputDefaults :: [(RepositoryId, ProfileRef)], inputCatalog :: [ProfileRef]
  , inputResources :: [(ResourceName, Availability)], inputRevisions :: [(TicketId, Int)] }
data Ineligibility = BindingMismatch | ProfileDefaultUnset | ProfileChangedSince [ProfileId]
  | PrerequisiteBlocked GateId GateBlock | DependencyUnknown WorkOrderId | DependencyUnsatisfiable WorkOrderId
  | DependencyIncomplete WorkOrderId | RepositoryNotOwned | RepositoryReserved WorkOrderId
  | ResourceUnknownReason ResourceName | ResourceUnavailableReason ResourceName | SourceUnknown | SourceStale
ineligibilityCode :: Ineligibility -> Text
data ScheduleDecision
scheduleOrders :: SchedulerInput -> Either SchedulerRefusal ScheduleDecision
decisionSelected :: ScheduleDecision -> Maybe (WorkOrderId, EngineerId)
decisionEligible :: ScheduleDecision -> [WorkOrderId]                         -- rank order
decisionIneligible :: ScheduleDecision -> [(WorkOrderId, [Ineligibility])]    -- by id; reasons in S3 order
schedulingCommands :: SchedulerInput -> ScheduleDecision -> [(WorkOrderId, Command WorkOrderInput)]
renderScheduleDecision :: ScheduleDecision -> Text
scheduleDigest :: Hasher -> ScheduleDecision -> ContentDigest
data SchedulerRefusal = PriorityNotHuman Principal | InvalidPriority Int | InvalidResource Text | ConflictingInput Text
schedulerRefusalCode :: SchedulerRefusal -> Text
```

## 5. Allowed paths

`src/Lockstep/Kernel/Scheduler.hs` (new), `test/unit/Lockstep/Kernel/SchedulerTest.hs`,
`test/unit/Lockstep/Kernel/SchedulerPropertyTest.hs`, `test/unit/Lockstep/Kernel/SchedulerFixtures.hs`
(new), `test/unit/Main.hs` (runner lines), `docs/architecture/ARCHITECTURE.md`,
`docs/gates/P2.4/**`. Earlier modules unchanged; frozen tests unchanged.

## 6. Tests (frozen before implementation)

Unit (`lockstep-unit`, pure; Profile bindings are built with the real C-P2.3 API):

| Area | Cases |
|---|---|
| Fixtures | the fixture world builds (bindings, refs, owners); asserted on its own so the test setup is exercised before the freeze |
| Priority and names | `Human` sets 0 and 999; `Agent`, `Scheduler`, `Supervisor` → `priority-not-human`; -1 and 1000 → `invalid-priority`; resource names valid and invalid |
| Selection | one eligible order is selected with its owner; no candidates → `selected none`; a blocked highest-priority order is excluded and the eligible lower one selected, the blocked one reported with its reason; priority, then admission time, then id break ties; the decision is identical for every permutation of every input list |
| Each reason | one case per S3 reason, each against an otherwise eligible order, asserting the code and its detail; several reasons are all reported in S3 order; a `binding-mismatch` order reports no profile reasons |
| Clarification 1 | an order whose only unsatisfied gate is `before-acceptance` (needs `verification-record`) is eligible; an unsatisfied `before-execution` gate blocks; an excepted `before-execution` gate does not block |
| Clarification 3 | two queued orders for one repository are both eligible and only the higher-ranked is selected; once one is `claimed` (or `active`, `waiting`) the other is `repository-reserved` naming it; `halted`, `completed` and `canceled` orders reserve nothing |
| Context orders | orders in non-candidate states never appear in the decision; a `completed` dependency is satisfied; `superseded`/`canceled` are unsatisfiable; unknown is unknown |
| Resources and sources | absent and reported-unknown resources → `resource-unknown`; unavailable → `resource-unavailable`; a missing current revision → `source-unknown`; a different one → `source-stale` |
| Mid-flight Profile change | a new default version → `profile-changed`; a human confirmation for the current sources makes it eligible again; no default → `profile-default-unset` |
| Input integrity | each S8 duplicate → `conflicting-input` |
| Commands | eligible `pending` → `mark-eligible`; ineligible `eligible` → `mark-ineligible`; others none; each command is accepted by `stepWorkOrder` |
| Rendering | the golden rendering of a mixed decision; the digest is the SHA-256 of the rendering |

Properties (`SchedulerPropertyTest`, seeded 20261019, 1000 cases each) over generated worlds of up
to 6 orders (random states, priorities, admission times, dependencies, repositories, owners,
resources, revisions and gate evidence):

1. replay: deciding twice gives the same rendering and digest;
2. permutation: shuffling every input list gives the same rendering;
3. soundness: every candidate is either eligible or has at least one reason, never both; no
   non-candidate appears; the eligible list is sorted by S7; the selection is its head;
4. oracle: an order is eligible exactly when an independent test predicate over the generated
   world says so;
5. commands: applying `schedulingCommands` with `stepWorkOrder` succeeds and leaves exactly the
   eligible candidates in `eligible`.

## 7. Verification

Pre-freeze: the tests compile against type-only stubs; format and lint clean; the unit baseline
fails only in the new groups, the fixture test passes (it exercises the test setup independently,
R-P2.3-1 lesson), and every earlier test passes. Acceptance: `scripts/check --integration` on the
clean tree; a Linux clone; frozen digests P1.1–P2.4; `check-kernel-boundary` covers `Scheduler`.

## 8. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a rule that contradicts DG-05
or a source document. Rollback: revert the P2.4 commits (no migration).

## 9. Freeze record

(Filled in at freeze.)
