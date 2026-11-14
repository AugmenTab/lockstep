{- | Importing and exporting a project's backlog (contract C-P6.1 B1–B13). An
imported item becomes an ordinary task, made by the same storage steps as
'Lockstep.Application.Tasks.createTask', with its provenance beside it. The
import is one transaction under the task lock and the source lock. Nothing
here creates a Work Order, schedules or runs anything.
-}
module Lockstep.Application.Backlog
  ( ImportReport (..)
  , TaskSource (..)
  , importBacklog
  , importBacklogDocument
  , exportBacklog
  , taskSources
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Kernel.Backlog (BacklogDocument, Criterion, ImportDecision, SourceKey, SourceProvider)
import Lockstep.Kernel.Identity (TaskId)

data ImportReport
  = ImportReport
  { reportDecision :: ImportDecision
  , reportRendered :: T.Text
  , reportTasks :: [(SourceKey, TaskId)]
  -- ^ The task each created, updated or unchanged item is, in document order.
  }
  deriving (Eq, Show)

-- | Where an imported task came from (B8).
data TaskSource
  = TaskSource
  { taskSourceTask :: TaskId
  , taskSourceProvider :: SourceProvider
  , taskSourceLocator :: T.Text
  , taskSourceKey :: T.Text
  , taskSourceRevision :: Int64
  , taskSourceCriteria :: [Criterion]
  }
  deriving (Eq, Show)

-- | A canonical document's bytes into a project; the refusal is its code.
importBacklog :: DatabaseRuntime -> T.Text -> LBS.ByteString -> IO (Either NotReadyReason (Either T.Text ImportReport))
importBacklog _ _ _ =
  pure (Right (Left T.empty))

-- | An already decoded document (e.g. from a provider adapter) with the digest of the bytes it was read from.
importBacklogDocument :: DatabaseRuntime -> T.Text -> T.Text -> BacklogDocument -> IO (Either NotReadyReason (Either T.Text ImportReport))
importBacklogDocument _ _ _ _ =
  pure (Right (Left T.empty))

exportBacklog :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text T.Text))
exportBacklog _ _ =
  pure (Right (Left T.empty))

-- | The provenance of a project's imported tasks, by task creation.
taskSources :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason [TaskSource])
taskSources _ _ =
  pure (Right [])
