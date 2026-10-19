{- | Reconciliation and human resolution of uncertain effects (contract C-P2.7
R3, R5, R7; DG-04 D-4.5, D-4.6, binding requirements 3 to 6). An uncertain
outcome is resolved only by evidence that can prove it: a destination lookup
for a queryable effect, read under the destination's declared terms, or an
explicit human decision, which is always marked as attested. A late applied
observation that contradicts the durable state is a conflict, never ignored.
Nothing here performs an effect.
-}
module Lockstep.Kernel.Reconciliation
  ( LookupResult (..)
  , ReconcileInput (..)
  , reconcileIntent
  , Resolution (..)
  , resolveIntent
  , LateVerdict (..)
  , judgeLateObservation
  , renderLookup
  , renderResolution
  , ReconcileRefusal (..)
  , reconcileRefusalCode
  ) where

import Data.Char qualified as Char
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectClass (..)
  , Intent (..)
  , IntentState (..)
  , Lease (..)
  , LookupTerms (..)
  , Observation (..)
  , Settlement (..)
  , effectSpecBudget
  , effectSpecClass
  , effectSpecTerms
  , intentStateName
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..))

data LookupResult
  = LookupFound T.Text
  | LookupNotFound
  | LookupFailed T.Text
  deriving (Eq, Show)

data ReconcileInput
  = ReconcileInput
  { reconcileNow :: UTCTime
  , reconcileLookup :: LookupResult
  }
  deriving (Eq, Show)

terminal :: IntentState -> Bool
terminal state =
  case state of
    IntentSettled _ -> True
    IntentAbandoned _ -> True
    _ -> False

{- | R3. Check order: an Agent; a settled or abandoned intent; the principal;
the class; the state (and a dispatched intent's lease); then the §3 table.
-}
reconcileIntent :: Intent -> Command ReconcileInput -> Either ReconcileRefusal Intent
reconcileIntent intent (Command principal input)
  | principal == Agent = Left ReconcileAgentAssertion
  | terminal (intentState intent) = Left ReconcileAlreadySettled
  | principal /= Supervisor = Left (ReconcileNotAuthorized principal)
  | otherwise =
      case effectSpecTerms (intentSpec intent) of
        TermsQueryable terms ->
          case intentState intent of
            IntentUnknown _ -> Right (decided terms)
            IntentDispatched lease
              | reconcileNow input < leaseUntil lease -> Left ReconcileLeaseActive
              | otherwise -> Right (decided terms)
            state -> Left (NothingToReconcile (intentStateName state))
        _ -> Left NotQueryable
 where
  decided terms =
    intent
      { intentState = reconciled terms (reconcileLookup input)
      , intentGeneration = intentGeneration intent + 1
      }

reconciled :: LookupTerms -> LookupResult -> IntentState
reconciled terms result =
  case result of
    LookupFound r -> IntentApplied r
    LookupNotFound
      | not (lookupAuthoritative terms) -> IntentUnknown (T.pack "lookup: not found, not authoritative")
      | not (lookupExcludesLateApplication terms) -> IntentUnknown (T.pack "lookup: not found, late application not excluded")
      | otherwise -> IntentNotApplied (T.pack "lookup: not found")
    LookupFailed r -> IntentUnknown (T.pack "lookup failed: " <> r)

data Resolution
  = AttestApplied T.Text
  | AttestNotApplied T.Text
  | RetryAcknowledgingDuplication Bool
  deriving (Eq, Show)

{- | R5. Check order: an Agent; a settled or abandoned intent; the principal
(a Human); the generation; an intent that is not unknown; then the choice.
-}
resolveIntent :: Intent -> Command (Int, Resolution) -> Either ReconcileRefusal Intent
resolveIntent intent (Command principal (generation, choice))
  | principal == Agent = Left ReconcileAgentAssertion
  | terminal (intentState intent) = Left ReconcileAlreadySettled
  | principal /= Human = Left (ReconcileNotAuthorized principal)
  | generation /= intentGeneration intent = Left ReconcileStaleClaim
  | otherwise =
      case intentState intent of
        IntentUnknown _ ->
          case choice of
            AttestApplied evidence
              | validEvidence evidence -> Right (to (IntentSettled (SettledApplied (attested evidence))))
              | otherwise -> Left InvalidEvidence
            AttestNotApplied evidence
              | not (validEvidence evidence) -> Left InvalidEvidence
              | intentDispatches intent <= effectSpecBudget (intentSpec intent) -> Right (to (IntentNotApplied (attested evidence)))
              | otherwise -> Right (to (IntentSettled (SettledNotApplied (attested evidence))))
            RetryAcknowledgingDuplication acknowledged
              | acknowledged -> Right (to IntentPending)
              | otherwise -> Left DuplicationNotAcknowledged
        state -> Left (NotUnknown (intentStateName state))
 where
  to state = intent {intentState = state}
  attested evidence = T.pack "human-attested: " <> evidence

validEvidence :: T.Text -> Bool
validEvidence text =
  not (T.null text) && T.length text <= 4096 && not (T.any Char.isControl text)

data LateVerdict
  = LateConsistent
  | LateConflict Intent
  deriving (Eq, Show)

{- | R7, §3: whether a refused applied observation contradicts the durable
state. An intent that could still run is made unknown, so it cannot be
dispatched again before a human resolves it.
-}
judgeLateObservation :: Intent -> Observation -> LateVerdict
judgeLateObservation intent observation =
  case observation of
    DestinationApplied _
      | conflicts -> LateConflict (blocked intent)
    _ -> LateConsistent
 where
  state = intentState intent
  saysNotApplied =
    case state of
      IntentNotApplied _ -> True
      IntentSettled (SettledNotApplied _) -> True
      IntentAbandoned _ -> True
      _ -> False
  recordsApplication =
    case state of
      IntentApplied _ -> True
      IntentSettled (SettledApplied _) -> True
      _ -> False
  conflicts =
    case effectSpecClass (intentSpec intent) of
      Repeatable -> saysNotApplied
      Idempotent -> saysNotApplied
      Queryable -> not recordsApplication
      Unqueryable -> not recordsApplication

blocked :: Intent -> Intent
blocked intent =
  case intentState intent of
    IntentPending -> late
    IntentClaimed _ -> late
    IntentDispatched _ -> late
    IntentNotApplied _ -> late
    _ -> intent
 where
  late = intent {intentState = IntentUnknown (T.pack "late-application")}

-- | §4: a lookup record's canonical text.
renderLookup :: LookupResult -> T.Text
renderLookup result =
  case result of
    LookupFound r -> T.pack "found result=" <> quoted r
    LookupNotFound -> T.pack "not-found"
    LookupFailed r -> T.pack "failed reason=" <> quoted r

-- | §4: a human record's canonical text.
renderResolution :: Resolution -> T.Text
renderResolution resolution =
  case resolution of
    AttestApplied e -> T.pack "attested-applied evidence=" <> quoted e
    AttestNotApplied e -> T.pack "attested-not-applied evidence=" <> quoted e
    RetryAcknowledgingDuplication True -> T.pack "retry duplication-acknowledged"
    RetryAcknowledgingDuplication False -> T.pack "retry duplication-not-acknowledged"

quoted :: T.Text -> T.Text
quoted text =
  T.pack "\"" <> T.concatMap escape text <> T.pack "\""
 where
  escape c =
    case c of
      '\\' -> T.pack "\\\\"
      '"' -> T.pack "\\\""
      _ -> T.singleton c

data ReconcileRefusal
  = ReconcileAgentAssertion
  | ReconcileAlreadySettled
  | ReconcileNotAuthorized Principal
  | NotQueryable
  | NothingToReconcile T.Text
  | ReconcileLeaseActive
  | ReconcileStaleClaim
  | NotUnknown T.Text
  | InvalidEvidence
  | DuplicationNotAcknowledged
  deriving (Eq, Show)

reconcileRefusalCode :: ReconcileRefusal -> T.Text
reconcileRefusalCode refusal =
  T.pack $
    case refusal of
      ReconcileAgentAssertion -> "agent-assertion"
      ReconcileAlreadySettled -> "already-settled"
      ReconcileNotAuthorized _ -> "not-authorized"
      NotQueryable -> "not-queryable"
      NothingToReconcile _ -> "nothing-to-reconcile"
      ReconcileLeaseActive -> "lease-active"
      ReconcileStaleClaim -> "stale-claim"
      NotUnknown _ -> "not-unknown"
      InvalidEvidence -> "invalid-evidence"
      DuplicationNotAcknowledged -> "duplication-risk-not-acknowledged"
