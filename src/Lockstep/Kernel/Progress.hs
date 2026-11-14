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
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Task (TaskReadiness)
import Lockstep.Kernel.Transaction (Stage, TxState)

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

standingOf :: WorkFacts -> Standing
standingOf _ =
  StandingUnknown T.empty

standingCode :: Standing -> T.Text
standingCode _ =
  T.empty

-- | Whether the work was published. Phase 6 publishes nothing (P8), so there is one value.
data Publication
  = NotPublished
  deriving (Eq, Show)

publicationCode :: Publication -> T.Text
publicationCode _ =
  T.empty

{- | The task a person can hand over next: the highest priority among those
whose standing is ready, then the earliest in the given order. Never one that
waits, is blocked or is not ready, whatever its priority.
-}
nextToHandOver :: [(a, Int, Standing)] -> Maybe a
nextToHandOver _ =
  Nothing
