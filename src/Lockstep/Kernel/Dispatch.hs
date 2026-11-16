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

    -- * The authoritative basis (Update 2 R6.1)
  , BasisSource (..)
  , basisCommits
  ) where

import Data.List qualified as L
import Data.Maybe (isNothing, listToMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Plan (EdgeKind (Technical), UnitKey)
import Lockstep.Kernel.Task (DependencyFact (..), TaskFacts (..), TaskReadiness (..), taskReadiness)

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
fixFactCode f =
  T.pack $
    case f of
      NoFix -> "none"
      FixUnderWay -> "under-way"
      FixAccepted -> "accepted"
      FixAcceptanceInvalidated -> "acceptance-invalidated"
      FixDone -> "done"
      FixStopped -> "stopped"

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
prerequisiteSatisfied p =
  prerequisiteTicketState p == T.pack "done"
    || prerequisiteFix p == FixDone
    || ( prerequisiteFix p == FixAccepted
           && prerequisiteEdge p == Just Technical
           && prerequisiteProvisional p
       )

{- | A task's readiness with S1: the task's state and block reason, and its
prerequisites. A satisfied prerequisite counts as finished; nothing else
changes ('Lockstep.Kernel.Task.taskReadiness').
-}
readinessWith :: T.Text -> Maybe T.Text -> [PrerequisiteFact] -> TaskReadiness
readinessWith state reason prerequisites =
  taskReadiness (TaskFacts state reason (fmap fact prerequisites))
 where
  canceled = T.pack "canceled"
  fact p =
    DependencyFact
      (prerequisiteTitle p)
      ( if prerequisiteTicketState p /= canceled && prerequisiteSatisfied p
          then T.pack "done"
          else prerequisiteTicketState p
      )

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
  | -- | R-P6.5-5: its fix was stopped; it is never handed over again.
    StoppedUnit
  | -- | R-P6.5-6: its hand-over was refused, with the refusal's code; it is tried again on each pass.
    RefusedHandOver T.Text
  | -- | C-P6.7 V3: its accepted fix no longer counts; it must be redone.
    InvalidatedUnit
  deriving (Eq, Show)

waitReasonCode :: WaitReason -> T.Text
waitReasonCode r =
  T.pack $
    case r of
      WaitingForPrerequisites _ -> "waiting-for"
      WriterBusy _ -> "writer-busy"
      ExecutionNotEnabled -> "execution-not-enabled"
      UsageNotKnown -> "usage-unknown"
      QueuedBehind _ -> "queued-behind"
      HandedOver -> "handed-over"
      FinishedUnit -> "finished"
      NotYetAccepted -> "not-ready"
      BlockedUnit _ -> "blocked"
      CannotStartUnit _ -> "cannot-start"
      CanceledUnit -> "canceled"
      NotLocal -> "not-local"
      UnrecognisedState _ -> "unknown"
      StoppedUnit -> "stopped"
      RefusedHandOver _ -> "refused"
      InvalidatedUnit -> "invalidated"

waitReasonWords :: WaitReason -> T.Text
waitReasonWords r =
  case r of
    WaitingForPrerequisites titles -> T.pack "Waiting for: " <> T.intercalate (T.pack ", ") titles <> T.pack "."
    WriterBusy title -> T.pack "Waiting: Lockstep is working on " <> title <> T.pack " in this project's folder, and works on one thing there at a time."
    ExecutionNotEnabled -> T.pack "Waiting: Lockstep may not work in this project yet."
    UsageNotKnown -> T.pack "Waiting: this plan limits model usage, and Lockstep does not record usage yet, so it cannot tell whether the limit allows more work."
    QueuedBehind title -> T.pack "Ready; it comes after " <> title <> T.pack "."
    HandedOver -> T.pack "Handed over: its fix is under way, waiting for you, or checked and waiting for your Done."
    FinishedUnit -> T.pack "Finished."
    NotYetAccepted -> T.pack "Not yet ready to work on."
    BlockedUnit reason -> T.pack "Blocked: " <> reason
    CannotStartUnit titles -> T.pack "Cannot start: a task it needs was canceled (" <> T.intercalate (T.pack ", ") titles <> T.pack ")."
    CanceledUnit -> T.pack "Canceled."
    NotLocal -> T.pack "Not handed over: it has effects outside this computer, which no plan may have yet."
    UnrecognisedState name -> T.pack "Lockstep cannot tell where this stands (" <> name <> T.pack ")."
    StoppedUnit -> T.pack "Stopped: its fix was stopped, so Lockstep will not work on it again by itself. To redo it, hand it over again; or cancel its task, or change the plan. Work that needs it waits."
    RefusedHandOver code -> T.pack "Lockstep could not hand it over (" <> code <> T.pack "); it tries again on each pass."
    InvalidatedUnit -> T.pack "Its accepted fix no longer counts: something it was built on was rejected, or the plan changed. It must be redone: stop its fix if it has not stopped, then hand it over again."

data DispatchDecision
  = DispatchDecision
  { decisionNext :: Maybe UnitKey
  , decisionWaiting :: [(UnitKey, WaitReason)]
  -- ^ Every other unit, in the plan's order.
  }
  deriving (Eq, Show)

-- | S2, S3: the one unit to hand over now, if any, and why each other unit waits.
dispatchDecision :: ProjectFacts -> [UnitFacts] -> DispatchDecision
dispatchDecision project units =
  DispatchDecision
    { decisionNext = fmap unitFactKey next
    , decisionWaiting =
        [ (unitFactKey u, reason)
        | u <- ordered
        , Just reason <- [waitOf u]
        ]
    }
 where
  ordered = L.sortOn (\u -> (unitFactOrdinal u, unitFactKey u)) units
  own u =
    case (unitFactHandedOver u, unitFactReadiness u) of
      (Just FixDone, _) -> Just FinishedUnit
      (Just FixStopped, _) -> Just StoppedUnit
      (Just FixAcceptanceInvalidated, _) -> Just InvalidatedUnit
      (Just _, _) -> Just HandedOver
      (Nothing, ReadyToWork) -> Nothing
      (Nothing, NotYetReady) -> Just NotYetAccepted
      (Nothing, WaitingFor titles) -> Just (WaitingForPrerequisites titles)
      (Nothing, BlockedBecause why) -> Just (BlockedUnit why)
      (Nothing, CannotStart titles) -> Just (CannotStartUnit titles)
      (Nothing, Finished) -> Just FinishedUnit
      (Nothing, TaskCanceled) -> Just CanceledUnit
      (Nothing, BeingWorkedOn) -> Just HandedOver
      (Nothing, StateUnrecognised name) -> Just (UnrecognisedState name)
  -- The project's own conditions, in a fixed order; each holds every otherwise eligible unit.
  projectReason
    | not (projectEnabled project) = Just ExecutionNotEnabled
    | projectBudget project == UsageUnknown = Just UsageNotKnown
    | otherwise = fmap WriterBusy (projectWriter project)
  candidateReason u
    | not (unitFactLocal u) = Just NotLocal
    | otherwise = projectReason
  eligible = [u | u <- units, isNothing (own u), isNothing (candidateReason u)]
  next = listToMaybe (L.sortOn (\u -> (negate (unitFactPriority u), unitFactOrdinal u, unitFactKey u)) eligible)
  waitOf u
    | Just u' <- next, unitFactKey u' == unitFactKey u = Nothing
    | Just r <- own u = Just r
    | Just r <- candidateReason u = Just r
    | otherwise = Just (QueuedBehind (maybe T.empty unitFactTitle next))

{- | S8: the basis among candidate accepted commits: the one that contains
every other (@isAncestor a b@: @a@ is an ancestor of, or equal to, @b@);
Nothing without candidates; Left @basis-ambiguous@ when none contains all.
-}
chooseBasis :: (T.Text -> T.Text -> Bool) -> [T.Text] -> Either T.Text (Maybe T.Text)
chooseBasis isAncestor candidates =
  case L.nub candidates of
    [] -> Right Nothing
    distinct ->
      case [c | c <- distinct, L.all (`isAncestor` c) distinct] of
        c : _ -> Right (Just c)
        [] -> Left (T.pack "basis-ambiguous")

-- | Update 2 R6.1: what one prerequisite of a dependent fix gives its basis.
data BasisSource
  = BasisSource
  { sourceSatisfied :: Bool
  -- ^ S1, and the prerequisite was not canceled.
  , sourceFix :: FixFact
  -- ^ Where its latest fix stands.
  , sourceCommit :: Maybe T.Text
  -- ^ That fix's accepted commit, when it has one.
  }
  deriving (Eq, Show)

-- | Update 2 R6.1 (stub).
basisCommits :: Bool -> [BasisSource] -> Either T.Text [T.Text]
basisCommits _ _ =
  Left (T.pack "not-implemented")
