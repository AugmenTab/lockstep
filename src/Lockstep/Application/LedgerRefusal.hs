{- | The Ledger's refusals as values (Increment D).

Inside the Ledger (and the executor, reconciler and sandbox built on it) a
refusal is a 'LedgerRefusal': one constructor per decision, or the Kernel's own
typed refusal. Callers that branch on a refusal match its constructor. A
refusal's code and words are given in one place, 'ledgerRefusalCode' and
'ledgerRefusalMessage'; the codes are the stored refusal codes and the CLI's,
so they never change.

The public 'LedgerFailure' keeps its text shape (@LedgerRefused code message@;
the frozen suites match it, e.g. integration @LedgerTraceTest.hs:250@): a
refusal is rendered into it once, by 'refusalFailure', at the boundary.
-}
module Lockstep.Application.LedgerRefusal
  ( LedgerFailure (..)
  , ledgerFailureCode
  , LedgerRefusal (..)
  , RecordRule (..)
  , StaleSubject (..)
  , FactsRule (..)
  , EvidenceRule (..)
  , OwnershipLoss (..)
  , InactiveFor (..)
  , KeyExpiry (..)
  , ledgerRefusalCode
  , ledgerRefusalMessage
  , refusalFailure
  , LedgerError (..)
  , publicFailure
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Activation (CarryRefusal, carryRefusalCode, carryRefusalMessage)
import Lockstep.Kernel.Effect (EffectRefusal, OperationId (..), effectRefusalCode, effectRefusalMessage)
import Lockstep.Kernel.Identity (identityText)
import Lockstep.Kernel.Profile (ProfileRefusal, profileRefusalCode, renderProfileRefusal)
import Lockstep.Kernel.Reconciliation (ReconcileRefusal, reconcileRefusalCode, reconcileRefusalMessage)
import Lockstep.Kernel.Recovery (RecoveryRefusal, recoveryRefusalCode, recoveryRefusalMessage)
import Lockstep.Kernel.Scheduler (SchedulerRefusal, schedulerRefusalCode, schedulerRefusalMessage)
import Lockstep.Kernel.Transition (TransitionRefusal, transitionRefusalCode, transitionRefusalMessage)

-- | The public failure (frozen shape): a refusal's code and words, an integrity failure, an unavailable database.
data LedgerFailure
  = LedgerRefused T.Text T.Text
  | LedgerIntegrity T.Text
  | LedgerUnavailable T.Text
  deriving (Eq, Show)

ledgerFailureCode :: LedgerFailure -> T.Text
ledgerFailureCode failure =
  case failure of
    LedgerRefused code _ -> code
    LedgerIntegrity _ -> T.pack "integrity"
    LedgerUnavailable _ -> T.pack "unavailable"

-- | Which record rule a value broke (code @invalid-record@).
data RecordRule
  = TitleRule
  | ReasonRule
  | LeaseRule
  | ClaimOwnerRule
  | RecoveryOwnerRule
  | PlanReferenceRule
  | ExecutorRule
  | ReconciliationRule
  deriving (Eq, Show, Enum, Bounded)

-- | What moved on (code @stale-revision@).
data StaleSubject
  = StaleTicket
  | StaleWorkOrder
  | StaleStep
  deriving (Eq, Show, Enum, Bounded)

-- | Which work fact is not valid (code @invalid-facts@).
data FactsRule
  = ClassTagRule
  | PathClassRule
  | RationaleRule
  deriving (Eq, Show, Enum, Bounded)

-- | Which gate-evidence name is not known (code @invalid-evidence@).
data EvidenceRule
  = UnknownArtifact
  | DigestRule
  | UnknownVerifier
  | UnknownApproval
  deriving (Eq, Show, Enum, Bounded)

-- | Why the repository has no owner for the decision (code @repository-not-owned@).
data OwnershipLoss
  = NoActiveOwner
  | ClaimantNoLongerOwns
  deriving (Eq, Show, Enum, Bounded)

-- | What an inactive order refuses (code @subject-not-active@).
data InactiveFor
  = InactiveForDispatch
  | InactiveForCarry
  deriving (Eq, Show, Enum, Bounded)

-- | Where an expired idempotency key was found (code @idempotency-key-expired@).
data KeyExpiry
  = ExpiredAtDispatch
  | ExpiredAtRetry
  deriving (Eq, Show, Enum, Bounded)

data LedgerRefusal
  = RevisionOutOfRange
  | InvalidRecord RecordRule
  | -- | An event the codec cannot store, with the codec's reason.
    NotDurable T.Text
  | UnknownTicket
  | StaleRevision StaleSubject
  | TicketNotReady
  | UnknownEngineer
  | EngineerHasNoRepository
  | RepositoryDefaultProfileUnset
  | UnknownDependency
  | InvalidFacts FactsRule
  | -- | The kind name given.
    InvalidKind T.Text
  | UnknownWorkOrder
  | IntentsNotAuthorized
  | EvidenceNotAuthorized
  | GateEvidenceInvalid EvidenceRule
  | WorkOrderNotActive
  | WorkOrderNotClaimed
  | RepositoryNotOwned OwnershipLoss
  | UnknownIntent
  | SubjectNotActive InactiveFor
  | ActivationSuperseded
  | IdempotencyKeyExpired KeyExpiry
  | -- | The other intents holding the key.
    EffectKeyInUse [OperationId]
  | -- | The intent's generation moved on during a lookup.
    LookupOutdated
  | NoAdapter
  | AdapterMismatch
  | NoReconciler
  | ReconcilerMismatch
  | LookupNotQueryable
  | -- | The text given and the effects known.
    UnknownSandboxEffect T.Text [T.Text]
  | TransitionRefused TransitionRefusal
  | EffectRefused EffectRefusal
  | SchedulerRefused SchedulerRefusal
  | ProfileRuleRefused ProfileRefusal
  | RecoveryRefused RecoveryRefusal
  | ReconcileRefused ReconcileRefusal
  | CarryRefused CarryRefusal
  deriving (Eq, Show)

-- | The refusal's code: the stored and printed code.
ledgerRefusalCode :: LedgerRefusal -> T.Text
ledgerRefusalCode refusal =
  case refusal of
    RevisionOutOfRange -> T.pack "revision-out-of-range"
    InvalidRecord _ -> T.pack "invalid-record"
    NotDurable _ -> T.pack "not-durable"
    UnknownTicket -> T.pack "unknown-ticket"
    StaleRevision _ -> T.pack "stale-revision"
    TicketNotReady -> T.pack "ticket-not-ready"
    UnknownEngineer -> T.pack "unknown-engineer"
    EngineerHasNoRepository -> T.pack "engineer-has-no-repository"
    RepositoryDefaultProfileUnset -> T.pack "repository-default-profile-unset"
    UnknownDependency -> T.pack "unknown-dependency"
    InvalidFacts _ -> T.pack "invalid-facts"
    InvalidKind _ -> T.pack "invalid-kind"
    UnknownWorkOrder -> T.pack "unknown-work-order"
    IntentsNotAuthorized -> T.pack "intents-not-authorized"
    EvidenceNotAuthorized -> T.pack "not-authorized"
    GateEvidenceInvalid _ -> T.pack "invalid-evidence"
    WorkOrderNotActive -> T.pack "work-order-not-active"
    WorkOrderNotClaimed -> T.pack "work-order-not-claimed"
    RepositoryNotOwned _ -> T.pack "repository-not-owned"
    UnknownIntent -> T.pack "unknown-intent"
    SubjectNotActive _ -> T.pack "subject-not-active"
    ActivationSuperseded -> T.pack "activation-superseded"
    IdempotencyKeyExpired _ -> T.pack "idempotency-key-expired"
    EffectKeyInUse _ -> T.pack "effect-key-in-use"
    LookupOutdated -> T.pack "stale-claim"
    NoAdapter -> T.pack "no-adapter"
    AdapterMismatch -> T.pack "adapter-mismatch"
    NoReconciler -> T.pack "no-reconciler"
    ReconcilerMismatch -> T.pack "reconciler-mismatch"
    LookupNotQueryable -> T.pack "not-queryable"
    UnknownSandboxEffect _ _ -> T.pack "unknown-sandbox-effect"
    TransitionRefused r -> transitionRefusalCode r
    EffectRefused r -> effectRefusalCode r
    SchedulerRefused r -> schedulerRefusalCode r
    ProfileRuleRefused r -> profileRefusalCode r
    RecoveryRefused r -> recoveryRefusalCode r
    ReconcileRefused r -> reconcileRefusalCode r
    CarryRefused r -> carryRefusalCode r

-- | The refusal in words, for the person who asked.
ledgerRefusalMessage :: LedgerRefusal -> T.Text
ledgerRefusalMessage refusal =
  case refusal of
    RevisionOutOfRange -> T.pack "a revision or generation is outside the range of a stored integer"
    InvalidRecord rule -> recordRuleMessage rule
    NotDurable reason -> reason
    UnknownTicket -> T.pack "there is no such ticket"
    StaleRevision StaleTicket -> T.pack "the ticket has moved on; re-read it"
    StaleRevision StaleWorkOrder -> T.pack "the work order has moved on; re-read it"
    StaleRevision StaleStep -> T.pack "the step changed since the page was shown"
    TicketNotReady -> T.pack "a work order needs a ready or in-progress ticket"
    UnknownEngineer -> T.pack "there is no Engineer with this name"
    EngineerHasNoRepository -> T.pack "the Engineer owns no repository"
    RepositoryDefaultProfileUnset -> T.pack "the repository has no default profile; see repository set-profile"
    UnknownDependency -> T.pack "a dependency is not a known work order"
    InvalidFacts ClassTagRule -> T.pack "not a valid class tag"
    InvalidFacts PathClassRule -> T.pack "not a valid path class"
    InvalidFacts RationaleRule -> T.pack "not a valid non-behavioural rationale"
    InvalidKind kind -> T.pack "no work order kind " <> kind
    UnknownWorkOrder -> T.pack "there is no such work order"
    IntentsNotAuthorized -> T.pack "only a Supervisor's start or resume may authorize effect intents"
    EvidenceNotAuthorized -> T.pack "only a human or the Supervisor records gate evidence"
    GateEvidenceInvalid UnknownArtifact -> T.pack "an unknown artifact"
    GateEvidenceInvalid DigestRule -> T.pack "a digest must be 64 lowercase hex characters"
    GateEvidenceInvalid UnknownVerifier -> T.pack "an unknown verifier"
    GateEvidenceInvalid UnknownApproval -> T.pack "an unknown approval (none, supervisor or human)"
    WorkOrderNotActive -> T.pack "a work unit is admitted only for a claimed or active work order"
    WorkOrderNotClaimed -> T.pack "only a claimed work order can be started"
    RepositoryNotOwned NoActiveOwner -> T.pack "the work order's repository has no active owner"
    RepositoryNotOwned ClaimantNoLongerOwns -> T.pack "the claiming Engineer no longer owns the order's repository"
    UnknownIntent -> T.pack "there is no such effect intent"
    SubjectNotActive InactiveForDispatch -> T.pack "the work order is not active; nothing may be dispatched for it"
    SubjectNotActive InactiveForCarry -> T.pack "the work order is not active"
    ActivationSuperseded -> T.pack "the intent belongs to an earlier activation of its work order; a Human must carry it first"
    IdempotencyKeyExpired ExpiredAtDispatch -> T.pack "the idempotency key's guarantee has ended; the earlier dispatch may still apply, so nothing was sent"
    IdempotencyKeyExpired ExpiredAtRetry ->
      T.pack "the idempotency key's guarantee has ended; attest that it applied, or abandon the effect with --acknowledge-duplication-risk (a not-applied attestation would only be refused again at dispatch)"
    EffectKeyInUse holders ->
      T.pack "the same effect key is held by "
        <> T.intercalate (T.pack ", ") (fmap identityText holders)
        <> T.pack "; abandon one (with --acknowledge-duplication-risk if it was dispatched), requeue without declaring the key again, and carry the other"
    LookupOutdated -> T.pack "the intent moved on while it was looked up"
    NoAdapter -> T.pack "this executor has no adapter for the effect"
    AdapterMismatch -> T.pack "the adapter implements another spec than the intent declares"
    NoReconciler -> T.pack "no reconciler serves the effect"
    ReconcilerMismatch -> T.pack "the reconciler serves another spec than the intent declares"
    LookupNotQueryable -> T.pack "only a queryable effect can be looked up at its destination"
    UnknownSandboxEffect text known ->
      T.pack "no sandbox effect " <> text <> T.pack "; known: " <> T.intercalate (T.pack ", ") known <> T.pack ", each with an optional :apply, :refuse, :hang or :apply-then-hang"
    TransitionRefused r -> transitionRefusalMessage r
    EffectRefused r -> effectRefusalMessage r
    SchedulerRefused r -> schedulerRefusalMessage r
    ProfileRuleRefused r -> renderProfileRefusal r
    RecoveryRefused r -> recoveryRefusalMessage r
    ReconcileRefused r -> reconcileRefusalMessage r
    CarryRefused r -> carryRefusalMessage r

recordRuleMessage :: RecordRule -> T.Text
recordRuleMessage rule =
  T.pack $
    case rule of
      TitleRule -> "a title has 1 to 200 characters and no control characters"
      ReasonRule -> "a reason is 1-4096 characters without control characters"
      LeaseRule -> "a lease lasts 1 to 3600 seconds"
      ClaimOwnerRule -> "a claim needs an owner"
      RecoveryOwnerRule -> "a recovery needs an owner"
      PlanReferenceRule -> "a plan reference has 1 to 200 characters and no control characters"
      ExecutorRule -> "an executor needs an owner, a lease of 1-3600 s, a timeout below the lease, and one adapter per spec"
      ReconciliationRule -> "a reconciliation needs a timeout of 1-600000 ms and one reconciler per spec"

-- | The refusal as the public failure: its code and its words.
refusalFailure :: LedgerRefusal -> LedgerFailure
refusalFailure refusal =
  LedgerRefused (ledgerRefusalCode refusal) (ledgerRefusalMessage refusal)

{- | A failure inside a Ledger transaction, typed: a refusal, or stored state
that does not reproduce (which rolls the transaction back). The Ledger's
transaction gives it to its caller as a 'LedgerFailure'.
-}
data LedgerError
  = LedgerRefusedBy LedgerRefusal
  | LedgerCorrupt T.Text
  deriving (Eq, Show)

publicFailure :: LedgerError -> LedgerFailure
publicFailure failure =
  case failure of
    LedgerRefusedBy refusal -> refusalFailure refusal
    LedgerCorrupt message -> LedgerIntegrity message
