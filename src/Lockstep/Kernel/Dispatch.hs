{- | The deterministic dispatcher's rules (contract C-P6.5 S1–S3, S7, S8):
when a prerequisite counts as satisfied, which unit of an approved plan is
handed over next and why each other unit waits, and the basis a dependent fix
starts from. Pure: the application reads the facts and does the hand-over.
-}
module Lockstep.Kernel.Dispatch
  ( -- * Prerequisites (S1)
    FixFact (..)
  , fixFactCode
  , PrerequisiteFact (..)
  , prerequisiteSatisfied
  , readinessWith

    -- * The decision (S2, S3, S7)
  , UnitFacts (..)
  , BudgetFact (..)
  , ProjectFacts (..)
  , WaitReason (..)
  , waitReasonCode
  , waitReasonWords
  , DispatchDecision (..)
  , dispatchDecision

    -- * The basis of a dependent fix (S8)
  , chooseBasis
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Plan (EdgeKind, UnitKey)
import Lockstep.Kernel.Task (TaskReadiness (..))

-- | Where a task's latest fix stands, as far as its dependents are concerned.
data FixFact
  = NoFix
  | -- | Handed over, running, or halted for a person's decision.
    FixUnderWay
  | -- | Verified, reviewed and committed on its work branch; not yet the person's Done.
    FixAccepted
  | -- | Accepted, but that acceptance no longer counts (P6.7).
    FixAcceptanceInvalidated
  | FixDone
  | FixStopped
  deriving (Eq, Show, Enum, Bounded)

fixFactCode :: FixFact -> T.Text
fixFactCode _ =
  T.empty

data PrerequisiteFact
  = PrerequisiteFact
  { prerequisiteTitle :: T.Text
  , prerequisiteTicketState :: T.Text
  , prerequisiteEdge :: Maybe EdgeKind
  -- ^ The plan edge's kind; Nothing for a task dependency outside a plan (untyped).
  , prerequisiteProvisional :: Bool
  -- ^ Whether the prerequisite's unit may satisfy technical edges before the person's Done.
  , prerequisiteFix :: FixFact
  }
  deriving (Eq, Show)

-- | S1.
prerequisiteSatisfied :: PrerequisiteFact -> Bool
prerequisiteSatisfied _ =
  False

{- | A task's readiness with S1: the task's state and block reason, and its
prerequisites. A satisfied prerequisite counts as finished; nothing else
changes ('Lockstep.Kernel.Task.taskReadiness').
-}
readinessWith :: T.Text -> Maybe T.Text -> [PrerequisiteFact] -> TaskReadiness
readinessWith _ _ _ =
  NotYetReady

-- | One unit of the effective revision, with its task's facts.
data UnitFacts
  = UnitFacts
  { unitFactKey :: UnitKey
  , unitFactTitle :: T.Text
  , unitFactPriority :: Int
  , unitFactOrdinal :: Int
  , unitFactReadiness :: TaskReadiness
  , unitFactHandedOver :: Maybe FixFact
  -- ^ Nothing while it was never handed over.
  , unitFactLocal :: Bool
  }
  deriving (Eq, Show)

-- | What is known of the plan's token budget.
data BudgetFact
  = NoBudget
  | -- | The plan has a budget and Lockstep does not record usage: unknown, never "available".
    UsageUnknown
  deriving (Eq, Show)

data ProjectFacts
  = ProjectFacts
  { projectEnabled :: Bool
  , projectWriter :: Maybe T.Text
  -- ^ The title of the task whose fix holds the repository's one writer.
  , projectBudget :: BudgetFact
  }
  deriving (Eq, Show)

data WaitReason
  = WaitingForPrerequisites [T.Text]
  | WriterBusy T.Text
  | ExecutionNotEnabled
  | UsageNotKnown
  | QueuedBehind T.Text
  | HandedOver
  | FinishedUnit
  | NotYetAccepted
  | BlockedUnit T.Text
  | CannotStartUnit [T.Text]
  | CanceledUnit
  | NotLocal
  | UnrecognisedState T.Text
  deriving (Eq, Show)

waitReasonCode :: WaitReason -> T.Text
waitReasonCode _ =
  T.empty

waitReasonWords :: WaitReason -> T.Text
waitReasonWords _ =
  T.empty

data DispatchDecision
  = DispatchDecision
  { decisionNext :: Maybe UnitKey
  , decisionWaiting :: [(UnitKey, WaitReason)]
  -- ^ Every other unit, in the plan's order.
  }
  deriving (Eq, Show)

-- | S2, S3: the one unit to hand over now, if any, and why each other unit waits.
dispatchDecision :: ProjectFacts -> [UnitFacts] -> DispatchDecision
dispatchDecision _ _ =
  DispatchDecision Nothing []

{- | S8: the basis among candidate accepted commits: the one that contains
every other (@isAncestor a b@: @a@ is an ancestor of, or equal to, @b@);
Nothing without candidates; Left @basis-ambiguous@ when none contains all.
-}
chooseBasis :: (T.Text -> T.Text -> Bool) -> [T.Text] -> Either T.Text (Maybe T.Text)
chooseBasis _ _ =
  Right Nothing
