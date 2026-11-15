{- | A project's evidence-linked summary (contract C-P6.8). Stub (the freeze's
RED baseline): nothing is read.
-}
module Lockstep.Application.Summary
  ( SummaryItem (..)
  , InterventionItem (..)
  , ProjectSummary (..)
  , projectSummary
  , usageFromOutput
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Kernel.Summary (Category, Checks, Evidence, Intervention, ReviewOutcome, Usage, noUsage)

data SummaryItem
  = SummaryItem
  { summaryTask :: T.Text
  , summaryTitle :: T.Text
  , summaryCategory :: Category
  , summaryChecks :: Checks
  , summaryReview :: ReviewOutcome
  , summaryCommit :: Maybe T.Text
  , summaryPublication :: T.Text
  , summaryEvidence :: [Evidence]
  }
  deriving (Eq, Show)

data InterventionItem
  = InterventionItem
  { interventionTask :: T.Text
  , interventionWhat :: T.Text
  , interventionKind :: Intervention
  , interventionEvidence :: Evidence
  }
  deriving (Eq, Show)

data ProjectSummary
  = ProjectSummary
  { summaryRevision :: Maybe T.Text
  , summaryItems :: [SummaryItem]
  , summaryPending :: [(T.Text, Evidence)]
  , summaryInterventions :: [InterventionItem]
  , summaryUsage :: Usage
  , summaryRuns :: Int
  , summaryRunsUnknown :: Int
  , summaryConstraints :: [(T.Text, T.Text)]
  }
  deriving (Eq, Show)

projectSummary :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe ProjectSummary))
projectSummary _ _ =
  pure (Right Nothing)

usageFromOutput :: T.Text -> Usage
usageFromOutput _ =
  noUsage
