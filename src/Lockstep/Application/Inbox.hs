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

import Control.Monad.Except (ExceptT (..), runExceptT)
import Data.List qualified as L
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Conversation (Channel (..), Conversation (..), Sender (..), StoredMessage, StoredRequest (..), conversation, openRequests, postMessage)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, withDatabase)
import Lockstep.Kernel.Conversation (RequestInput (HumanSays))
import Lockstep.Kernel.Identity (HumanRequestId (..), ProjectId, TaskId, WorkOrderId (..), parseIdentity)
import Lockstep.Kernel.Inbox (choiceConsequence, maxClarifications)
import Lockstep.Kernel.Transaction (Stage, TxState (..))
import Lockstep.Persistence.Clarification qualified as Clarifications
import Lockstep.Persistence.Execution qualified as Execution
import Lockstep.Persistence.Projects qualified as Projects
import Lockstep.Persistence.Tasks qualified as Tasks
import Lockstep.Persistence.Transactions qualified as Transactions

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
  , entryAcceptance :: T.Text
  , entryQuestion :: T.Text
  , entryStep :: Maybe Stage
  , entryChoices :: [InboxChoice]
  , entryMessages :: [StoredMessage]
  , entryAnswersLeft :: Int
  -- ^ How many more of the person's questions the Planner may still answer (C-P6.3 I6).
  }
  deriving (Eq, Show)

-- | The task, project, fix and attempts a request is about, read together.
data Facts
  = Facts Tasks.TaskRow Projects.ProjectRow (Maybe Transactions.TransactionRow) Int

{- | Every open Human Request about a handed-over task, oldest first. (Every
request the engine opens is about one; a request about a Work Order no task
was handed over for has no task or project to show and is not listed.)
-}
inboxEntries :: DatabaseRuntime -> IO (Either NotReadyReason [InboxEntry])
inboxEntries runtime =
  runExceptT $ do
    open <- ExceptT (openRequests runtime)
    catMaybes <$> traverse entryFor open
 where
  entryFor request =
    case (parseIdentity (storedWorkOrder request), parseIdentity (storedRequestId request)) of
      (Just workOrder, Just requestId) -> do
        facts <- ExceptT (withDatabase runtime (factsOf workOrder requestId))
        talk <- ExceptT (conversation runtime (storedRequestId request))
        pure $ do
          Facts task project fix attempts <- facts
          let
            step = fix >>= stepOf . Transactions.txRowState
          pure
            InboxEntry
              { entryRequest = storedRequestId request
              , entryRevision = storedRevision request
              , entryProject = Projects.rowId project
              , entryProjectName = Projects.rowName project
              , entryTask = Tasks.rowTaskId task
              , entryTaskTitle = Tasks.rowTitle task
              , entryAcceptance = Tasks.rowAcceptance task
              , entryQuestion = storedQuestion request
              , entryStep = step
              , entryChoices = [InboxChoice c (maybe unknownConsequence (`choiceConsequence` c) step) | c <- storedChoices request]
              , entryMessages = maybe [] conversationMessages talk
              , entryAnswersLeft = max 0 (maxClarifications - attempts)
              }
      _ -> pure Nothing
  unknownConsequence =
    T.pack "Lockstep cannot describe what this choice does."

factsOf :: WorkOrderId -> HumanRequestId -> O.Orville (Maybe Facts)
factsOf workOrder requestId = do
  admission <- Execution.findAdmissionByWorkOrder workOrder
  case admission of
    Nothing -> pure Nothing
    Just a -> do
      task <- Tasks.findTaskRow (Execution.admissionRowTask a)
      project <- Projects.findProjectById (Execution.admissionRowProject a)
      fix <- Transactions.findTransactionByWorkOrder workOrder
      attempts <- L.length <$> Clarifications.requestClarifications requestId
      pure (Facts <$> task <*> project <*> pure fix <*> pure attempts)

-- | The step a fix is at or stopped at.
stepOf :: TxState -> Maybe Stage
stepOf state =
  case state of
    Running stage -> Just stage
    Halted stage _ -> Just stage
    _ -> Nothing

-- | I3: a person's question about an open request, at its revision; it decides nothing.
askQuestion :: DatabaseRuntime -> IdempotencyKey -> T.Text -> Int -> T.Text -> IO (Either NotReadyReason (Either T.Text StoredMessage))
askQuestion runtime key request revision text =
  postMessage runtime key request (SenderHuman ApplicationChannel) (HumanSays revision text)
