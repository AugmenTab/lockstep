{- | Where each piece of a project's work stands (contract C-P6.2 C1–C3): one
typed standing per task, decided from its readiness (C-P3.6), whether it was
handed over (C-P4.1) and its fix's state (C-P4.6). Technical acceptance, a
person's Done and publication stay distinct. Pure.
-}
module Lockstep.Kernel.Progress
  ( WorkFacts (..)
  , Standing (..)
  , standingOf
  , standingCode
  , Publication (..)
  , publicationCode
  , nextToHandOver
  , explainWaiting
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Task (TaskReadiness (..), mostImportantReady)
import Lockstep.Kernel.Transaction (Stage, TxState (..))

data WorkFacts
  = WorkFacts
  { factReadiness :: TaskReadiness
  , factHandedOver :: Bool
  , factFix :: Maybe TxState
  , factAcceptedCommit :: Maybe T.Text
  }
  deriving (Eq, Show)

data Standing
  = StandingProposed
  | StandingReady
  | -- | The unfinished tasks it needs, by title.
    StandingWaiting [T.Text]
  | StandingBlocked T.Text
  | -- | Tasks it needs that were canceled.
    StandingCannotStart [T.Text]
  | StandingQueued
  | StandingActive Stage
  | -- | Its fix stopped at this step for a person, with the halt code.
    StandingWaitingForYou Stage T.Text
  | -- | Checked and committed locally by the Supervisor (the commit, when known); not Done.
    StandingTechnicallyVerified (Maybe T.Text)
  | StandingHumanDone
  | StandingStopped T.Text
  | StandingCanceled
  | -- | A state Lockstep does not recognise (its name).
    StandingUnknown T.Text
  deriving (Eq, Show)

{- | C1's precedence: canceled; then the fix's state; then a Done task; then
handed over (queued); otherwise the task's readiness.
-}
standingOf :: WorkFacts -> Standing
standingOf f =
  case (factReadiness f, factFix f) of
    (TaskCanceled, _) -> StandingCanceled
    (_, Just fix) ->
      case fix of
        Done -> StandingHumanDone
        Accepted -> StandingTechnicallyVerified (factAcceptedCommit f)
        Halted stage code -> StandingWaitingForYou stage code
        Stopped code -> StandingStopped code
        Running stage -> StandingActive stage
    (Finished, Nothing) -> StandingHumanDone
    (_, Nothing) | factHandedOver f -> StandingQueued
    (readiness, Nothing) ->
      case readiness of
        NotYetReady -> StandingProposed
        ReadyToWork -> StandingReady
        WaitingFor titles -> StandingWaiting titles
        BlockedBecause reason -> StandingBlocked reason
        CannotStart titles -> StandingCannotStart titles
        -- Under way with no fix of its own: not handed over through Lockstep, so it is not shown as active.
        BeingWorkedOn -> StandingQueued
        StateUnrecognised name -> StandingUnknown name

-- | The standing's stable code (the page's @data-standing@).
standingCode :: Standing -> T.Text
standingCode standing =
  T.pack $
    case standing of
      StandingProposed -> "proposed"
      StandingReady -> "ready"
      StandingWaiting _ -> "waiting"
      StandingBlocked _ -> "blocked"
      StandingCannotStart _ -> "cannot-start"
      StandingQueued -> "queued"
      StandingActive _ -> "active"
      StandingWaitingForYou _ _ -> "waiting-for-you"
      StandingTechnicallyVerified _ -> "technically-verified"
      StandingHumanDone -> "human-done"
      StandingStopped _ -> "stopped"
      StandingCanceled -> "canceled"
      StandingUnknown _ -> "unknown"

-- | Whether the work was published. Phase 6 publishes nothing (P8), so there is one value.
data Publication
  = NotPublished
  deriving (Eq, Show)

publicationCode :: Publication -> T.Text
publicationCode NotPublished =
  T.pack "not-published"

{- | R-P6.2-1: a waiting task names, for each task it waits for, what that task's
own standing says when it looks finished but is not closed (its fix Done or
technically verified while its task stays open), so the page never shows one
task Done and another waiting on it without saying why.
-}
explainWaiting :: [(T.Text, Standing)] -> Standing -> Standing
explainWaiting _ =
  id

{- | The task a person can hand over next: the highest priority among those
whose standing is ready, then the earliest in the given order. Never one that
waits, is blocked or is not ready, whatever its priority.
-}
nextToHandOver :: [(a, Int, Standing)] -> Maybe a
nextToHandOver tasks =
  mostImportantReady [(a, priority, order, if standing == StandingReady then ReadyToWork else NotYetReady) | (order, (a, priority, standing)) <- L.zip [0 :: Int ..] tasks]
