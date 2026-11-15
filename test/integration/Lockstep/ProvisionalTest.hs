{-# LANGUAGE OverloadedStrings #-}

{- | Provisional progression and human authority against real PostgreSQL, Git
and processes with scripted roles (contract C-P6.7): a technically accepted
fix unlocks its dependents with no Done, push or merge; the owner's rejection
invalidates every fix built on it, stops the one under way at a safe
boundary, and leaves unrelated work running; a plan change invalidates the
accepted work of its unit; rework is a new hand-over with fresh evidence; and
nothing grants new authority.
-}
module Lockstep.ProvisionalTest
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
import Lockstep.Application.Conversation (Channel (..), Sender (..), StoredRequest (..), openRequests, postMessage)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Dispatch (DispatchReport (..), DispatchView (..), dispatchOnce, dispatchView)
import Lockstep.Application.Engine (Engine (..), TransactionView (..), decideCompletion, transactionForWorkOrder)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution, findAdmission)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), ProposalRefusal (..), RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (TaskView (..), listTasks)
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
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryBool, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P6.7 provisional progression and human authority (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a technically accepted fix unlocks its dependent: no Done, no Ticket moved, no push, the person's branch unchanged (V1)" unlocksWithoutDone
    , testCase "rejecting an accepted ancestor invalidates every fix built on it; their Done is refused; unrelated work still runs (V2, V3)" rejectionInvalidates
    , testCase "a fix under way when its ancestor is rejected halts at its next stage, offering only Stop, and is never accepted (V4)" lateRejection
    , testCase "rework: once the fix has stopped the task is handed over again, a new fix with its own evidence; the old one is kept (V5, V6)" rework
    , testCase "approving a revision that changes a unit invalidates its accepted work (V2 c)" planChangeInvalidates
    , testCase "no new authority: an external effect is refused, a proposed revision hands nothing over (V7)" noNewAuthority
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

-- | Whether the second unit's fix started from the first unit's accepted commit.
basisFollows :: Scenario -> String -> String -> IO Bool
basisFollows sc a b =
  queryBool
    (scAdmin sc)
    (scDb sc)
    ( "SELECT (SELECT t.basis_commit FROM lockstep_transactions t JOIN lockstep_bug_admissions x ON x.work_order_id = t.work_order_id JOIN lockstep_plan_units u ON u.task_id = x.task_id WHERE u.unit_key = '"
        <> b
        <> "' LIMIT 1) = (SELECT t.accepted_commit FROM lockstep_transactions t JOIN lockstep_bug_admissions x ON x.work_order_id = t.work_order_id JOIN lockstep_plan_units u ON u.task_id = x.task_id WHERE u.unit_key = '"
        <> a
        <> "' LIMIT 1) AS v"
    )

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

-- Cases ------------------------------------------------------------------------------------------

unlocksWithoutDone :: Assertion
unlocksWithoutDone =
  withScenario $ \sc -> do
    (view, folder) <- project sc "unlock"
    mainBefore <- gitIn folder ["rev-parse", "refs/heads/main"]
    _ <- approved sc view "unlock" (chain 2)
    engine <- engineFor sc
    passesUntil sc engine 80 ((== 2) <$> acceptedCount sc)
    basisFollows sc "f1" "f2" >>= assertBool "f2 was not built on f1's accepted commit"
    count sc "lockstep_transactions WHERE state = 'done'" >>= (@?= 0)
    tasks <- ready (listTasks (scRuntime sc) (projectId view))
    fmap taskState tasks @?= ["ready", "ready"]
    gitIn folder ["rev-parse", "refs/heads/main"] >>= (@?= mainBefore)
    gitIn folder ["remote"] >>= (@?= "")

rejectionInvalidates :: Assertion
rejectionInvalidates =
  withScenario $ \sc -> do
    (view, _) <- project sc "reject"
    r <- approved sc view "reject" (chain 3)
    engine <- engineFor sc
    passesUntil sc engine 120 ((== 3) <$> acceptedCount sc)
    f1 <- fixOfUnit sc r "f1"
    f2 <- fixOfUnit sc r "f2"
    -- The owner rejects the first: both fixes built on it, directly or not, stop counting.
    _ <- decide sc f1 "not-done" >>= either (\e -> assertFailure ("not done refused: " <> T.unpack e)) pure
    count sc "lockstep_fix_invalidations WHERE code = 'ancestor-rejected'" >>= (@?= 2)
    waitingOf sc view >>= (@?= [("f1", "stopped"), ("f2", "invalidated"), ("f3", "invalidated")])
    decide sc f2 "done" >>= (@?= Left "acceptance-invalidated") . fmap viewState
    -- Their history stays as it was.
    count sc "lockstep_transactions WHERE state = 'accepted'" >>= (@?= 2)
    -- Unrelated work still runs.
    (other, _) <- project sc "other"
    _ <- approved sc other "other" (chain 1)
    passesUntil sc engine 60 ((== 3) <$> acceptedCount sc)
    count sc "lockstep_transactions" >>= (@?= 4)

lateRejection :: Assertion
lateRejection =
  withScenario $ \sc -> do
    (view, _) <- project sc "late"
    r <- approved sc view "late" (chain 2)
    engine <- engineFor sc
    passesUntil sc engine 60 ((== 1) <$> acceptedCount sc)
    -- f2's fix starts on f1's accepted commit and is under way.
    passesUntil sc engine 10 ((== 2) <$> count sc "lockstep_transactions WHERE basis_commit IS NOT NULL")
    f1 <- fixOfUnit sc r "f1"
    _ <- decide sc f1 "not-done" >>= either (\e -> assertFailure ("not done refused: " <> T.unpack e)) pure
    passesUntil sc engine 3 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted' AND halt_code = 'ancestor-rejected'")
    -- Only Stop: a retry cannot run a stage on what was rejected.
    open <- ready (openRequests (scRuntime sc))
    request <- case open of
      [q] -> pure q
      _ -> assertFailure "no open request"
    rk <- idem "retry"
    ready (postMessage (scRuntime sc) rk (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "retry" "again")) >>= (@?= Left "unknown-choice") . fmap (const ())
    sk <- idem "stop"
    _ <- accepted (ready (postMessage (scRuntime sc) sk (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "stop" "stop it")))
    passesUntil sc engine 5 ((== 2) <$> count sc "lockstep_transactions WHERE state = 'stopped'")
    acceptedCount sc >>= (@?= 0)

rework :: Assertion
rework =
  withScenario $ \sc -> do
    (view, _) <- project sc "rework"
    r <- approved sc view "rework" (chain 1)
    engine <- engineFor sc
    passesUntil sc engine 60 ((== 1) <$> acceptedCount sc)
    first <- fixOfUnit sc r "f1"
    task <- maybe (assertFailure "no task") pure (L.lookup "f1" (revisionTasks r))
    tasks <- ready (listTasks (scRuntime sc) (projectId view))
    revision <- maybe (assertFailure "no task view") (pure . taskTicketRevision) (L.find ((== task) . taskId) tasks)
    -- While the first fix counts, a second hand-over is refused.
    k1 <- idem "again-1"
    ready (admitBug (scRuntime sc) (folders sc) k1 task revision) >>= (@?= Left "already-admitted") . fmap admissionWorkOrder
    _ <- decide sc first "not-done" >>= either (\e -> assertFailure ("not done refused: " <> T.unpack e)) pure
    waitingOf sc view >>= (@?= [("f1", "stopped")])
    records <- count sc ("lockstep_transaction_records WHERE transaction_id = '" <> T.unpack (viewId first) <> "'")
    -- Once it has stopped, the task is handed over again: a new Work Order, and a fix with its own evidence.
    k2 <- idem "again-2"
    second <- accepted (ready (admitBug (scRuntime sc) (folders sc) k2 task revision))
    assertBool "the rework reused the first Work Order" (admissionWorkOrder second /= viewWorkOrder first)
    passesUntil sc engine 60 ((== 1) <$> acceptedCount sc)
    count sc "lockstep_bug_admissions" >>= (@?= 2)
    count sc "lockstep_transactions" >>= (@?= 2)
    count sc ("lockstep_transaction_records WHERE transaction_id = '" <> T.unpack (viewId first) <> "'") >>= (@?= records)
    waitingOf sc view >>= (@?= [("f1", "handed-over")])

planChangeInvalidates :: Assertion
planChangeInvalidates =
  withScenario $ \sc -> do
    (view, _) <- project sc "change"
    r <- approved sc view "change-1" (chain 1)
    engine <- engineFor sc
    passesUntil sc engine 60 ((== 1) <$> acceptedCount sc)
    f1 <- fixOfUnit sc r "f1"
    -- The owner approves a revision that changes what f1 must do.
    _ <- approved sc view "change-2" (plan [(unit 1) {unitAcceptance = [PlanCriterion "f1.value() is 1, and stays 1." ["prd"]]}] [])
    count sc "lockstep_fix_invalidations WHERE code = 'plan-changed'" >>= (@?= 1)
    waitingOf sc view >>= (@?= [("f1", "invalidated")])
    decide sc f1 "done" >>= (@?= Left "acceptance-invalidated") . fmap viewState

noNewAuthority :: Assertion
noNewAuthority =
  withScenario $ \sc -> do
    (view, _) <- project sc "authority"
    ik <- idem "external"
    refused <- ready (proposePlan (scRuntime sc) ik (projectId view) "owner-session" (LBS.fromStrict (TE.encodeUtf8 (encodePlanDocument (plan [(unit 1) {unitEffect = ExternalEffect}] [])))))
    either proposalRefusalCode (const "proposed") refused @?= "invalid-plan"
    -- A proposed revision the owner has not approved hands nothing over.
    pk <- idem "proposed-only"
    _ <- ready (proposePlan (scRuntime sc) pk (projectId view) "owner-session" (LBS.fromStrict (TE.encodeUtf8 (encodePlanDocument (chain 1)))))
    ready (dispatchOnce (scRuntime sc) (folders sc)) >>= (@?= []) . fmap reportUnit
    count sc "lockstep_bug_admissions" >>= (@?= 0)
