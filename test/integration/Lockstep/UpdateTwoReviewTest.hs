{-# LANGUAGE OverloadedStrings #-}

{- | The independent review of Update 2 (R-U2, docs/gates/P6-U2/review.md),
against real PostgreSQL, Git and processes with scripted roles: an uncertain
outcome stays the person's even after an invalidation re-halts the fix and a
cancel is pending; a Planner revision that would remove a gate is refused when
approved, not only when proposed; a cancel left over from an earlier fix never
cancels the task once a newer fix was handed over; a newer halt supersedes only
the fix's earlier halt requests.
-}
module Lockstep.UpdateTwoReviewTest
  ( tests
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (SomeException, try)
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (doesFileExist)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Cancellation (CancellationView (..), cancellationOf, requestCancel)
import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Conversation (Channel (..), NewHumanRequest (..), Sender (..), StoredRequest (..), openRequest, openRequests, postMessage)
import Lockstep.Application.Engine (Engine (..), TransactionView (..), decideCompletion)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (admitBug)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (DraftOutcome (..), DraftReport (..), PlanDecision (..), PlanView (..), RevisionView (..), decidePlan, draftPlansUntil, planView, requestDraft)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (NewTask (..), TaskView (..), createTask, findTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (directRunner, scriptedAdapter)
import Lockstep.Kernel.Conversation (RequestInput (..))
import Lockstep.Kernel.Plan (EdgeKind (..), PlanDocument (..), PlanEdge (..), PlanMode (..), PlanSource (..), PlanUnit (..))
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Support.Postgres (adminExecute)
import Lockstep.Support.Scheduling (Scenario (..), Scripts (..), accepted, acceptedCount, approveIn, count, engineFor, fixOfTask, folders, idemWith, k, markReady, passesUntil, planOf, projectWith, proposeIn, ready, tasksOf, valueFiles, valueScripts, valueTitle, valueUnit, withScenario)

tests :: TestTree
tests =
  testGroup
    "R-U2 the review of Update 2 (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "an uncertain outcome stays the person's after an invalidation re-halts the fix and a cancel is pending (R-U2-1)" uncertainKept
    , testCase "a Planner revision that would remove a human gate is refused when approved, not only when proposed (R-U2-2)" gateRecheckedAtApproval
    , testCase "a cancel left from an earlier fix never cancels the task once a newer fix was handed over (R-U2-3)" staleCancelSettled
    , testCase "a newer halt supersedes only the fix's earlier halt requests, not another open request about it (R-U2-5)" otherRequestKept
    ]

prefix :: T.Text
prefix =
  "test-update2-review-"

idem :: T.Text -> IO IdempotencyKey
idem =
  idemWith prefix

taskTitled :: Scenario -> ProjectView -> T.Text -> IO TaskView
taskTitled sc view title = do
  ts <- tasksOf sc view
  maybe (assertFailure ("no task " <> T.unpack title)) pure (L.find ((== title) . taskTitle) ts)

waitFor :: Int -> IO Bool -> IO Bool
waitFor n check = do
  done <- check
  case (done, n) of
    (True, _) -> pure True
    (False, 0) -> pure False
    _ -> threadDelay 100000 >> waitFor (n - 1) check

openRequestOf :: Scenario -> TransactionView -> IO StoredRequest
openRequestOf sc fix = do
  open <- ready (openRequests (scRuntime sc))
  case [r | r <- open, storedWorkOrder r == viewWorkOrder fix, "halt" `T.isInfixOf` storedEvidence r || storedChoices r /= []] of
    r : _ -> pure r
    [] -> assertFailure "no open request for the fix"

uncertainKept :: Assertion
uncertainKept =
  withScenario $ \sc -> do
    (view, _) <- projectWith sc prefix "uncertain" (valueFiles 2) True
    _ <- approveIn sc prefix view "uncertain" (planOf "Values" Brownfield [valueUnit 1, valueUnit 2] [PlanEdge (k "f2") (k "f1") Technical])
    let
      marker = scTmp sc <> "/ran"
      sleeper = "{\"append\":{\"path\":\"" <> T.pack marker <> "\",\"content\":\"ran\\n\"}},{\"sleep\":30}"
      (title2, good2) = valueScripts 2
    engine <- engineFor sc [valueScripts 1, (title2, good2 {scriptsPlanner = [sleeper]})]
    passesUntil sc engine 80 ((== 1) <$> acceptedCount sc)
    passesUntil sc engine 10 ((== 2) <$> count sc "lockstep_transaction_records WHERE kind = 'basis'")
    thread <- forkIO (void (try (void (engineOnceWith (scRuntime sc) engine (folders sc))) :: IO (Either SomeException ())))
    ran <- waitFor 300 (doesFileExist marker)
    assertBool "the Planner never started" ran
    killThread thread
    threadDelay 500000
    void (engineOnceWith (scRuntime sc) engine (folders sc))
    count sc "lockstep_transactions WHERE halt_code = 'uncertain-invocation unfinished-invocation'" >>= (@?= 1)
    -- The ancestor is rejected (f2 is invalidated) and the person asks to cancel f2's task.
    t1 <- taskTitled sc view (valueTitle 1)
    f1 <- fixOfTask sc (taskId t1)
    void (accepted (ready (decideCompletion (scRuntime sc) (viewId f1) (SenderHuman ApplicationChannel) "not-done")))
    t2 <- taskTitled sc view (valueTitle 2)
    void (accepted (ready (requestCancel (scRuntime sc) "test-session" (taskId t2) (taskTicketRevision t2))))
    traverse_ (const (engineOnceWith (scRuntime sc) engine (folders sc))) [1 :: Int, 2, 3]
    -- Re-halted for the invalidation, still not stopped: the uncertain outcome waits for the person.
    f2 <- fixOfTask sc (taskId t2)
    viewState f2 @?= "halted"
    ready (cancellationOf (scRuntime sc) (taskId t2)) >>= (@?= Just "waiting-for-you") . fmap cancellationState
    count sc "lockstep_transaction_records WHERE kind = 'cancellation'" >>= (@?= 0)

gateRecheckedAtApproval :: Assertion
gateRecheckedAtApproval =
  withScenario $ \sc -> do
    (view, _) <- projectWith sc prefix "gates" (valueFiles 2) True
    let
      prd = "# Values\n\nTwo values.\n"
      sha text = case sha256Hasher of Hasher f -> contentDigestText (f text)
      inPhase n phase = (valueUnit n) {unitPhase = phase, unitSubphase = phase <> ".1"}
      open' = planOf "Values" Brownfield [inPhase 1 "P1", inPhase 2 "P2"] [PlanEdge (k "f2") (k "f1") Technical]
      gated = open' {planEdges = [PlanEdge (k "f2") (k "f1") HumanAcceptance]}
    _ <- approveIn sc prefix view "open" open'
    -- The owner proposes a gated revision (2), not yet approved.
    gatedRevision <- proposeIn sc prefix view "gated" gated >>= either (\e -> assertFailure ("refused: " <> show e)) pure
    -- The Planner then proposes one with no gate (3): it removes none of the plan in effect (1).
    dk <- idem "draft"
    _ <- accepted (ready (requestDraft (scRuntime sc) dk (projectId view) "owner-session" prd Nothing))
    cancel <- newCancel
    runner <- directRunner cancel (scTmp sc <> "/work")
    let
      answer = "{\"result\":{\"kind\":\"plan\",\"plan\":" <> encodePlanDocument open' {planTitle = "Values again", planSources = [PlanSource "prd" (sha prd)]} <> "}}"
      planner = Engine runner (\role _ -> if role == Planner then Just (scriptedAdapter "scripts/runner/scripted-role" (TE.encodeUtf8 ("{\"steps\":[" <> answer <> "]}"))) else Nothing)
    reports <- ready (draftPlansUntil (scRuntime sc) planner (pure False))
    plannerNumber <- case fmap reportOutcome reports of
      [DraftProposed n] -> pure n
      other -> assertFailure ("the Planner's draft gave " <> show other)
    -- The owner approves the gate; then the pending, newer Planner revision would remove it.
    _ <- accepted (ready (decidePlan (scRuntime sc) "owner-session" (projectId view) (revisionNumber gatedRevision) (revisionDigest gatedRevision) ApprovePlan))
    pv <- accepted (ready (planView (scRuntime sc) (projectId view)))
    plannerRevision <- maybe (assertFailure "no Planner revision") pure (L.find ((== plannerNumber) . revisionNumber) (planViewRevisions pv))
    ready (decidePlan (scRuntime sc) "owner-session" (projectId view) plannerNumber (revisionDigest plannerRevision) ApprovePlan) >>= (@?= Left "human-gate-removed") . fmap (const ())
    count sc "lockstep_plan_decisions WHERE decision = 'approved'" >>= (@?= 2)

staleCancelSettled :: Assertion
staleCancelSettled =
  withScenario $ \sc -> do
    (view, _) <- projectWith sc prefix "stale-cancel" (valueFiles 1) True
    tk <- idem "task"
    t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) (valueTitle 1) "f1.value() is 1." Normal [])))
    tReady <- markReady sc t
    ak <- idem "admit-1"
    _ <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId tReady) (taskTicketRevision tReady)))
    -- No scripts: the fix halts; the person stops it.
    engine <- engineFor sc []
    passesUntil sc engine 20 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    old <- fixOfTask sc (taskId t)
    request <- openRequestOf sc old
    sk <- idem "stop"
    void (accepted (ready (postMessage (scRuntime sc) sk (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "stop" "stop it"))))
    passesUntil sc engine 5 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'stopped'")
    -- The person hands it over again: a newer fix.
    current <- ready (findTask (scRuntime sc) (taskId t)) >>= maybe (assertFailure "no task") pure
    rk <- idem "admit-2"
    _ <- accepted (ready (admitBug (scRuntime sc) (folders sc) rk (taskId t) (taskTicketRevision current)))
    -- A cancel of the earlier fix left unsettled (as a crash or a refused settlement would leave it).
    adminExecute (scAdmin sc) (T.unpack (scDb sc)) ("INSERT INTO lockstep_task_cancellations (work_order_id, task_id, session) VALUES ('" <> T.unpack (viewWorkOrder old) <> "', '" <> T.unpack (taskId t) <> "', 'test-session')")
    traverse_ (const (engineOnceWith (scRuntime sc) engine (folders sc))) [1 :: Int, 2]
    count sc "lockstep_task_cancellation_settlements WHERE outcome = 'not-canceled'" >>= (@?= 1)
    ready (findTask (scRuntime sc) (taskId t)) >>= (@?= Just "ready") . fmap taskState
    count sc "lockstep_bug_admissions" >>= (@?= 2)

otherRequestKept :: Assertion
otherRequestKept =
  withScenario $ \sc -> do
    (view, _) <- projectWith sc prefix "other-request" (valueFiles 1) True
    _ <- approveIn sc prefix view "other-request" (planOf "Values" Brownfield [valueUnit 1] [])
    engine <- engineFor sc []
    passesUntil sc engine 20 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    t <- taskTitled sc view (valueTitle 1)
    fix <- fixOfTask sc (taskId t)
    ok <- idem "other"
    other <-
      accepted
        ( ready
            ( openRequest
                (scRuntime sc)
                ok
                SenderSupervisor
                NewHumanRequest
                  { newRequestWorkOrder = viewWorkOrder fix
                  , newRequestEngineer = viewEngineer fix
                  , newRequestContract = Nothing
                  , newRequestChoices = Nothing
                  , newRequestQuestion = "Is the folder the right one?"
                  , newRequestEvidence = "asked separately"
                  , newRequestAuthority = "None: a question only."
                  }
            )
        )
    traverse_ (const (engineOnceWith (scRuntime sc) engine (folders sc))) [1 :: Int, 2, 3]
    open <- ready (openRequests (scRuntime sc))
    assertBool "the other request was withdrawn" (storedRequestId other `L.elem` fmap storedRequestId open)
    L.length open @?= 2
