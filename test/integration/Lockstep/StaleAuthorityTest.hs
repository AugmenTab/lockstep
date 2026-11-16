{-# LANGUAGE OverloadedStrings #-}

{- | Update 2 R6.3, stale authority and cancellation, against real PostgreSQL,
Git and processes with scripted roles. When an accepted ancestor is rejected,
the open requests of every fix it invalidates lose their authority in the same
transaction: they are withdrawn as invalidated, kept as records, and a late
answer is refused without touching the fix; an unrelated request stays
actionable; the fix's fresh Stop-only request is a new request. A request left
open by an older database is withdrawn as superseded by the next halt, so a
restart never revives it. A person's cancel of a task whose fix is live stops
the fix at a safe point first and only then cancels the task; an uncertain
outcome waits for the person; an accepted fix is never canceled silently.
-}
module Lockstep.StaleAuthorityTest
  ( tests
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (SomeException, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (doesFileExist)
import System.IO (FilePath)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Cancellation (CancelOutcome (..), CancellationView (..), cancellationOf, requestCancel)
import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Conversation (Channel (..), Conversation (..), Sender (..), StoredMessage (..), StoredRequest (..), conversation, openRequests, postMessage)
import Lockstep.Application.Engine (TransactionView (..), decideCompletion)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (admitBug)
import Lockstep.Application.Inbox (RequestRecord (..), requestsOfTask)
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask, findTask)
import Lockstep.Kernel.Conversation (RequestInput (..))
import Lockstep.Kernel.Inbox (RequestStanding (..))
import Lockstep.Kernel.Plan (EdgeKind (..), PlanEdge (..), PlanMode (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Support.Postgres (adminExecute, databaseConfigFor, withRuntime)
import Lockstep.Support.Scheduling (Scenario (..), Scripts (..), accepted, acceptedCount, approveIn, count, engineFor, fixOfTask, folders, idemWith, k, markReady, passesUntil, planOf, projectWith, ready, refusedWith, review, tasksOf, valueFiles, valueScripts, valueTitle, valueUnit, withScenario)

tests :: TestTree
tests =
  testGroup
    "R6.3 stale authority and cancellation (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "rejecting an ancestor withdraws its descendants' open requests as invalidated, in the same transaction; a late answer is refused; an unrelated request stays; the fresh request is new; replays and restarts change nothing (R6.3)" rejectionWithdraws
    , testCase "a request an older database left open is superseded by the next halt, never revived by a restart (R6.3)" legacyOpenSuperseded
    , testCase "cancel of a task whose fix waits for a person: the fix stops first, its request is withdrawn, then the task is canceled (R6.3)" cancelHalted
    , testCase "cancel of a task handed over but not started: stopped before any stage runs, then canceled (R6.3)" cancelBeforeStart
    , testCase "cancel while a helper's outcome is uncertain: nothing is settled until the person decides; the uncertainty stays recorded (R6.3)" cancelUncertain
    , testCase "an accepted fix is never canceled silently: cancel is refused until the person decides Done or Not done (R6.3)" cancelAccepted
    ]

-- Fixtures ---------------------------------------------------------------------------------------

prefix :: T.Text
prefix =
  "test-stale-authority-"

idem :: T.Text -> IO IdempotencyKey
idem =
  idemWith prefix

project :: Scenario -> T.Text -> IO (ProjectView, FilePath)
project sc name =
  projectWith sc prefix name (valueFiles 3) True

-- | A plain task "Make fN return N", ready and handed over by the person; its id.
plainTask :: Scenario -> ProjectView -> Int -> IO T.Text
plainTask sc view n = do
  tk <- idem ("task-" <> T.pack (show n) <> "-" <> projectName view)
  t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) (valueTitle n) ("f" <> T.pack (show n) <> ".value() is " <> T.pack (show n) <> ".") Normal [])))
  tReady <- markReady sc t
  ak <- idem ("admit-" <> T.pack (show n) <> "-" <> projectName view)
  _ <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId tReady) (taskTicketRevision tReady)))
  pure (taskId t)

taskTitled :: Scenario -> ProjectView -> T.Text -> IO TaskView
taskTitled sc view title = do
  ts <- tasksOf sc view
  maybe (assertFailure ("no task " <> T.unpack title)) pure (L.find ((== title) . taskTitle) ts)

-- | The open request about this fix.
openRequestOf :: Scenario -> TransactionView -> IO StoredRequest
openRequestOf sc fix = do
  open <- ready (openRequests (scRuntime sc))
  case L.filter ((== viewWorkOrder fix) . storedWorkOrder) open of
    [r] -> pure r
    rs -> assertFailure ("expected one open request for the fix, found " <> show (L.length rs))

conversationOf :: Scenario -> StoredRequest -> IO Conversation
conversationOf sc r =
  ready (conversation (scRuntime sc) (storedRequestId r)) >>= maybe (assertFailure "no conversation") pure

answer :: Scenario -> T.Text -> StoredRequest -> T.Text -> IO (Either T.Text StoredMessage)
answer sc key r choice = do
  ik <- idem key
  ready (postMessage (scRuntime sc) ik (storedRequestId r) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision r) choice ("the person chose " <> choice)))

standings :: Scenario -> T.Text -> IO [RequestStanding]
standings sc task =
  fmap recordStanding <$> accepted (ready (requestsOfTask (scRuntime sc) task))

withdrawals :: Scenario -> IO Int
withdrawals sc =
  count sc "lockstep_conversation_messages WHERE kind = 'withdrawal'"

halted :: Scenario -> IO Int
halted sc =
  count sc "lockstep_transactions WHERE state = 'halted'"

cancel :: Scenario -> T.Text -> IO (Either T.Text CancelOutcome)
cancel sc task = do
  t <- ready (findTask (scRuntime sc) task) >>= maybe (assertFailure "no task") pure
  ready (requestCancel (scRuntime sc) "test-session" task (taskTicketRevision t))

stateOfTask :: Scenario -> T.Text -> IO T.Text
stateOfTask sc task =
  maybe "missing" taskState <$> ready (findTask (scRuntime sc) task)

cancellation :: Scenario -> T.Text -> IO CancellationView
cancellation sc task =
  ready (cancellationOf (scRuntime sc) task) >>= maybe (assertFailure "no cancellation recorded") pure

-- Cases ------------------------------------------------------------------------------------------

rejectionWithdraws :: Assertion
rejectionWithdraws =
  withScenario $ \sc -> do
    (view, _) <- project sc "chain"
    _ <- approveIn sc prefix view "chain" (planOf "Values" Brownfield [valueUnit 1, valueUnit 2] [PlanEdge (k "f2") (k "f1") Technical])
    (other, _) <- project sc "other"
    otherTask <- plainTask sc other 3
    -- Only f1 has scripts: f2 and the unrelated f3 halt at their discovery for a person's decision.
    engine <- engineFor sc [valueScripts 1]
    passesUntil sc engine 80 ((\a h -> a == 1 && h == 2) <$> acceptedCount sc <*> halted sc)
    t1 <- taskTitled sc view (valueTitle 1)
    t2 <- taskTitled sc view (valueTitle 2)
    f1 <- fixOfTask sc (taskId t1)
    f2 <- fixOfTask sc (taskId t2)
    older <- openRequestOf sc f2
    otherFix <- fixOfTask sc otherTask
    otherRequest <- openRequestOf sc otherFix
    -- The owner rejects f1: f2 stops counting, and its request loses its authority at once, before any pass.
    void (accepted (ready (decideCompletion (scRuntime sc) (viewId f1) (SenderHuman ApplicationChannel) "not-done")))
    open <- ready (openRequests (scRuntime sc))
    fmap storedRequestId open @?= [storedRequestId otherRequest]
    talk <- conversationOf sc older
    storedState (conversationRequest talk) @?= "withdrawn"
    lastMessage <- maybe (assertFailure "no message") pure (L.uncons (L.reverse (conversationMessages talk)))
    messageKind (fst lastMessage) @?= "withdrawal"
    assertBool "the withdrawal does not say it was invalidated" ("Invalidated" `T.isPrefixOf` messageBody (fst lastMessage))
    -- A late answer to the obsolete request is refused and changes nothing.
    refusedWith "request-closed" (fmap (fmap messageSequence) (answer sc "late" older "retry"))
    still <- fixOfTask sc (taskId t2)
    (viewState still, viewHalt still) @?= (viewState f2, viewHalt f2)
    -- The next pass halts f2 for the invalidation, with a fresh Stop-only request of its own.
    passesUntil sc engine 10 ((== Just "ancestor-rejected") . viewHalt <$> fixOfTask sc (taskId t2))
    fresh <- openRequestOf sc =<< fixOfTask sc (taskId t2)
    assertBool "the fresh request reuses the obsolete one's identity" (storedRequestId fresh /= storedRequestId older)
    storedChoices fresh @?= ["stop"]
    standings sc (taskId t2) >>= (@?= [StandingInvalidated, StandingCurrent])
    -- Replays, more passes and a restart withdraw nothing more and revive nothing.
    traverse_ (const (engineOnceWith (scRuntime sc) engine (folders sc))) [1 :: Int, 2]
    config <- databaseConfigFor (scAdmin sc) (scDb sc)
    withRuntime config $ \runtime -> void (engineOnceWith runtime engine (folders sc))
    withdrawals sc >>= (@?= 1)
    ready (openRequests (scRuntime sc)) >>= (@?= 2) . L.length
    standings sc (taskId t2) >>= (@?= [StandingInvalidated, StandingCurrent])
    -- The unrelated request is still the person's to answer.
    void (accepted (answer sc "other-stop" otherRequest "stop"))

legacyOpenSuperseded :: Assertion
legacyOpenSuperseded =
  withScenario $ \sc -> do
    (view, _) <- project sc "legacy"
    _ <- approveIn sc prefix view "legacy" (planOf "Values" Brownfield [valueUnit 1, valueUnit 2] [PlanEdge (k "f2") (k "f1") Technical])
    engine <- engineFor sc [valueScripts 1]
    passesUntil sc engine 80 ((\a h -> a == 1 && h == 1) <$> acceptedCount sc <*> halted sc)
    t1 <- taskTitled sc view (valueTitle 1)
    t2 <- taskTitled sc view (valueTitle 2)
    f1 <- fixOfTask sc (taskId t1)
    f2 <- fixOfTask sc (taskId t2)
    older <- openRequestOf sc f2
    -- A database from before update 2: an invalidation recorded without withdrawing the request.
    adminExecute
      (scAdmin sc)
      (T.unpack (scDb sc))
      ("INSERT INTO lockstep_fix_invalidations (transaction_id, code, cause_transaction_id) VALUES ('" <> T.unpack (viewId f2) <> "', 'ancestor-rejected', '" <> T.unpack (viewId f1) <> "')")
    config <- databaseConfigFor (scAdmin sc) (scDb sc)
    withRuntime config $ \runtime -> void (engineOnceWith runtime engine (folders sc))
    talk <- conversationOf sc older
    storedState (conversationRequest talk) @?= "withdrawn"
    assertBool "the older request was not marked superseded" (L.any (("Superseded" `T.isPrefixOf`) . messageBody) (conversationMessages talk))
    refusedWith "request-closed" (fmap (fmap messageSequence) (answer sc "late" older "retry"))
    standings sc (taskId t2) >>= (@?= [StandingSuperseded, StandingCurrent])

cancelHalted :: Assertion
cancelHalted =
  withScenario $ \sc -> do
    (view, _) <- project sc "halted"
    task <- plainTask sc view 1
    -- No scripts: the fix halts at its discovery for a person's decision.
    engine <- engineFor sc []
    passesUntil sc engine 20 ((== 1) <$> halted sc)
    fix <- fixOfTask sc task
    request <- openRequestOf sc fix
    -- Canceling outright is still refused while the fix is live; a cancel request is taken, nothing is settled yet.
    t <- ready (findTask (scRuntime sc) task) >>= maybe (assertFailure "no task") pure
    refusedWith "fix-active" (fmap (fmap taskState) (ready (decideTask (scRuntime sc) "test-session" task (taskTicketRevision t) CancelTask)))
    outcome <- accepted (cancel sc task)
    case outcome of
      CancelStopping _ -> pure ()
      CancelSettled _ -> assertFailure "the task was canceled while its fix was live"
    cancellation sc task >>= (@?= "stopping") . cancellationState
    stateOfTask sc task >>= (@?= taskState t)
    fixOfTask sc task >>= (@?= "halted") . viewState
    -- A replay of the cancel is the same request.
    again <- accepted (cancel sc task)
    case again of
      CancelStopping _ -> pure ()
      CancelSettled _ -> assertFailure "a replayed cancel settled the task"
    count sc "lockstep_task_cancellations" >>= (@?= 1)
    -- The pass stops the fix at its safe point, withdraws its request, then cancels the task.
    void (engineOnceWith (scRuntime sc) engine (folders sc))
    fixOfTask sc task >>= (@?= "stopped") . viewState
    count sc "lockstep_transaction_records WHERE kind = 'cancellation'" >>= (@?= 1)
    conversationOf sc request >>= (@?= "withdrawn") . storedState . conversationRequest
    refusedWith "request-closed" (fmap (fmap messageSequence) (answer sc "late" request "retry"))
    stateOfTask sc task >>= (@?= "canceled")
    cancellation sc task >>= (@?= "canceled") . cancellationState

cancelBeforeStart :: Assertion
cancelBeforeStart =
  withScenario $ \sc -> do
    (view, _) <- project sc "unstarted"
    task <- plainTask sc view 1
    outcome <- accepted (cancel sc task)
    case outcome of
      CancelStopping _ -> pure ()
      CancelSettled _ -> assertFailure "the task was canceled while its fix was handed over"
    engine <- engineFor sc [valueScripts 1]
    passesUntil sc engine 5 ((== "canceled") <$> stateOfTask sc task)
    fixOfTask sc task >>= (@?= "stopped") . viewState
    -- No stage ran: no basis, no role.
    count sc "lockstep_transaction_records WHERE kind = 'basis'" >>= (@?= 0)
    count sc "lockstep_invocations" >>= (@?= 0)

cancelUncertain :: Assertion
cancelUncertain =
  withScenario $ \sc -> do
    (view, _) <- project sc "uncertain"
    task <- plainTask sc view 1
    let
      marker = scTmp sc <> "/ran"
      sleeper = "{\"append\":{\"path\":\"" <> T.pack marker <> "\",\"content\":\"ran\\n\"}},{\"sleep\":30}"
    engine <- engineFor sc [(valueTitle 1, Scripts [sleeper] "" (review []))]
    -- The first pass starts the fix and builds its basis; the second runs the Planner, cut short.
    void (engineOnceWith (scRuntime sc) engine (folders sc))
    thread <- forkIO (void (try (void (engineOnceWith (scRuntime sc) engine (folders sc))) :: IO (Either SomeException ())))
    ran <- waitFor 300 (doesFileExist marker)
    assertBool "the Planner never started" ran
    killThread thread
    threadDelay 500000
    count sc "lockstep_invocations WHERE finished_at IS NULL" >>= (@?= 1)
    void (accepted (cancel sc task))
    -- The pass settles the cut-short run as uncertain; the cancel does not discard it.
    traverse_ (const (engineOnceWith (scRuntime sc) engine (folders sc))) [1 :: Int, 2]
    fix <- fixOfTask sc task
    (viewState fix, viewHalt fix) @?= ("halted", Just "uncertain-invocation unfinished-invocation")
    cancellation sc task >>= (@?= "waiting-for-you") . cancellationState
    stateOfTask sc task >>= (@?= "ready")
    count sc "lockstep_transaction_records WHERE kind = 'uncertain'" >>= (@?= 1)
    -- The person decides: stop. Then the cancel settles; the uncertain record stays.
    request <- openRequestOf sc fix
    void (accepted (answer sc "stop" request "stop"))
    passesUntil sc engine 5 ((== "canceled") <$> stateOfTask sc task)
    fixOfTask sc task >>= (@?= "stopped") . viewState
    count sc "lockstep_transaction_records WHERE kind = 'uncertain'" >>= (@?= 1)

cancelAccepted :: Assertion
cancelAccepted =
  withScenario $ \sc -> do
    (view, _) <- project sc "accepted"
    task <- plainTask sc view 1
    engine <- engineFor sc [valueScripts 1]
    passesUntil sc engine 60 ((== 1) <$> acceptedCount sc)
    refusedWith "fix-accepted" (fmap (fmap (const ())) (cancel sc task))
    count sc "lockstep_task_cancellations" >>= (@?= 0)
    fixOfTask sc task >>= (@?= "accepted") . viewState

-- | Polls the check every 100 ms, at most @n@ times.
waitFor :: Int -> IO Bool -> IO Bool
waitFor n check = do
  done <- check
  case (done, n) of
    (True, _) -> pure True
    (False, 0) -> pure False
    _ -> threadDelay 100000 >> waitFor (n - 1) check
