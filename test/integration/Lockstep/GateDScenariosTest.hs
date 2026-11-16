{-# LANGUAGE OverloadedStrings #-}

{- | Gate D (P6.11) scenarios D-01 and D-05 to D-09, model-free, against real
PostgreSQL, Git and processes with scripted roles: a PRD becomes a validated
plan, and a cycle or a contradiction is refused; rejecting an ancestor
invalidates its descendants while unrelated work stays eligible; resource,
quota and failed-test refusals; a crash mid-role and restarts lose no decision
and make no second writer; an imported Ticket and a plan unit go through the
same pipeline; a person's question is answered, a forged decision refused, and
the person's authenticated decision resumes the fix safely. D-02 to D-04 are
'Lockstep.GateDThreeUnitTest'; D-10 is 'Lockstep.GateDPagesTest'.
-}
module Lockstep.GateDScenariosTest
  ( tests
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (SomeException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (doesFileExist, removeFile)
import System.IO (FilePath, writeFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Backlog (importBacklog)
import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Conversation (Channel (..), Sender (..), StoredRequest (..), openRequests, postMessage)
import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Dispatch (DispatchView (..), dispatchView)
import Lockstep.Application.Engine (Engine (..), RecordView (..), TransactionView (..), decideCompletion)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (admitBug)
import Lockstep.Application.Inbox (askQuestion)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (DraftOutcome (..), DraftReport (..), draftPlansUntil, requestDraft)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (TaskView (..))
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter (..), Workspace (..), directRunner, scriptedAdapter)
import Lockstep.Kernel.Conversation (RequestInput (..))
import Lockstep.Kernel.Plan (EdgeKind (..), Envelope (..), PlanCriterion (..), PlanDocument (..), PlanEdge (..), PlanMode (..), PlanSource (..), PlanUnit (..))
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Support.Postgres (databaseConfigFor, withRuntime)
import Lockstep.Support.Scheduling
  ( Scenario (..)
  , Scripts (..)
  , accepted
  , acceptedCount
  , approveIn
  , count
  , engineFor
  , fixOfTask
  , fixes
  , folders
  , idemWith
  , k
  , markReady
  , passesUntil
  , planOf
  , projectWith
  , ready
  , refusedWith
  , scriptsOf
  , tasksOf
  , valueFiles
  , valueScripts
  , valueTitle
  , valueUnit
  , withScenario
  )

tests :: TestTree
tests =
  testGroup
    "Gate D scenarios (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a PRD becomes a validated plan through the Planner; a cycle and a contradiction are refused and record nothing (D-01)" prdToDag
    , testCase "rejecting an ancestor invalidates its descendant; an unrelated unit stays eligible and runs (D-05)" rejectionScope
    , testCase "refusals: execution not enabled, a busy writer, an unknown quota, a failing verification never accepted (D-06)" refusals
    , testCase "a crash mid-role and restarts: no second writer, the person's decision is kept and applied once, the chain finishes (D-07)" crashRecovery
    , testCase "an imported Ticket and a plan unit go through the same pipeline (D-08)" sharedPipeline
    , testCase "a question is answered, forged decisions are refused, the person's decision resumes the fix safely (D-09)" inboxDecision
    ]

-- Fixtures ---------------------------------------------------------------------------------------

prefix :: T.Text
prefix =
  "test-gate-d-scen-"

idem :: T.Text -> IO IdempotencyKey
idem =
  idemWith prefix

project :: Scenario -> T.Text -> IO (ProjectView, FilePath)
project sc name =
  projectWith sc prefix name (valueFiles 3) True

sha :: T.Text -> T.Text
sha text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

taskTitled :: Scenario -> ProjectView -> T.Text -> IO TaskView
taskTitled sc view title = do
  ts <- tasksOf sc view
  maybe (assertFailure ("no task " <> T.unpack title)) pure (L.find ((== title) . taskTitle) ts)

script :: T.Text -> BS.ByteString
script steps =
  TE.encodeUtf8 ("{\"steps\":[" <> steps <> "]}")

-- | An engine whose roles use the scripts table by title; the Planner answers a person's question with this text.
engineAnswering :: Scenario -> [(T.Text, Scripts)] -> T.Text -> T.Text -> IO Engine
engineAnswering sc table question answer = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    adapter role n =
      Adapter
        { adapterName = "scripted-gate-d"
        , adapterPrepare = \workspace -> do
            context <- TE.decodeUtf8 <$> BS.readFile (workspaceInput workspace <> "/context.json")
            let
              chosen
                | role == Planner && question `T.isInfixOf` context = Just ("{\"result\":{\"kind\":\"clarification\",\"text\":\"" <> answer <> "\"}}")
                | otherwise = L.find ((`T.isInfixOf` context) . fst) table >>= \(_, s) -> L.lookup n (L.zip [0 ..] (scriptsOf s role))
            adapterPrepare (scriptedAdapter "scripts/runner/scripted-role" (script (fromMaybe "" chosen))) workspace
        }
  pure (Engine runner (\role n -> Just (adapter role n)))

-- | The kinds of a fix's records, in order.
kindsOf :: TransactionView -> [T.Text]
kindsOf v =
  fmap recordKind (viewRecords v)

-- Cases ------------------------------------------------------------------------------------------

prdToDag :: Assertion
prdToDag =
  withScenario $ \sc -> do
    let
      prd = "# Values\n\nf1 returns 1; f2 returns 2 using f1.\n"
      sources = [PlanSource "prd" (sha prd)]
      unitWith n = (valueUnit n) {unitAcceptance = [PlanCriterion ("f" <> T.pack (show n) <> ".value() is " <> T.pack (show n) <> ".") ["prd"]]}
      valid = (planOf "Values" Brownfield [unitWith 1, unitWith 2] [PlanEdge (k "f2") (k "f1") Technical]) {planSources = sources}
      cyclic = valid {planEdges = [PlanEdge (k "f2") (k "f1") Technical, PlanEdge (k "f1") (k "f2") Technical]}
      -- A contradiction: a criterion cites a document the plan was not given.
      contradictory = valid {planUnits = [unitWith 1, (unitWith 2) {unitAcceptance = [PlanCriterion "f2.value() is 2." ["architecture"]]}]}
      drafted name document = do
        (view, _) <- project sc name
        dk <- idem ("draft-" <> name)
        _ <- accepted (ready (requestDraft (scRuntime sc) dk (projectId view) "owner-session" prd Nothing))
        cancel <- newCancel
        runner <- directRunner cancel (scTmp sc <> "/work")
        let
          answer = "{\"result\":{\"kind\":\"plan\",\"plan\":" <> encodePlanDocument document <> "}}"
          planner = Engine runner (\role _ -> if role == Planner then Just (scriptedAdapter "scripts/runner/scripted-role" (script answer)) else Nothing)
        fmap reportOutcome <$> ready (draftPlansUntil (scRuntime sc) planner (pure False))
    drafted "valid" valid >>= (@?= [DraftProposed 1])
    count sc "lockstep_plan_revisions" >>= (@?= 1)
    cycle' <- drafted "cyclic" cyclic
    case cycle' of
      [DraftRefused problems] -> assertBool ("the cycle is not named: " <> show problems) (L.any ("cycle" `T.isInfixOf`) problems)
      other -> assertFailure ("a cyclic plan gave " <> show other)
    contradiction <- drafted "contradictory" contradictory
    case contradiction of
      [DraftRefused (_ : _)] -> pure ()
      other -> assertFailure ("a contradictory plan gave " <> show other)
    -- Only the valid one was recorded, and nothing was approved by drafting.
    count sc "lockstep_plan_revisions" >>= (@?= 1)
    count sc "lockstep_plan_decisions" >>= (@?= 0)

rejectionScope :: Assertion
rejectionScope =
  withScenario $ \sc -> do
    (view, _) <- project sc "reject"
    _ <- approveIn sc prefix view "reject" (planOf "Values" Brownfield [valueUnit 1, valueUnit 2, valueUnit 3] [PlanEdge (k "f2") (k "f1") Technical])
    engine <- engineFor sc (fmap valueScripts [1, 2, 3])
    -- f1, then f2 (it comes before f3 in the plan); f3 is still to come.
    passesUntil sc engine 120 ((== 2) <$> acceptedCount sc)
    t1 <- taskTitled sc view (valueTitle 1)
    f1 <- fixOfTask sc (taskId t1)
    void (accepted (ready (decideCompletion (scRuntime sc) (viewId f1) (SenderHuman ApplicationChannel) "not-done")))
    count sc "lockstep_fix_invalidations WHERE code = 'ancestor-rejected'" >>= (@?= 1)
    v <- accepted (ready (dispatchView (scRuntime sc) (projectId view)))
    dispatchViewNext v @?= Just "f3"
    L.sort (dispatchViewWaiting v) @?= [("f1", "stopped"), ("f2", "invalidated")]
    passesUntil sc engine 60 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'accepted' AND id NOT IN (SELECT transaction_id FROM lockstep_fix_invalidations)")
    t3 <- taskTitled sc view (valueTitle 3)
    fixOfTask sc (taskId t3) >>= (@?= "accepted") . viewState

refusals :: Assertion
refusals =
  withScenario $ \sc -> do
    -- Not allowed to run: nothing is handed over, and it says why.
    (closed, _) <- projectWith sc prefix "closed" (valueFiles 1) False
    _ <- approveIn sc prefix closed "closed" (planOf "Values" Brownfield [valueUnit 1] [])
    v1 <- accepted (ready (dispatchView (scRuntime sc) (projectId closed)))
    dispatchViewWaiting v1 @?= [("f1", "execution-not-enabled")]
    -- A budget whose usage Lockstep cannot know: never treated as available.
    (budgeted, _) <- project sc "budgeted"
    _ <- approveIn sc prefix budgeted "budgeted" (planOf "Values" Brownfield [valueUnit 1] []) {planEnvelope = Envelope False 10 (Just 100000)}
    v2 <- accepted (ready (dispatchView (scRuntime sc) (projectId budgeted)))
    dispatchViewWaiting v2 @?= [("f1", "usage-unknown")]
    -- A fix whose change never makes its frozen test pass is never accepted, and its dependent waits on a busy writer.
    (failing, _) <- project sc "failing"
    _ <- approveIn sc prefix failing "failing" (planOf "Values" Brownfield [valueUnit 1, valueUnit 2] [])
    let
      (title1, good) = valueScripts 1
      wrong = good {scriptsFix = fixes "f1.py" "def value():\n    return 7\n"}
    engine <- engineFor sc [(title1, wrong), valueScripts 2]
    passesUntil sc engine 80 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    traverse_ (const (engineOnceWith (scRuntime sc) engine (folders sc))) [1 :: Int, 2]
    acceptedCount sc >>= (@?= 0)
    count sc "lockstep_transaction_records WHERE kind = 'acceptance'" >>= (@?= 0)
    v3 <- accepted (ready (dispatchView (scRuntime sc) (projectId failing)))
    L.sort (dispatchViewWaiting v3) @?= [("f1", "handed-over"), ("f2", "writer-busy")]
    count sc "lockstep_bug_admissions" >>= (@?= 1)

crashRecovery :: Assertion
crashRecovery =
  withScenario $ \sc -> do
    (view, _) <- project sc "crash"
    _ <- approveIn sc prefix view "crash" (planOf "Values" Brownfield [valueUnit 1, valueUnit 2, valueUnit 3] [PlanEdge (k "f2") (k "f1") Technical, PlanEdge (k "f3") (k "f2") Technical])
    let
      marker = scTmp sc <> "/ran"
      sleeper = "{\"append\":{\"path\":\"" <> T.pack marker <> "\",\"content\":\"ran\\n\"}},{\"sleep\":30}"
      (title2, good2) = valueScripts 2
      -- f2's first discovery is cut short; after the person's retry the next Planner runs answer normally.
      crashing2 = good2 {scriptsPlanner = sleeper : scriptsPlanner good2}
    engine <- engineFor sc [valueScripts 1, (title2, crashing2), valueScripts 3]
    passesUntil sc engine 80 ((== 1) <$> acceptedCount sc)
    -- f2 is handed over and its basis built; then its Planner run is killed mid-flight.
    passesUntil sc engine 10 ((== 1) <$> count sc "lockstep_transaction_records WHERE kind = 'basis' AND transaction_id NOT IN (SELECT id FROM lockstep_transactions WHERE state = 'accepted')")
    thread <- forkIO (void (try (void (engineOnceWith (scRuntime sc) engine (folders sc))) :: IO (Either SomeException ())))
    ran <- waitFor 300 (doesFileExist marker)
    assertBool "the Planner never started" ran
    killThread thread
    threadDelay 500000
    count sc "lockstep_invocations WHERE finished_at IS NULL" >>= (@?= 1)
    -- A restart: the cut-short run is settled as uncertain and the fix halts; nothing runs twice, no second writer.
    config <- databaseConfigFor (scAdmin sc) (scDb sc)
    withRuntime config $ \runtime -> traverse_ (const (engineOnceWith runtime engine (folders sc))) [1 :: Int, 2]
    count sc "lockstep_transactions WHERE state IN ('running', 'halted')" >>= (@?= 1)
    count sc "lockstep_bug_admissions" >>= (@?= 2)
    count sc "lockstep_transaction_records WHERE kind = 'uncertain'" >>= (@?= 1)
    -- The person decides retry; a restart before the next pass keeps the decision, applied exactly once.
    open <- ready (openRequests (scRuntime sc))
    request <- case open of
      [r] -> pure r
      other -> assertFailure ("open requests: " <> show (L.length other))
    rk <- idem "retry"
    void (accepted (ready (postMessage (scRuntime sc) rk (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "retry" "run it again"))))
    withRuntime config $ \runtime -> passesOn sc runtime engine 200 ((== 3) <$> acceptedCount sc)
    count sc "lockstep_transaction_records WHERE kind = 'resume'" >>= (@?= 1)
    count sc "lockstep_bug_admissions" >>= (@?= 3)
    count sc "lockstep_fix_bases" >>= (@?= 2)

-- | Engine worker passes on this runtime until the condition holds; at most @limit@ passes.
passesOn :: Scenario -> DatabaseRuntime -> Engine -> Int -> IO Bool -> IO ()
passesOn sc runtime engine limit done = do
  finished <- done
  case (finished, limit) of
    (True, _) -> pure ()
    (False, 0) -> assertFailure "the condition did not hold within the passes allowed"
    _ -> engineOnceWith runtime engine (folders sc) >> passesOn sc runtime engine (limit - 1) done

sharedPipeline :: Assertion
sharedPipeline =
  withScenario $ \sc -> do
    (view, _) <- project sc "shared"
    -- An imported Ticket: f2, from a canonical backlog document.
    let
      item = "{\"key\":\"VAL-2\",\"revision\":1,\"title\":\"" <> valueTitle 2 <> "\",\"acceptance\":[{\"text\":\"f2.value() is 2.\"}],\"blockers\":[]}"
      document = "{\"format\":\"lockstep-backlog\",\"version\":1,\"source\":{\"provider\":\"canonical\",\"locator\":\"values-notes\"},\"revision\":1,\"items\":[" <> item <> "]}"
    _ <- accepted (ready (importBacklog (scRuntime sc) (projectId view) (LBS.fromStrict (TE.encodeUtf8 document))))
    importedTask <- taskTitled sc view (valueTitle 2)
    readyTask <- if taskState importedTask == "ready" then pure importedTask else markReady sc importedTask
    ik <- idem "admit-imported"
    _ <- accepted (ready (admitBug (scRuntime sc) (folders sc) ik (taskId readyTask) (taskTicketRevision readyTask)))
    -- A plan unit: f1, handed over by the scheduler.
    _ <- approveIn sc prefix view "shared" (planOf "Values" Brownfield [valueUnit 1] [])
    engine <- engineFor sc (fmap valueScripts [1, 2])
    passesUntil sc engine 120 ((== 2) <$> acceptedCount sc)
    imported <- fixOfTask sc (taskId readyTask)
    planned <- taskTitled sc view (valueTitle 1) >>= fixOfTask sc . taskId
    -- The same records, in the same order, through the same engine; one from a person's hand-over, one from the scheduler's.
    kindsOf imported @?= kindsOf planned
    count sc "lockstep_bug_admissions WHERE actor = 'scheduler'" >>= (@?= 1)
    count sc "lockstep_task_sources" >>= (@?= 1)

inboxDecision :: Assertion
inboxDecision =
  withScenario $ \sc -> do
    (view, folder) <- project sc "inbox"
    _ <- approveIn sc prefix view "inbox" (planOf "Values" Brownfield [valueUnit 1] [])
    -- An uncommitted file: the fix halts at its basis for a person's decision.
    writeFile (folder <> "/notes.txt") "uncommitted\n"
    let
      question = "What does retry do here?"
    engine <- engineAnswering sc [valueScripts 1] question "Retry checks the folder again from the start."
    passesUntil sc engine 20 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    open <- ready (openRequests (scRuntime sc))
    request <- case open of
      [r] -> pure r
      other -> assertFailure ("open requests: " <> show (L.length other))
    qk <- idem "question"
    _ <- accepted (ready (askQuestion (scRuntime sc) qk (storedRequestId request) (storedRevision request) question))
    passesUntil sc engine 5 ((== 1) <$> count sc "lockstep_clarifications WHERE outcome = 'answered'")
    -- Only a person decides: an agent's and the Supervisor's decisions are refused.
    let
      decide sender key choice = do
        dk <- idem key
        fmap (fmap (const ())) (ready (postMessage (scRuntime sc) dk (storedRequestId request) sender (HumanDecides (storedRevision request) choice "decided")))
    refusedWith "agent-assertion" (decide (SenderAgent "implementer") "forged-agent" "retry")
    refusedWith "not-authorized" (decide SenderSupervisor "forged-supervisor" "retry")
    -- The person clears the folder and decides retry; the fix resumes from its basis and is accepted.
    removeFile (folder <> "/notes.txt")
    void (accepted (decide (SenderHuman ApplicationChannel) "person" "retry"))
    passesUntil sc engine 80 ((== 1) <$> acceptedCount sc)
    count sc "lockstep_transaction_records WHERE kind = 'resume'" >>= (@?= 1)
    count sc "lockstep_conversation_messages WHERE kind = 'decision' AND principal = 'Human'" >>= (@?= 1)

-- | Polls the check every 100 ms, at most @n@ times.
waitFor :: Int -> IO Bool -> IO Bool
waitFor n check = do
  done <- check
  case (done, n) of
    (True, _) -> pure True
    (False, 0) -> pure False
    _ -> threadDelay 100000 >> waitFor (n - 1) check
