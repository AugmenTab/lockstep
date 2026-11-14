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

import Control.Monad.Except (ExceptT (..), runExceptT)
import Data.List qualified as L
import Data.Maybe (isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Application.Backlog (TaskSource (..), taskSources)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, withDatabase)
import Lockstep.Application.Execution (Admission (..), Enablement (..), ExecutionStatus (..), executionStatus, findAdmission)
import Lockstep.Application.Projects (ProjectFolders, ProjectView (..), findProject)
import Lockstep.Application.Tasks (TaskView (..), listTasks)
import Lockstep.Kernel.Backlog (sourceProviderCode)
import Lockstep.Kernel.Identity (ProjectId, TaskId, WorkOrderId (..), parseIdentity)
import Lockstep.Kernel.Progress (Publication (..), Standing, WorkFacts (..), nextToHandOver, standingOf)
import Lockstep.Persistence.Transactions qualified as Transactions

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

{- | The project's progress; Nothing for an unknown project. Every task is read
from its canonical rows now: its Ticket's state and dependencies (C-P3.6), its
hand-over (C-P4.1), its fix's state and accepted commit (C-P4.6), its
provenance (C-P6.1). A task never drops out: one that cannot be read is
@unknown@ (and a Ticket that does not replay aborts the read, as on every
other page).
-}
loadProgress :: DatabaseRuntime -> ProjectFolders -> T.Text -> IO (Either NotReadyReason (Maybe ProgressView))
loadProgress runtime folders rawProject = do
  found <- findProject runtime rawProject
  case found of
    Left reason -> pure (Left reason)
    Right Nothing -> pure (Right Nothing)
    Right (Just project) -> runExceptT $ do
      tasks <- ExceptT (listTasks runtime (projectId project))
      sources <- ExceptT (taskSources runtime (projectId project))
      status <- ExceptT (executionStatus runtime folders (projectId project))
      rows <- traverse (rowFor sources) tasks
      pure . Just $
        ProgressView
          { progressProject = projectKey project
          , progressName = projectName project
          , progressRows = rows
          , progressNext = nextToHandOver [(rowTask r, rowPriority r, rowStanding r) | r <- rows]
          , progressWhere = whereItRuns status
          }
 where
  rowFor sources t = do
    admission <- ExceptT (findAdmission runtime (taskId t))
    fix <-
      case admission >>= parseIdentity . admissionWorkOrder of
        Nothing -> pure Nothing
        Just workOrder -> ExceptT (withDatabase runtime (Transactions.findTransactionByWorkOrder workOrder))
    let
      facts =
        WorkFacts
          { factReadiness = taskReadinessOf t
          , factHandedOver = isJust admission
          , factFix = Transactions.txRowState <$> fix
          , factAcceptedCommit = fix >>= Transactions.txRowAccepted
          }
    pure
      ProgressRow
        { rowTask = taskKey t
        , rowTitle = taskTitle t
        , rowPriority = taskPriority t
        , rowSource = sourceText <$> L.find ((== taskKey t) . taskSourceTask) sources
        , rowStanding = standingOf facts
        , rowPublication = NotPublished
        }
  sourceText s =
    T.unwords
      [ sourceProviderCode (taskSourceProvider s)
      , taskSourceLocator s
      , taskSourceKey s
      , T.pack "@"
      , T.pack (show (taskSourceRevision s))
      ]

-- | C4: who works where, or why nobody does yet, in the project page's own words.
whereItRuns :: Maybe ExecutionStatus -> WhereItRuns
whereItRuns status =
  case status of
    Just (Enabled e) ->
      RunsWith
        Placement
          { placementEngineer = enablementEngineer e
          , placementFolder = enablementFolder e
          , placementChecks = enablementChecks e
          , placementChecksVersion = enablementChecksVersion e
          , placementChecksDigest = enablementChecksDigest e
          }
    Just NeedsFolder -> RunsNowhere (T.pack "Lockstep may not work in this project yet: it has no folder.")
    Just FolderReadOnly -> RunsNowhere (T.pack "Lockstep may not work in this project: its folder was added from elsewhere and is only read.")
    Just (NotEnabled _) -> RunsNowhere (T.pack "Lockstep may not work in this project yet: you have not allowed it on the project's page.")
    Nothing -> RunsNowhere (T.pack "Lockstep could not tell whether it may work in this project.")
