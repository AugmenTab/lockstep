{-# LANGUAGE OverloadedStrings #-}

{- | The independent review of C-P6.5 (R-P6.5), against real PostgreSQL, Git
and processes with scripted roles: the basis of a dependent fix when its
prerequisite is marked Done or Not done after the hand-over, two fixes it
needs that do not contain each other, a hand-over that is not the decision's
next unit, a stopped unit's waiting reason, a refused hand-over shown and
recorded once, and the S1 edges that a technical acceptance does not satisfy.
-}
module Lockstep.DispatchReviewTest
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
import Lockstep.Application.Dispatch (DispatchReport (..), DispatchView (..), dispatchOnce, dispatchView, handOverUnit)
import Lockstep.Application.Engine (Engine (..), TransactionView (..), decideCompletion, transactionForWorkOrder)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (Admission (..), enableExecution, findAdmission)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
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
    "R-P6.5 review of continuous scheduling (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a prerequisite marked Done after its dependent was handed over: the dependent is still built on its accepted commit, with its provenance (R-P6.5-1)" doneBeforeBasis
    , testCase "a prerequisite marked Not done after its dependent was handed over: the dependent halts at its basis prerequisite-unsatisfied (R-P6.5-1)" notDoneBeforeBasis
    , testCase "two accepted fixes a fix needs that do not contain each other: it halts at its basis basis-ambiguous, recording nothing (S8)" diamond
    , testCase "a hand-over of a unit that is not the decision's next one is refused not-next and writes nothing (R-P6.5-3, R-P6.5-4)" notNext
    , testCase "a stopped unit waits as stopped, its dependent as waiting-for (R-P6.5-5)" stoppedReason
    , testCase "a refused hand-over is recorded once and shown as refused; once it can be made, it is (R-P6.5-6)" refusedShown
    , testCase "a technical acceptance satisfies neither a technical edge on a unit that is not provisional nor a human-acceptance edge (S1)" edgesThatWait
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

-- | f2 needs f1 (technical, provisional): f1 accepted, then f2 handed over and not yet started.
handedOverAfterAcceptance :: Scenario -> T.Text -> IO (Engine, RevisionView)
handedOverAfterAcceptance sc name = do
  (view, _) <- project sc name
  r <- approved sc view name (plan [unit 1, unit 2] [PlanEdge (k "f2") (k "f1") Technical])
  engine <- engineFor sc
  passesUntil sc engine 60 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'accepted'")
  reports <- ready (dispatchOnce (scRuntime sc) (folders sc))
  fmap reportUnit reports @?= ["f2"]
  count sc "lockstep_transactions" >>= (@?= 1)
  pure (engine, r)

-- Cases ------------------------------------------------------------------------------------------

doneBeforeBasis :: Assertion
doneBeforeBasis =
  withScenario $ \sc -> do
    (engine, r) <- handedOverAfterAcceptance sc "done"
    f1 <- fixOfUnit sc r "f1"
    _ <- accepted (ready (decideCompletion (scRuntime sc) (viewId f1) (SenderHuman ApplicationChannel) "done"))
    passesUntil sc engine 5 ((== 2) <$> count sc "lockstep_transactions WHERE basis_commit IS NOT NULL")
    basisFollows sc "f1" "f2" >>= assertBool "f2's fix did not start from f1's accepted commit after f1 was marked Done"
    count sc "lockstep_fix_bases" >>= (@?= 1)

notDoneBeforeBasis :: Assertion
notDoneBeforeBasis =
  withScenario $ \sc -> do
    (engine, r) <- handedOverAfterAcceptance sc "not-done"
    f1 <- fixOfUnit sc r "f1"
    _ <- accepted (ready (decideCompletion (scRuntime sc) (viewId f1) (SenderHuman ApplicationChannel) "not-done"))
    passesUntil sc engine 5 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    f2 <- fixOfUnit sc r "f2"
    (viewState f2, viewHalt f2, viewBasis f2) @?= ("halted", Just "prerequisite-unsatisfied", Nothing)
    count sc "lockstep_fix_bases" >>= (@?= 0)

diamond :: Assertion
diamond =
  withScenario $ \sc -> do
    (view, _) <- project sc "diamond"
    r <- approved sc view "diamond" (plan [unit 1, unit 2, unit 3] [PlanEdge (k "f3") (k "f1") Technical, PlanEdge (k "f3") (k "f2") Technical])
    engine <- engineFor sc
    passesUntil sc engine 120 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    count sc "lockstep_transactions WHERE state = 'accepted'" >>= (@?= 2)
    f3 <- fixOfUnit sc r "f3"
    (viewHalt f3, viewBasis f3) @?= (Just "basis-ambiguous", Nothing)
    count sc "lockstep_fix_bases" >>= (@?= 0)

notNext :: Assertion
notNext =
  withScenario $ \sc -> do
    (view, _) <- project sc "two"
    r <- approved sc view "two" (plan [unit 1, unit 2] [])
    ready (dispatchOnce (scRuntime sc) (folders sc)) >>= (@?= ["f1"]) . fmap reportUnit
    -- f1 holds the project's one writer: f2 is not the next unit.
    ready (handOverUnit (scRuntime sc) (folders sc) (projectId view) (revisionDigest r) "f2") >>= (@?= Left "not-next")
    count sc "lockstep_bug_admissions" >>= (@?= 1)
    count sc "lockstep_plan_dispatches" >>= (@?= 1)
    -- A plan with a token budget hands over nothing, also when asked directly.
    (budgeted, _) <- project sc "budgeted"
    b <- approved sc budgeted "budgeted" (plan [unit 1] []) {planEnvelope = Envelope False 10 (Just 100000)}
    ready (handOverUnit (scRuntime sc) (folders sc) (projectId budgeted) (revisionDigest b) "f1") >>= (@?= Left "not-next")
    count sc "lockstep_bug_admissions" >>= (@?= 1)

stoppedReason :: Assertion
stoppedReason =
  withScenario $ \sc -> do
    (view, folder) <- project sc "stopped"
    _ <- approved sc view "stopped" (plan [unit 1, unit 2] [PlanEdge (k "f2") (k "f1") Technical])
    -- An uncommitted file: f1's fix halts at its basis; the person stops it.
    writeFile (folder <> "/notes.txt") "uncommitted\n"
    engine <- engineFor sc
    passesUntil sc engine 10 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    open <- ready (openRequests (scRuntime sc))
    request <- case open of
      [q] -> pure q
      _ -> assertFailure "no open request"
    sk <- idem "stop"
    _ <- accepted (ready (postMessage (scRuntime sc) sk (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "stop" "stop this fix")))
    passesUntil sc engine 10 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'stopped'")
    v <- accepted (ready (dispatchView (scRuntime sc) (projectId view)))
    (dispatchViewNext v, dispatchViewWaiting v) @?= (Nothing, [("f1", "stopped"), ("f2", "waiting-for")])

refusedShown :: Assertion
refusedShown =
  withScenario $ \sc -> do
    (view, _) <- project sc "refused"
    _ <- approved sc view "refused" (plan [unit 1] [])
    -- Lockstep is given a projects folder that does not hold the project's: the hand-over is refused.
    let
      elsewhere = ProjectFolders (Just (scTmp sc <> "/elsewhere")) []
    first <- ready (dispatchOnce (scRuntime sc) elsewhere)
    fmap (\x -> (reportUnit x, reportResult x)) first @?= [("f1", Left "folder-read-only")]
    -- The same refusal again is not reported or recorded again.
    ready (dispatchOnce (scRuntime sc) elsewhere) >>= (@?= []) . fmap reportUnit
    count sc "lockstep_plan_dispatch_refusals" >>= (@?= 1)
    v <- accepted (ready (dispatchView (scRuntime sc) (projectId view)))
    (dispatchViewNext v, dispatchViewWaiting v) @?= (Nothing, [("f1", "refused")])
    assertBool "the refusal has no words" (L.any (\(u, w) -> u == "f1" && "could not hand it over" `T.isInfixOf` w) (dispatchViewWords v))
    -- With the right folder it is handed over.
    ready (dispatchOnce (scRuntime sc) (folders sc)) >>= (@?= ["f1"]) . fmap reportUnit
    after <- accepted (ready (dispatchView (scRuntime sc) (projectId view)))
    dispatchViewWaiting after @?= [("f1", "handed-over")]

edgesThatWait :: Assertion
edgesThatWait =
  withScenario $ \sc -> do
    (firm, _) <- project sc "firm"
    (signed, _) <- project sc "signed"
    _ <- approved sc firm "firm" (plan [(unit 1) {unitProvisional = False}, unit 2] [PlanEdge (k "f2") (k "f1") Technical])
    _ <- approved sc signed "signed" (plan [unit 1, unit 2] [PlanEdge (k "f2") (k "f1") HumanAcceptance])
    engine <- engineFor sc
    passesUntil sc engine 60 ((== 2) <$> count sc "lockstep_transactions WHERE state = 'accepted'")
    traverse_ (const (engineOnceWith (scRuntime sc) engine (folders sc))) [1 :: Int .. 3]
    count sc "lockstep_bug_admissions" >>= (@?= 2)
    traverse_
      ( \p -> do
          v <- accepted (ready (dispatchView (scRuntime sc) (projectId p)))
          (dispatchViewNext v, dispatchViewWaiting v) @?= (Nothing, [("f1", "handed-over"), ("f2", "waiting-for")])
      )
      [firm, signed]
