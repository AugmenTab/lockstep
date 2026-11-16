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
  , AttemptView (..)
  , requestAttempts
  , RequestRecord (..)
  , requestsOfTask
  , recentRequests
  ) where

import Control.Monad.Except (ExceptT (..), runExceptT)
import Data.List qualified as L
import Data.Maybe (catMaybes, isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Conversation (Channel (..), Conversation (..), Sender (..), StoredMessage, StoredRequest (..), conversation, openRequests, postMessage)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, withDatabase)
import Lockstep.Application.Invalidations (invalidationOf)
import Lockstep.Kernel.Conversation (RequestInput (HumanSays))
import Lockstep.Kernel.Identity (HumanRequestId (..), ProjectId, TaskId (..), WorkOrderId (..), identityText, parseIdentity)
import Lockstep.Kernel.Inbox (RequestFacts (..), RequestStanding, choiceConsequence, maxClarifications, requestStanding)
import Lockstep.Kernel.Transaction (RecordKind (..), Stage, TxState (..))
import Lockstep.Persistence.Clarification qualified as Clarifications
import Lockstep.Persistence.Conversation qualified as Conversations
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
  , entryEvidence :: T.Text
  , entryHalt :: Maybe T.Text
  -- ^ The code the fix stopped for (R-P6.3-1).
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
              , entryEvidence = storedEvidence request
              , entryHalt =
                  case Transactions.txRowState <$> fix of
                    Just (Halted _ code) -> Just code
                    _ -> Nothing
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
      -- R-P6.3-5: only attempts that ran count; one without a helper ran nothing.
      attempts <- L.length . L.filter ran <$> Clarifications.requestClarifications requestId
      pure (Facts <$> task <*> project <*> pure fix <*> pure attempts)
 where
  ran r =
    Clarifications.clarificationOutcome r /= Just (Clarifications.clarificationEndingCode Clarifications.EndedNoHelper)

-- | One attempt to answer a question, for the task page (R-P6.3-6).
data AttemptView
  = AttemptView
  { attemptQuestion :: Int
  -- ^ The question's message sequence.
  , attemptOutcome :: Maybe T.Text
  -- ^ @answered@, @failed@, @no-helper@ or @uncertain@; Nothing while it runs.
  }
  deriving (Eq, Show)

-- | The attempts made on a request's questions, in question order.
requestAttempts :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason [AttemptView])
requestAttempts runtime rawRequest =
  case parseIdentity rawRequest of
    Nothing -> pure (Right [])
    Just requestId ->
      withDatabase runtime $
        fmap (\r -> AttemptView (fromIntegral (Clarifications.clarificationSequence r)) (Clarifications.clarificationOutcome r))
          <$> Clarifications.requestClarifications requestId

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

-- | Update 2 R6.3: one Human Request about a task, as a record, with where it stands.
data RequestRecord
  = RequestRecord
  { recordRequest :: T.Text
  , recordTask :: TaskId
  , recordTaskTitle :: T.Text
  , recordProjectName :: T.Text
  , recordQuestion :: T.Text
  , recordStanding :: RequestStanding
  , recordNote :: Maybe T.Text
  -- ^ The Supervisor's withdrawal message, when it was withdrawn.
  }
  deriving (Eq, Show)

{- | Update 2 R6.3: every Human Request about the task's fixes (each of its
hand-overs), oldest first, with where each stands. Nothing is left out: a
request that no longer decides anything is shown as such.
-}
requestsOfTask :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text [RequestRecord]))
requestsOfTask runtime rawId =
  case parseIdentity rawId of
    Nothing -> pure (Right (Left (T.pack "unknown-task")))
    Just tid ->
      withDatabase runtime $ do
        admissions <- Execution.taskAdmissions tid
        rows <- L.concat <$> traverse (Conversations.requestsForWorkOrder . Execution.admissionRowWorkOrder) admissions
        Right . catMaybes <$> traverse recordOf rows

-- | Update 2 R6.3: the requests that are closed (answered or withdrawn), most recently changed first, at most 30.
recentRequests :: DatabaseRuntime -> IO (Either NotReadyReason [RequestRecord])
recentRequests runtime =
  withDatabase runtime $ do
    rows <- Conversations.closedRequestRows 30
    catMaybes <$> traverse recordOf rows

-- | A request about a handed-over task as a record; Nothing for one about no task.
recordOf :: Conversations.RequestRow -> O.Orville (Maybe RequestRecord)
recordOf row = do
  let
    workOrder = Conversations.requestRowWorkOrder row
    requestId = Conversations.requestRowId row
  admission <- Execution.findAdmissionByWorkOrder workOrder
  case admission of
    Nothing -> pure Nothing
    Just a -> do
      task <- Tasks.findTaskRow (Execution.admissionRowTask a)
      project <- Projects.findProjectById (Execution.admissionRowProject a)
      fix <- Transactions.findTransactionByWorkOrder workOrder
      messages <- Conversations.requestMessages requestId
      siblings <- Conversations.requestsForWorkOrder workOrder
      invalid <- maybe (pure Nothing) (invalidationOf . Transactions.txRowId) fix
      records <- maybe (pure []) (Transactions.transactionRecords . Transactions.txRowId) fix
      let
        idText = identityText requestId
        newest = fmap (Conversations.requestRowId . fst) (L.uncons (L.reverse siblings))
        halted =
          case Transactions.txRowState <$> fix of
            Just (Halted _ _) -> True
            _ -> False
        ended =
          case Transactions.txRowState <$> fix of
            Just (Stopped _) -> True
            Just Accepted -> True
            Just Done -> True
            _ -> False
        facts =
          RequestFacts
            { requestFactState = Conversations.requestRowState row
            , requestFactWithdrawal = Conversations.messageRowBody <$> L.find ((== T.pack "withdrawal") . Conversations.messageRowKind) (L.reverse messages)
            , requestFactFixInvalidated = isJust invalid
            , requestFactCurrent = halted && newest == Just requestId
            , -- R-U2-6: also when the fix has ended since (stopped, accepted or Done): nothing waits on the answer.
              requestFactActedOn = ended || L.any (\r -> Transactions.recordRowKind r == RecordResume && idText `T.isInfixOf` Transactions.recordRowBody r) records
            }
      pure $
        ( \t p ->
            RequestRecord
              { recordRequest = idText
              , recordTask = Tasks.rowTaskId t
              , recordTaskTitle = Tasks.rowTitle t
              , recordProjectName = Projects.rowName p
              , recordQuestion = Conversations.requestRowQuestion row
              , recordStanding = requestStanding facts
              , recordNote = requestFactWithdrawal facts
              }
        )
          <$> task
          <*> project
