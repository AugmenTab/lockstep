{-# LANGUAGE OverloadedStrings #-}

{- | Continuous deterministic scheduling of an approved plan against real
PostgreSQL, Git and processes, with scripted roles (contract C-P6.5 and the
handoff §10 list): one approval runs a three-unit chain to the end, each fix
built on the one before; order, contention, restarts, stale revisions,
waiting reasons, a human decision that holds only its own repository, a Done
fix that satisfies its dependents, and no cancel while a fix is active.
-}
module Lockstep.DispatchTest
  ( tests
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Conversation (Channel (..), Sender (..), StoredRequest (..), openRequests, postMessage)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Dispatch (DispatchReport (..), DispatchView (..), dispatchOnce, dispatchView, handOverUnit)
import Lockstep.Application.Engine (Engine (..), TransactionView (..), decideCompletion, transactionForWorkOrder, transactionView)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask, listTasks)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter (..), Workspace (..), directRunner, scriptedAdapter)
import Lockstep.Kernel.Conversation (RequestInput (..))
import Lockstep.Kernel.Plan
  ( EdgeKind (..)
  , EffectClass (..)
  , Envelope (..)
  , PlanCriterion (..)
  , PlanDocument (..)
  , PlanEdge (..)
  , PlanMode (..)
  , PlanSource (..)
  , PlanUnit (..)
  , RiskClass (..)
  , UnitKey
  , mkUnitKey
  )
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..), TaskReadiness (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryBool, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P6.5 continuous scheduling of an approved plan (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "one approval runs a three-unit chain to the end with no person between: each fix is handed over by the scheduler and built on the accepted commit before it; nothing is Done; a restart redispatches nothing (S1-S6, S8)" chain
    , testCase "the next unit: the highest priority that is ready; a higher priority that waits is not taken; the others say why (S2, S3, S7)" ordering
    , testCase "two dispatchers at once hand over one unit once; a dispatcher on a fresh runtime hands over nothing more (S4, S6)" contenders
    , testCase "a hand-over decided on a revision that is no longer effective is refused stale-plan-revision and writes nothing (S4)" staleRevision
    , testCase "truthful waiting: a project not allowed to run, a plan with a token budget (usage unknown), a busy writer (S2, S7)" waiting
    , testCase "a fix halted for a person's decision holds its own project only; another project's unit runs (S7)" humanBlocksOnlyItsOwn
    , testCase "a fix the person marks Done satisfies its dependents, also outside a plan (S1, P6.2 D1)" doneSatisfies
    , testCase "a task whose fix is handed over or running cannot be canceled; once the fix is stopped it can (S10)" cancelDuringFix
    ]

-- Fixtures ---------------------------------------------------------------------------------------

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p65" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/work")
        action (Scenario admin db runtime tmp)

folders :: Scenario -> ProjectFolders
folders sc =
  ProjectFolders (Just (scTmp sc <> "/projects")) []

accepted :: Show e => IO (Either e a) -> IO a
accepted action =
  action >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

idem :: T.Text -> IO IdempotencyKey
idem text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-dispatch-key-" <> text))

gitIn :: FilePath -> [String] -> IO String
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  finished <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case finished of
    Nothing -> assertFailure ("git " <> show args <> " did not finish within 30 s")
    Just (code, out, err) -> do
      assertBool ("git " <> show args <> " failed: " <> out <> err) (code == ExitSuccess)
      pure out

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

k :: T.Text -> UnitKey
k text =
  case mkUnitKey text of
    Just u -> u
    Nothing -> k "invalid-key-in-test"

-- | A project whose folder holds f1.py, f2.py, f3.py (each @value()@ returns 0), allowed to run.
project :: Scenario -> T.Text -> Bool -> IO (ProjectView, FilePath)
project sc name enable = do
  pk <- idem ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  traverse_ (\n -> writeFile (folder <> "/f" <> show n <> ".py") "def value():\n    return 0\n") [1 :: Int, 2, 3]
  _ <- gitIn folder ["add", "f1.py", "f2.py", "f3.py"]
  _ <- gitIn folder ["commit", "-q", "-m", "start"]
  when enable $ do
    ek <- idem ("enable-" <> name)
    void (accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing)))
  pure (view, folder)

-- | Unit @fN@: make fN.value() return N.
unit :: Int -> PlanUnit
unit n =
  PlanUnit
    { unitKey = k ("f" <> T.pack (show n))
    , unitTitle = "Make f" <> T.pack (show n) <> " return " <> T.pack (show n)
    , unitPhase = "P1"
    , unitSubphase = "P1." <> T.pack (show n)
    , unitWorkKind = "bug-fix"
    , unitProfile = "lockstep-bug-fix"
    , unitPriority = Normal
    , unitEffect = LocalOnly
    , unitRisk = RiskLow
    , unitProvisional = True
    , unitOutputs = ["f" <> T.pack (show n) <> ".py"]
    , unitAcceptance = [PlanCriterion ("f" <> T.pack (show n) <> ".value() is " <> T.pack (show n) <> ".") ["prd"]]
    , unitNegative = []
    , unitChecks = []
    , unitPrerequisites = []
    , unitResources = []
    }

plan :: [PlanUnit] -> [PlanEdge] -> PlanDocument
plan units edges =
  PlanDocument
    { planTitle = "Three values"
    , planMode = Brownfield
    , planSources = [PlanSource "prd" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
    , planEnvelope = Envelope False 10 Nothing
    , planUnits = units
    , planEdges = edges
    , planUncertainties = []
    }

chainPlan :: PlanDocument
chainPlan =
  plan [unit 1, unit 2, unit 3] [PlanEdge (k "f2") (k "f1") Technical, PlanEdge (k "f3") (k "f2") Technical]

-- | Proposes and approves a plan; the approved revision.
approved :: Scenario -> ProjectView -> T.Text -> PlanDocument -> IO RevisionView
approved sc view name p = do
  ik <- idem ("plan-" <> name)
  r <- accepted (ready (proposePlan (scRuntime sc) ik (projectId view) "owner-session" (LBS.fromStrict (TE.encodeUtf8 (encodePlanDocument p)))))
  accepted (ready (decidePlan (scRuntime sc) "owner-session" (projectId view) (revisionNumber r) (revisionDigest r) ApprovePlan))

-- Scripts: each role's script is chosen by the unit title its context names -----------------------

jsonString :: T.Text -> T.Text
jsonString text =
  "\"" <> T.concatMap escape text <> "\""
 where
  escape c =
    case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      _ -> T.singleton c

result :: T.Text -> T.Text
result roleAnswer =
  "{\"result\":" <> roleAnswer <> "}"

-- | The happy scripts for unit fN, per role, in invocation order.
scriptsFor :: Int -> Role -> [T.Text]
scriptsFor n role =
  let
    f = "f" <> T.pack (show n)
    file = f <> ".py"
    wrong = f <> " is wrong"
    check = "import " <> f <> "; assert " <> f <> ".value() == " <> T.pack (show n) <> ", '" <> wrong <> "'"
    citation = "[{\"path\":\"" <> file <> "\",\"first\":1,\"last\":2}]"
    discovery =
      result
        ( "{\"kind\":\"discovery\",\"summary\":\""
            <> f
            <> " returns 0\",\"hypothesis\":\"value returns 0\",\"citations\":"
            <> citation
            <> ","
            <> "\"reproduction\":{\"argv\":[\"python3\",\"-c\","
            <> jsonString check
            <> "],\"signature\":\""
            <> wrong
            <> "\"},"
            <> "\"allowed_paths\":[\""
            <> file
            <> "\"]}"
        )
    testFile = "test_" <> f <> ".py"
    candidate =
      result
        ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"value\",\"text\":\"value is "
            <> T.pack (show n)
            <> "\",\"ticket_quote\":\""
            <> f
            <> ".value() is "
            <> T.pack (show n)
            <> ".\","
            <> "\"citations\":"
            <> citation
            <> "}],\"allowed_paths\":[\""
            <> file
            <> "\"],"
            <> "\"verification\":[[\"python3\",\"-m\",\"unittest\",\"test_"
            <> f
            <> "\"]],\"tests\":[{\"path\":\""
            <> testFile
            <> "\",\"content\":"
            <> jsonString ("import unittest\nimport " <> f <> "\n\n\nclass TestValue(unittest.TestCase):\n    def test_value(self):\n        self.assertEqual(" <> f <> ".value(), " <> T.pack (show n) <> ", '" <> wrong <> "')\n")
            <> ",\"expect\":\"red\",\"argv\":[\"python3\",\"-m\",\"unittest\",\"test_"
            <> f
            <> "\"],\"signature\":\""
            <> wrong
            <> "\"}]}"
        )
    fixes = "{\"write\":{\"path\":\"" <> file <> "\",\"content\":" <> jsonString ("def value():\n    return " <> T.pack (show n) <> "\n") <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"value returns its number\"}"
  in
    case role of
      Planner -> [discovery, candidate]
      Challenger -> [result "{\"kind\":\"challenge\",\"findings\":[]}", result "{\"kind\":\"challenge\",\"findings\":[]}"]
      Implementer -> [fixes]
      Reviewer -> [result ("{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"read it\"],\"inspected\":[" <> jsonString file <> "," <> jsonString testFile <> "]}")]

script :: T.Text -> BS.ByteString
script steps' =
  TE.encodeUtf8 ("{\"steps\":[" <> steps' <> "]}")

{- | An adapter that reads the invocation's context and runs the n-th script
of the unit whose title it names (none: the role fails, as with no helper).
-}
titledAdapter :: Role -> Int -> Adapter
titledAdapter role n =
  Adapter
    { adapterName = "scripted-by-title"
    , adapterPrepare = \workspace -> do
        context <- TE.decodeUtf8 <$> BS.readFile (workspaceInput workspace <> "/context.json")
        let
          unitOf = L.find (\u -> ("Make f" <> T.pack (show u) <> " return") `T.isInfixOf` context) [1 :: Int, 2, 3]
          chosen = unitOf >>= \u -> L.lookup n (L.zip [0 ..] (scriptsFor u role))
        adapterPrepare (scriptedAdapter "scripts/runner/scripted-role" (script (fromMaybe "" chosen))) workspace
    }

engineFor :: Scenario -> IO Engine
engineFor sc = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  pure (Engine runner (\role n -> Just (titledAdapter role n)))

-- | Engine worker passes (dispatch, start, advance) until the condition holds; at most @limit@ passes.
passesUntil :: Scenario -> Engine -> Int -> IO Bool -> IO ()
passesUntil sc engine limit done = do
  finished <- done
  case (finished, limit) of
    (True, _) -> pure ()
    (False, 0) -> do
      lastPass <- engineOnceWith (scRuntime sc) engine (folders sc)
      views <- traverse (\(i, _) -> transactionView (scRuntime sc) i) lastPass
      assertFailure ("the condition did not hold within the passes allowed; DEBUG " <> show lastPass <> show [fmap (fmap (\v -> (viewStage v, viewHalt v, L.drop (L.length (viewRecords v) - 3) (viewRecords v)))) x | x <- views])
    (False, _) -> do
      _ <- engineOnceWith (scRuntime sc) engine (folders sc)
      passesUntil sc engine (limit - 1) done

stateOf :: Scenario -> T.Text -> IO (Maybe T.Text)
stateOf sc workOrder =
  fmap viewState <$> ready (transactionForWorkOrder (scRuntime sc) workOrder)

tasksOf :: Scenario -> ProjectView -> IO [TaskView]
tasksOf sc view =
  ready (listTasks (scRuntime sc) (projectId view))

taskOfUnit :: RevisionView -> [TaskView] -> T.Text -> IO TaskView
taskOfUnit r ts name =
  case L.lookup name (revisionTasks r) >>= \tid -> L.find ((== tid) . taskId) ts of
    Just t -> pure t
    Nothing -> assertFailure ("no task for unit " <> T.unpack name)

-- Cases ------------------------------------------------------------------------------------------

chain :: Assertion
chain =
  withScenario $ \sc -> do
    (view, folder) <- project sc "chain" True
    r <- approved sc view "chain" chainPlan
    engine <- engineFor sc
    let
      acceptedCount = count sc "lockstep_transactions WHERE state = 'accepted'"
    passesUntil sc engine 120 ((== 3) <$> acceptedCount)
    -- Every hand-over was the scheduler's, one per unit, in dependency order.
    count sc "lockstep_bug_admissions WHERE actor = 'scheduler'" >>= (@?= 3)
    count sc "lockstep_plan_dispatches" >>= (@?= 3)
    -- Each fix started from the accepted commit before it.
    let
      basisFollows a b =
        "SELECT (SELECT t.basis_commit FROM lockstep_transactions t JOIN lockstep_bug_admissions x ON x.work_order_id = t.work_order_id JOIN lockstep_plan_units u ON u.task_id = x.task_id WHERE u.unit_key = '"
          <> b
          <> "' LIMIT 1) = (SELECT t.accepted_commit FROM lockstep_transactions t JOIN lockstep_bug_admissions x ON x.work_order_id = t.work_order_id JOIN lockstep_plan_units u ON u.task_id = x.task_id WHERE u.unit_key = '"
          <> a
          <> "' LIMIT 1) AS v"
    queryBool (scAdmin sc) (scDb sc) (basisFollows "f1" "f2") >>= assertBool "f2's fix did not start from f1's accepted commit"
    queryBool (scAdmin sc) (scDb sc) (basisFollows "f2" "f3") >>= assertBool "f3's fix did not start from f2's accepted commit"
    count sc "lockstep_fix_bases" >>= (@?= 2)
    -- The last fix's branch has all three values; the person's checkout has none of them.
    ts <- tasksOf sc view
    t3 <- taskOfUnit r ts "f3"
    refs <- gitIn folder ["for-each-ref", "--format=%(refname:short)", "refs/heads/lockstep/"]
    let
      branches = L.lines refs
    L.length branches @?= 3
    contents <- traverse (\b -> traverse (\f -> gitIn folder ["show", b <> ":" <> f]) ["f1.py", "f2.py", "f3.py"]) branches
    assertBool "no branch holds all three values" (L.any (\cs -> cs == ["def value():\n    return 1\n", "def value():\n    return 2\n", "def value():\n    return 3\n"]) contents)
    checkout <- gitIn folder ["show", "HEAD:f1.py"]
    checkout @?= "def value():\n    return 0\n"
    -- Technical acceptance is not Done: no fix is Done, every task is still ready, nothing was pushed.
    count sc "lockstep_transactions WHERE state = 'done'" >>= (@?= 0)
    fmap taskState ts @?= ["ready", "ready", "ready"]
    taskState t3 @?= "ready"
    remotes <- gitIn folder ["remote"]
    remotes @?= ""
    -- A restart redispatches nothing: a fresh runtime's passes hand over nothing more.
    config <- databaseConfigFor (scAdmin sc) (scDb sc)
    withRuntime config $ \runtime -> do
      reports <- ready (dispatchOnce runtime (folders sc))
      fmap reportResult reports @?= []
    count sc "lockstep_bug_admissions" >>= (@?= 3)

ordering :: Assertion
ordering =
  withScenario $ \sc -> do
    (view, _) <- project sc "ordering" True
    let
      high = (unit 1) {unitPriority = High}
      normal = (unit 2) {unitPriority = Normal}
      low = (unit 3) {unitPriority = Low}
    _ <- approved sc view "ordering" (plan [low, normal, high] [PlanEdge (k "f1") (k "f3") Technical])
    before <- accepted (ready (dispatchView (scRuntime sc) (projectId view)))
    -- f1 is high but waits for f3; f2 (normal) goes before f3 (low).
    dispatchViewNext before @?= Just "f2"
    L.sort (dispatchViewWaiting before) @?= [("f1", "waiting-for"), ("f3", "queued-behind")]
    reports <- ready (dispatchOnce (scRuntime sc) (folders sc))
    fmap reportUnit reports @?= ["f2"]
    after <- accepted (ready (dispatchView (scRuntime sc) (projectId view)))
    dispatchViewNext after @?= Nothing
    L.sort (dispatchViewWaiting after) @?= [("f1", "waiting-for"), ("f2", "handed-over"), ("f3", "writer-busy")]
    -- A second pass while f2's fix has not started hands over nothing.
    ready (dispatchOnce (scRuntime sc) (folders sc)) >>= (@?= []) . fmap reportUnit

contenders :: Assertion
contenders =
  withScenario $ \sc -> do
    (view, _) <- project sc "contenders" True
    _ <- approved sc view "contenders" (plan [unit 1] [])
    config <- databaseConfigFor (scAdmin sc) (scDb sc)
    doneA <- newEmptyMVar
    doneB <- newEmptyMVar
    _ <- forkIO (withRuntime config (\rt -> dispatchOnce rt (folders sc)) >>= putMVar doneA)
    _ <- forkIO (withRuntime config (\rt -> dispatchOnce rt (folders sc)) >>= putMVar doneB)
    a <- takeMVar doneA
    b <- takeMVar doneB
    let
      handed = [u | Right reports <- [a, b], DispatchReport _ u (Right _) <- reports]
    handed @?= ["f1"]
    count sc "lockstep_bug_admissions" >>= (@?= 1)
    count sc "lockstep_plan_dispatches" >>= (@?= 1)
    withRuntime config (\rt -> ready (dispatchOnce rt (folders sc))) >>= (@?= []) . fmap reportUnit
    count sc "lockstep_bug_admissions" >>= (@?= 1)

staleRevision :: Assertion
staleRevision =
  withScenario $ \sc -> do
    (view, _) <- project sc "stale" True
    first <- approved sc view "stale-1" (plan [unit 1] [])
    _ <- approved sc view "stale-2" (plan [unit 1, unit 2] [])
    ready (handOverUnit (scRuntime sc) (folders sc) (projectId view) (revisionDigest first) "f1") >>= (@?= Left "stale-plan-revision")
    count sc "lockstep_bug_admissions" >>= (@?= 0)
    count sc "lockstep_plan_dispatches" >>= (@?= 0)

waiting :: Assertion
waiting =
  withScenario $ \sc -> do
    (closed, _) <- project sc "closed" False
    _ <- approved sc closed "closed" (plan [unit 1] [])
    v1 <- accepted (ready (dispatchView (scRuntime sc) (projectId closed)))
    (dispatchViewNext v1, dispatchViewWaiting v1) @?= (Nothing, [("f1", "execution-not-enabled")])
    (budgeted, _) <- project sc "budgeted" True
    _ <- approved sc budgeted "budgeted" (plan [unit 1] []) {planEnvelope = Envelope False 10 (Just 100000)}
    v2 <- accepted (ready (dispatchView (scRuntime sc) (projectId budgeted)))
    (dispatchViewNext v2, dispatchViewWaiting v2) @?= (Nothing, [("f1", "usage-unknown")])
    ready (dispatchOnce (scRuntime sc) (folders sc)) >>= (@?= []) . fmap reportUnit
    count sc "lockstep_bug_admissions" >>= (@?= 0)
    -- A project with no approved plan has nothing to say.
    (bare, _) <- project sc "bare" True
    ready (dispatchView (scRuntime sc) (projectId bare)) >>= (@?= Left "no-effective-plan") . fmap dispatchViewNext

humanBlocksOnlyItsOwn :: Assertion
humanBlocksOnlyItsOwn =
  withScenario $ \sc -> do
    (dirty, dirtyFolder) <- project sc "dirty" True
    (clean, _) <- project sc "clean" True
    _ <- approved sc dirty "dirty" (plan [unit 1] [])
    _ <- approved sc clean "clean" (plan [unit 1] [])
    -- An uncommitted file: the dirty project's fix halts at its basis for a person's decision.
    writeFile (dirtyFolder <> "/notes.txt") "uncommitted\n"
    engine <- engineFor sc
    passesUntil sc engine 80 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'accepted'")
    count sc "lockstep_transactions WHERE state = 'halted'" >>= (@?= 1)
    open <- ready (openRequests (scRuntime sc))
    L.length open @?= 1
    cleanView <- accepted (ready (dispatchView (scRuntime sc) (projectId clean)))
    dispatchViewWaiting cleanView @?= [("f1", "handed-over")]

doneSatisfies :: Assertion
doneSatisfies =
  withScenario $ \sc -> do
    (view, _) <- project sc "done" True
    -- Two ordinary tasks, no plan: b depends on a.
    ta <- idem "task-a"
    a <- accepted (ready (createTask (scRuntime sc) (NewTask ta (projectId view) "Make f1 return 1" "f1.value() is 1." Normal [])))
    aReady <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId a) (taskTicketRevision a) MarkReady))
    tb <- idem "task-b"
    b <- accepted (ready (createTask (scRuntime sc) (NewTask tb (projectId view) "Something after" "It follows." Normal [taskId a])))
    _ <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId b) (taskTicketRevision b) MarkReady))
    ak <- idem "admit-a"
    admission <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId aReady) (taskTicketRevision aReady)))
    engine <- engineFor sc
    passesUntil sc engine 60 ((== Just "accepted") <$> stateOf sc (admissionWorkOrder admission))
    -- Accepted is not Done: an untyped dependency still waits.
    waitingB <- L.find ((== taskId b) . taskId) <$> tasksOf sc view
    fmap taskReadinessOf waitingB @?= Just (WaitingFor ["Make f1 return 1"])
    tx <- ready (transactionForWorkOrder (scRuntime sc) (admissionWorkOrder admission)) >>= maybe (assertFailure "no fix") pure
    _ <- accepted (ready (decideCompletion (scRuntime sc) (viewId tx) (SenderHuman ApplicationChannel) "done"))
    readyB <- L.find ((== taskId b) . taskId) <$> tasksOf sc view
    fmap taskReadinessOf readyB @?= Just ReadyToWork

cancelDuringFix :: Assertion
cancelDuringFix =
  withScenario $ \sc -> do
    (view, folder) <- project sc "cancel" True
    ta <- idem "task"
    t <- accepted (ready (createTask (scRuntime sc) (NewTask ta (projectId view) "Make f1 return 1" "f1.value() is 1." Normal [])))
    tReady <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
    ak <- idem "admit"
    admission <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId tReady) (taskTicketRevision tReady)))
    -- Handed over, not started: no cancel.
    ready (decideTask (scRuntime sc) "test-session" (taskId tReady) (taskTicketRevision tReady) CancelTask) >>= (@?= Left "fix-active") . fmap taskState
    -- Halted for a decision: no cancel either.
    writeFile (folder <> "/notes.txt") "uncommitted\n"
    engine <- engineFor sc
    passesUntil sc engine 10 ((== Just "halted") <$> stateOf sc (admissionWorkOrder admission))
    ready (decideTask (scRuntime sc) "test-session" (taskId tReady) (taskTicketRevision tReady) CancelTask) >>= (@?= Left "fix-active") . fmap taskState
    -- The person stops the fix; then the task may be canceled, and the page still has the fix's real state.
    open <- ready (openRequests (scRuntime sc))
    request <- case open of
      [r] -> pure r
      _ -> assertFailure "no open request"
    sk <- idem "stop"
    _ <- accepted (ready (postMessage (scRuntime sc) sk (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "stop" "stop this fix")))
    passesUntil sc engine 10 ((== Just "stopped") <$> stateOf sc (admissionWorkOrder admission))
    canceled <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId tReady) (taskTicketRevision tReady) CancelTask))
    taskState canceled @?= "canceled"
    stateOf sc (admissionWorkOrder admission) >>= (@?= Just "stopped")
    exists <- doesFileExist (folder <> "/notes.txt")
    assertBool "the person's file was touched" exists
