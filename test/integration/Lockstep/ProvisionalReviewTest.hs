{-# LANGUAGE OverloadedStrings #-}

{- | The independent review of C-P6.7 (R-P6.7) against real PostgreSQL, Git
and processes with scripted roles: a fix is Done only once everything it was
built on is Done; a plan change invalidates the changed unit's work and the
work built on it; an invalidated accepted fix is not handed over again until
it is stopped; and a rework keeps the plan unit's kind.
-}
module Lockstep.ProvisionalReviewTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory)
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
import Lockstep.Application.Conversation (Channel (..), Sender (..))
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Dispatch (DispatchView (..), dispatchView)
import Lockstep.Application.Engine (Engine (..), TransactionView (..), decideCompletion, transactionForWorkOrder)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution, findAdmission)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), ExpectedChecks (..), chooseChecks)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (TaskView (..), listTasks)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter (..), Workspace (..), directRunner, scriptedAdapter)
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
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "R-P6.7 review of provisional progression (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a fix is Done only once every fix it was built on is Done (R-P6.7-9)" doneNeedsAncestorsDone
    , testCase "a plan change invalidates the changed unit's fix and the fix built on it; the invalidated one is not handed over again until it is stopped (V2 c, V6)" planChangeCascades
    , testCase "a rework of a plan unit keeps its kind (R-P6.7-3)" reworkKeepsKind
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
    withSystemTempDirectory "lockstep-p65r" $ \tmp -> do
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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-dispatch-review-" <> text))

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
project :: Scenario -> T.Text -> IO (ProjectView, FilePath)
project sc name = do
  pk <- idem ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  traverse_ (\n -> writeFile (folder <> "/f" <> show n <> ".py") "def value():\n    return 0\n") [1 :: Int, 2, 3]
  _ <- gitIn folder ["add", "f1.py", "f2.py", "f3.py"]
  _ <- gitIn folder ["commit", "-q", "-m", "start"]
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

-- | An adapter that reads the invocation's context and runs the n-th script of the unit whose title it names.
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
      assertFailure ("the condition did not hold within the passes allowed; the last pass: " <> show lastPass)
    (False, _) -> do
      _ <- engineOnceWith (scRuntime sc) engine (folders sc)
      passesUntil sc engine (limit - 1) done

-- | The fix of a unit's task.
fixOfUnit :: Scenario -> RevisionView -> T.Text -> IO TransactionView
fixOfUnit sc r name = do
  task <- maybe (assertFailure ("no task for unit " <> T.unpack name)) pure (L.lookup name (revisionTasks r))
  admission <- ready (findAdmission (scRuntime sc) task) >>= maybe (assertFailure ("unit " <> T.unpack name <> " was not handed over")) pure
  ready (transactionForWorkOrder (scRuntime sc) (admissionWorkOrder admission)) >>= maybe (assertFailure ("no fix for unit " <> T.unpack name)) pure

-- | The person's Done or Not done on a fix.
decide :: Scenario -> TransactionView -> T.Text -> IO (Either T.Text TransactionView)
decide sc tx choice =
  ready (decideCompletion (scRuntime sc) (viewId tx) (SenderHuman ApplicationChannel) choice)

acceptedCount :: Scenario -> IO Int
acceptedCount sc =
  count sc "lockstep_transactions WHERE state = 'accepted'"

waitingOf :: Scenario -> ProjectView -> IO [(T.Text, T.Text)]
waitingOf sc view =
  dispatchViewWaiting <$> accepted (ready (dispatchView (scRuntime sc) (projectId view)))

chain :: Int -> PlanDocument
chain n =
  plan (fmap unit [1 .. n]) [PlanEdge (k ("f" <> T.pack (show (i + 1)))) (k ("f" <> T.pack (show i))) Technical | i <- [1 .. n - 1]]

-- | The task of a unit and its Ticket revision.
taskOfUnit :: Scenario -> ProjectView -> RevisionView -> T.Text -> IO (T.Text, Int)
taskOfUnit sc view r name = do
  task <- maybe (assertFailure ("no task for " <> T.unpack name)) pure (L.lookup name (revisionTasks r))
  tasks <- ready (listTasks (scRuntime sc) (projectId view))
  revision <- maybe (assertFailure "no task view") (pure . taskTicketRevision) (L.find ((== task) . taskId) tasks)
  pure (task, revision)

-- Cases ------------------------------------------------------------------------------------------

doneNeedsAncestorsDone :: Assertion
doneNeedsAncestorsDone =
  withScenario $ \sc -> do
    (view, _) <- project sc "done-order"
    r <- approved sc view "done-order" (chain 2)
    engine <- engineFor sc
    passesUntil sc engine 80 ((== 2) <$> acceptedCount sc)
    f1 <- fixOfUnit sc r "f1"
    f2 <- fixOfUnit sc r "f2"
    -- f2 stands on f1's change, which is only provisionally accepted: f2 cannot be Done before it.
    decide sc f2 "done" >>= (@?= Left "ancestor-not-done") . fmap viewState
    decide sc f1 "done" >>= (@?= Right "done") . fmap viewState
    decide sc f2 "done" >>= (@?= Right "done") . fmap viewState

planChangeCascades :: Assertion
planChangeCascades =
  withScenario $ \sc -> do
    (view, _) <- project sc "cascade"
    r <- approved sc view "cascade-1" (chain 2)
    engine <- engineFor sc
    passesUntil sc engine 80 ((== 2) <$> acceptedCount sc)
    f1 <- fixOfUnit sc r "f1"
    -- The owner changes what f1 must do; f2 was built on f1's work.
    _ <- approved sc view "cascade-2" (plan [(unit 1) {unitAcceptance = [PlanCriterion "f1.value() is 1, and stays 1." ["prd"]]}, unit 2] [PlanEdge (k "f2") (k "f1") Technical])
    count sc "lockstep_fix_invalidations WHERE code = 'plan-changed'" >>= (@?= 1)
    count sc ("lockstep_fix_invalidations WHERE code = 'ancestor-rejected' AND cause_transaction_id = '" <> T.unpack (viewId f1) <> "'") >>= (@?= 1)
    waitingOf sc view >>= (@?= [("f1", "invalidated"), ("f2", "invalidated")])
    -- An invalidated fix is not handed over again before the person stops it.
    (task2, revision2) <- taskOfUnit sc view r "f2"
    ak <- idem "rework-too-early"
    ready (admitBug (scRuntime sc) (folders sc) ak task2 revision2) >>= (@?= Left "already-admitted") . fmap admissionWorkOrder

reworkKeepsKind :: Assertion
reworkKeepsKind =
  withScenario $ \sc -> do
    (view, _) <- project sc "kind"
    accepted (ready (chooseChecks (scRuntime sc) (projectId view) "lockstep-bug-fix" "lockstep-engineering" False)) >>= (@?= ChecksChosen)
    r <- approved sc view "kind" (plan [(unit 1) {unitWorkKind = "feature", unitProfile = "lockstep-engineering"}] [])
    engine <- engineFor sc
    passesUntil sc engine 60 ((== 1) <$> acceptedCount sc)
    f1 <- fixOfUnit sc r "f1"
    _ <- decide sc f1 "not-done" >>= either (\e -> assertFailure ("not done refused: " <> T.unpack e)) pure
    (task, revision) <- taskOfUnit sc view r "f1"
    ak <- idem "rework"
    _ <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak task revision))
    count sc "lockstep_bug_admissions WHERE work_kind = 'feature'" >>= (@?= 2)
    count sc "lockstep_work_orders WHERE classes = 'feature'" >>= (@?= 2)
