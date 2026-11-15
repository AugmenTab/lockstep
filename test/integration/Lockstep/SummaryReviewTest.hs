{-# LANGUAGE OverloadedStrings #-}

{- | The independent review of C-P6.8 (R-P6.8) against real PostgreSQL, Git
and processes with scripted roles: a reworked fix's outcomes are those of its
current candidate; a fix handed over but not started is not eligible; a halted
fix's evidence names its halt and its open request; an inconclusive
verification is not a failure; and a rework keeps the earlier fix's
interventions and usage.
-}
module Lockstep.SummaryReviewTest
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
import Lockstep.Application.Conversation (Channel (..), Sender (..), StoredRequest (..), openRequests)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Dispatch (dispatchOnce)
import Lockstep.Application.Engine (Engine (..), TransactionView (..), decideCompletion, transactionForWorkOrder)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution, findAdmission)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Summary (InterventionItem (..), ProjectSummary (..), SummaryItem (..), projectSummary)
import Lockstep.Application.Tasks (TaskView (..), listTasks)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter (..), Workspace (..), directRunner, scriptedAdapter)
import Lockstep.Kernel.Plan
  ( EffectClass (..)
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
import Lockstep.Kernel.Summary (Category (..), Checks (..), Evidence (..), Intervention (..), ReviewOutcome (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "R-P6.8 review of the evidence-linked summary (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a reworked fix: its verification is the current candidate's, and the earlier candidate's rejection is not its review (R-P6.8-1)" reworkedOutcomes
    , testCase "a fix handed over but not started is not eligible (R-P6.8-4)" handedOverNotEligible
    , testCase "a halted fix's evidence names its halt record and its open request (R-P6.8-5)" haltedEvidence
    , testCase "a verification that could not run is not-run, never failed (R-P6.8-8)" inconclusiveVerification
    , testCase "a rework keeps the earlier fix's interventions and usage (R-P6.8-3)" reworkKeepsHistory
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
    -- The Planner's helper reports its usage as the Claude CLI does, on standard output.
    discovery =
      "{\"stdout\":"
        <> jsonString "{\"type\":\"result\",\"usage\":{\"input_tokens\":120,\"output_tokens\":30,\"cache_creation_input_tokens\":7,\"cache_read_input_tokens\":900}}\n"
        <> "},"
        <> result
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
            <> "\"verification\":"
            <> verification
            <> ",\"tests\":[{\"path\":\""
            <> testFile
            <> "\",\"content\":"
            <> jsonString ("import unittest\nimport " <> f <> "\n\n\nclass TestValue(unittest.TestCase):\n    def test_value(self):\n        self.assertEqual(" <> f <> ".value(), " <> T.pack (show n) <> ", '" <> wrong <> "')\n")
            <> ",\"expect\":\"red\",\"argv\":[\"python3\",\"-m\",\"unittest\",\"test_"
            <> f
            <> "\"],\"signature\":\""
            <> wrong
            <> "\"}]}"
        )
    -- Unit 3's verification needs a program this computer does not have: inconclusive, never failed.
    verification =
      if n == 3
        then "[[\"lockstep-no-such-program\"]]"
        else "[[\"python3\",\"-m\",\"unittest\",\"test_" <> f <> "\"]]"
    fixes = "{\"write\":{\"path\":\"" <> file <> "\",\"content\":" <> jsonString ("def value():\n    return " <> T.pack (show n) <> "\n") <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"value returns its number\"}"
    -- Unit 2's second attempt makes another candidate commit.
    fixesAgain = "{\"write\":{\"path\":\"" <> file <> "\",\"content\":" <> jsonString ("def value():\n    return " <> T.pack (show n) <> "  # again\n") <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"value returns its number, again\"}"
    noFindings = result "{\"kind\":\"challenge\",\"findings\":[]}"
    approve = result ("{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"read it\"],\"inspected\":[" <> jsonString file <> "," <> jsonString testFile <> "]}")
    reject = result ("{\"kind\":\"review\",\"verdict\":\"reject\",\"reasons\":[\"not like this\"],\"inspected\":[" <> jsonString file <> "," <> jsonString testFile <> "]}")
  in
    case role of
      Planner -> [discovery, candidate]
      Challenger -> [noFindings, noFindings, noFindings]
      -- Unit 2: the first candidate is rejected; the second is verified and its review never comes (no script).
      Implementer -> if n == 2 then [fixes, fixesAgain] else [fixes]
      Reviewer -> if n == 2 then [reject] else [approve]

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

summaryOf :: Scenario -> ProjectView -> IO ProjectSummary
summaryOf sc view =
  ready (projectSummary (scRuntime sc) (projectId view)) >>= maybe (assertFailure "no summary for the project") pure

itemOf :: ProjectSummary -> T.Text -> IO SummaryItem
itemOf s title =
  maybe (assertFailure ("no item " <> T.unpack title)) pure (L.find ((== title) . summaryTitle) (summaryItems s))

-- | One unit's plan in a fresh project.
oneUnit :: Scenario -> T.Text -> Int -> IO (ProjectView, FilePath, RevisionView)
oneUnit sc name n = do
  (view, folder) <- project sc name
  r <- approved sc view name (plan [unit n] [])
  pure (view, folder, r)

-- Cases ------------------------------------------------------------------------------------------

reworkedOutcomes :: Assertion
reworkedOutcomes =
  withScenario $ \sc -> do
    (view, _, _) <- oneUnit sc "rework" 2
    engine <- engineFor sc
    -- The first candidate is rejected; the second is verified; its review never comes, so the fix halts at review.
    passesUntil sc engine 80 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted' AND stage = 'review'")
    i <- summaryOf sc view >>= (`itemOf` "Make f2 return 2")
    (summaryCategory i, summaryChecks i, summaryReview i) @?= (CategoryAwaitingPerson, ChecksPassed, ReviewNotRun)

handedOverNotEligible :: Assertion
handedOverNotEligible =
  withScenario $ \sc -> do
    (view, _, _) <- oneUnit sc "queued" 1
    -- Handed over by the scheduler, and not yet started by the engine.
    _ <- ready (dispatchOnce (scRuntime sc) (folders sc))
    count sc "lockstep_bug_admissions" >>= (@?= 1)
    count sc "lockstep_transactions" >>= (@?= 0)
    i <- summaryOf sc view >>= (`itemOf` "Make f1 return 1")
    summaryCategory i @?= CategoryWaiting

haltedEvidence :: Assertion
haltedEvidence =
  withScenario $ \sc -> do
    (view, folder, _) <- oneUnit sc "halted" 1
    writeFile (folder <> "/notes.txt") "uncommitted\n"
    engine <- engineFor sc
    passesUntil sc engine 10 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    s <- summaryOf sc view
    i <- itemOf s "Make f1 return 1"
    open <- ready (openRequests (scRuntime sc))
    let
      requests = [r | OfRequest r <- summaryEvidence i]
    requests @?= fmap storedRequestId open
    assertBool "no halt record among the evidence" (L.any isRecord (summaryEvidence i))
    fmap snd (summaryPending s) @?= fmap (OfRequest . storedRequestId) open
 where
  isRecord e =
    case e of
      OfRecord _ _ -> True
      _ -> False

inconclusiveVerification :: Assertion
inconclusiveVerification =
  withScenario $ \sc -> do
    (view, _, _) <- oneUnit sc "missing" 3
    engine <- engineFor sc
    passesUntil sc engine 60 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    count sc "lockstep_transactions WHERE halt_code = 'verification-environment-missing'" >>= (@?= 1)
    i <- summaryOf sc view >>= (`itemOf` "Make f3 return 3")
    summaryChecks i @?= ChecksNotRun

reworkKeepsHistory :: Assertion
reworkKeepsHistory =
  withScenario $ \sc -> do
    (view, _, r) <- oneUnit sc "history" 1
    engine <- engineFor sc
    passesUntil sc engine 60 ((== 1) <$> acceptedCount sc)
    first <- fixOfUnit sc r "f1"
    _ <- decide sc first "not-done" >>= either (\e -> assertFailure ("not done refused: " <> T.unpack e)) pure
    before <- summaryOf sc view
    -- The person hands the task over again; the new fix has not started.
    task <- maybe (assertFailure "no task") pure (L.lookup "f1" (revisionTasks r))
    tasks <- ready (listTasks (scRuntime sc) (projectId view))
    revision <- maybe (assertFailure "no task view") (pure . taskTicketRevision) (L.find ((== task) . taskId) tasks)
    ak <- idem "again"
    _ <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak task revision))
    after <- summaryOf sc view
    fmap (\x -> (interventionWhat x, interventionKind x)) (summaryInterventions after) @?= [("not-done", NecessaryIntervention)]
    (summaryUsage after, summaryRuns after, summaryRunsUnknown after) @?= (summaryUsage before, summaryRuns before, summaryRunsUnknown before)
