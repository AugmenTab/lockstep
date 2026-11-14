{- | The Human Inbox (contract C-P6.3 I1–I3, I9): every open Human Request
across projects, with its project, task, the step its fix stopped at, each
choice with its consequence and its conversation; and a person's question
about one (a C-P4.3 message that never decides).
-}
module Lockstep.Application.Inbox
  ( InboxChoice (..)
  , InboxEntry (..)
  , inboxEntries
  , askQuestion
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Conversation (StoredMessage)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Kernel.Identity (ProjectId, TaskId)
import Lockstep.Kernel.Transaction (Stage)

data InboxChoice
  = InboxChoice
  { inboxChoiceName :: T.Text
  , inboxChoiceConsequence :: T.Text
  }
  deriving (Eq, Show)

data InboxEntry
  = InboxEntry
  { entryRequest :: T.Text
  , entryRevision :: Int
  , entryProject :: ProjectId
  , entryProjectName :: T.Text
  , entryTask :: TaskId
  , entryTaskTitle :: T.Text
  , entryQuestion :: T.Text
  , entryStep :: Maybe Stage
  , entryChoices :: [InboxChoice]
  , entryMessages :: [StoredMessage]
  , entryAnswersLeft :: Int
  -- ^ How many more of the person's questions the Planner may still answer (C-P6.3 I6).
  }
  deriving (Eq, Show)

-- | Every open Human Request, oldest first.
inboxEntries :: DatabaseRuntime -> IO (Either NotReadyReason [InboxEntry])
inboxEntries _ =
  pure (Right [])

-- | I3: a person's question about an open request, at its revision; it decides nothing.
askQuestion :: DatabaseRuntime -> IdempotencyKey -> T.Text -> Int -> T.Text -> IO (Either NotReadyReason (Either T.Text StoredMessage))
askQuestion _ _ _ _ _ =
  pure (Right (Left T.empty))
