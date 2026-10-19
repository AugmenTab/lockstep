{- | The display status of an effect intent (contract C-P2.8 V1, §3; DG-04
binding requirement 6). One status per intent, by the first matching row of
the table. Only an application settled from the destination's own answer is
PASSED: a human attestation is ATTESTED, and an unknown or in-flight outcome is
never PASSED. The facts that are not in the intent itself (the time, whether
its Work Order is active, whether a human attested it) are inputs.
-}
module Lockstep.Kernel.EffectView
  ( EffectStatus (..)
  , StatusFacts (..)
  , effectStatus
  , effectStatusReason
  , effectStatusLabel
  , effectStatusClass
  ) where

import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Effect
  ( EffectClass (..)
  , Intent (..)
  , IntentState (..)
  , Lease (..)
  , Settlement (..)
  , effectSpecBudget
  , effectSpecClass
  )

data EffectStatus
  = StatusNotRun
  | StatusClaimed
  | StatusInProgress
  | StatusReconciliationNeeded
  | StatusUnknown
  | StatusBlocked
  | StatusNotApplied
  | StatusPassed
  | StatusAttested
  | StatusAbandoned
  deriving (Eq, Show, Enum, Bounded)

data StatusFacts
  = StatusFacts
  { factsNow :: UTCTime
  , factsOrderActive :: Bool
  , factsHumanAttested :: Bool
  }
  deriving (Eq, Show)

effectStatus :: StatusFacts -> Intent -> EffectStatus
effectStatus facts intent =
  fst (statusRow facts intent)

effectStatusReason :: StatusFacts -> Intent -> T.Text
effectStatusReason facts intent =
  snd (statusRow facts intent)

-- | §3, first matching row.
statusRow :: StatusFacts -> Intent -> (EffectStatus, T.Text)
statusRow facts intent =
  case intentState intent of
    IntentAbandoned r -> (StatusAbandoned, T.pack "abandoned: " <> r)
    IntentSettled (SettledApplied r)
      | factsHumanAttested facts -> (StatusAttested, T.pack "attested by a human, not observed: " <> r)
      | otherwise -> (StatusPassed, T.pack "applied: " <> r)
    IntentSettled (SettledNotApplied r) -> (StatusNotApplied, T.pack "not applied: " <> r)
    IntentApplied r -> (StatusInProgress, T.pack "applied, not yet settled: " <> r)
    IntentUnknown r
      | queryable -> (StatusReconciliationNeeded, T.pack "outcome unknown, a lookup may resolve it: " <> r)
      | otherwise -> (StatusUnknown, T.pack "outcome unknown, a human must resolve it: " <> r)
    IntentDispatched lease
      | factsNow facts >= leaseUntil lease -> (StatusReconciliationNeeded, holder "dispatched by " lease <> T.pack "; its lease ended without an answer")
      | otherwise -> (StatusInProgress, holder "dispatched by " lease)
    _ | not (factsOrderActive facts) -> (StatusBlocked, T.pack "the work order is not active")
    IntentClaimed lease
      | factsNow facts < leaseUntil lease -> (StatusClaimed, holder "claimed by " lease)
      | otherwise -> (StatusNotRun, T.pack "a claim by " <> leaseOwner lease <> T.pack " lapsed before dispatch")
    IntentPending -> (StatusNotRun, T.pack "not dispatched")
    IntentNotApplied r
      | intentDispatches intent <= effectSpecBudget (intentSpec intent) -> (StatusNotApplied, T.pack "not applied, a retry is left: " <> r)
      | otherwise -> (StatusNotApplied, T.pack "not applied, no retry left: " <> r)
 where
  queryable = effectSpecClass (intentSpec intent) == Queryable
  holder prefix lease =
    T.pack prefix <> leaseOwner lease <> T.pack (" (generation " <> show (leaseGeneration lease) <> ")")

effectStatusLabel :: EffectStatus -> T.Text
effectStatusLabel status =
  T.pack $
    case status of
      StatusNotRun -> "NOT_RUN"
      StatusClaimed -> "CLAIMED"
      StatusInProgress -> "IN_PROGRESS"
      StatusReconciliationNeeded -> "RECONCILIATION_NEEDED"
      StatusUnknown -> "UNKNOWN"
      StatusBlocked -> "BLOCKED"
      StatusNotApplied -> "NOT_APPLIED"
      StatusPassed -> "PASSED"
      StatusAttested -> "ATTESTED"
      StatusAbandoned -> "ABANDONED"

effectStatusClass :: EffectStatus -> T.Text
effectStatusClass status =
  T.pack "ls-effect-" <> T.map (\c -> if c == '_' then '-' else c) (T.toLower (effectStatusLabel status))
