{- | A project's Progress page as data (contract C-P6.2 C1–C4): every task's
standing from canonical rows at render time, where it came from, what is next
to hand over, and who works where. Read only.
-}
module Lockstep.Application.Progress
  ( ProgressRow (..)
  , WhereItRuns (..)
  , Placement (..)
  , ProgressView (..)
  , loadProgress
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Application.Projects (ProjectFolders)
import Lockstep.Kernel.Identity (ProjectId, TaskId)
import Lockstep.Kernel.Progress (Publication, Standing)

data ProgressRow
  = ProgressRow
  { rowTask :: TaskId
  , rowTitle :: T.Text
  , rowPriority :: Int
  , rowSource :: Maybe T.Text
  -- ^ For an imported task: @provider locator key \@ revision@ (C-P6.1); Nothing for a task made in Lockstep.
  , rowStanding :: Standing
  , rowPublication :: Publication
  }
  deriving (Eq, Show)

-- | Who works in the project and under which checks, or why nobody does yet.
data WhereItRuns
  = RunsNowhere T.Text
  | RunsWith Placement
  deriving (Eq, Show)

-- | The project's enablement (C-P4.1): its Engineer, folder and checks.
data Placement
  = Placement
  { placementEngineer :: T.Text
  , placementFolder :: T.Text
  , placementChecks :: T.Text
  , placementChecksVersion :: Int
  , placementChecksDigest :: T.Text
  }
  deriving (Eq, Show)

data ProgressView
  = ProgressView
  { progressProject :: ProjectId
  , progressName :: T.Text
  , progressRows :: [ProgressRow]
  -- ^ In the project's task order (most important first, then the oldest).
  , progressNext :: Maybe TaskId
  , progressWhere :: WhereItRuns
  }
  deriving (Eq, Show)

-- | The project's progress; Nothing for an unknown project.
loadProgress :: DatabaseRuntime -> ProjectFolders -> T.Text -> IO (Either NotReadyReason (Maybe ProgressView))
loadProgress _ _ _ =
  pure (Right Nothing)
