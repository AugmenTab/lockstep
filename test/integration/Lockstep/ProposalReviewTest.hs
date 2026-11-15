{-# LANGUAGE OverloadedStrings #-}

{- | The independent review of C-P6.9 (R-P6.9), against real PostgreSQL:
evidence resolves to Lockstep's own rows in one canonical spelling, a
Profile-rule proposal names a catalog Profile at its latest version when it is
made, and only resolvable proposals are recorded.
-}
module Lockstep.ProposalReviewTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (listToMaybe)
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
import Lockstep.Application.Engine (Engine (..), RecordView (..), TransactionView (..), transactionForWorkOrder, transactionView)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (Admission (..), enableExecution, findAdmission)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.ProfileDocument (encodeRawProfile)
import Lockstep.Application.Profiles (addProfile)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Proposals (ProposalView (..), decideImprovement, proposeImprovement)
import Lockstep.Application.Summary (ProjectSummary (..), projectSummary)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (directRunner)
import Lockstep.Kernel.Execution (bugFixRaw)
import Lockstep.Kernel.Plan
  ( EffectClass (..)
  , Envelope (..)
  , PlanCriterion (..)
  , PlanDocument (..)
  , PlanMode (..)
  , PlanSource (..)
  , PlanUnit (..)
  , RiskClass (..)
  , UnitKey
  , mkUnitKey
  )
import Lockstep.Kernel.Profile (RawProfile (..))
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Proposal (Decision (..), ProposalInput (..), Proposer (..), Scope (..))
import Lockstep.Kernel.Summary (Evidence (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "R-P6.9 the review of improvement proposals (real PostgreSQL)"
    [ testCase "evidence that names no fix, record, invalidation or request of Lockstep's, or no full commit, is refused (R-P6.9-1)" unresolved
    , testCase "evidence that resolves is accepted: the fix, its record, its open request (R-P6.9-1)" resolved
    , testCase "the same link in another spelling is the same link: counted once, the same proposal (R-P6.9-2)" spelling
    , testCase "a Profile rule for a catalog Profile names its latest version when proposed (R-P6.9-4)" profileRule
    , testCase "a proposal recorded with resolved evidence is decided as recorded (R-P6.9-3)" decidable
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
    withSystemTempDirectory "lockstep-p69r" $ \tmp -> do
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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-proposal-review-" <> text))

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

gitIn :: FilePath -> [String] -> IO ()
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
    Just (code, out, err) -> assertBool ("git " <> show args <> " failed: " <> out <> err) (code == ExitSuccess)

k :: T.Text -> UnitKey
k text =
  case mkUnitKey text of
    Just u -> u
    Nothing -> k "invalid-key-in-test"

plan :: PlanDocument
plan =
  PlanDocument
    { planTitle = "One value"
    , planMode = Brownfield
    , planSources = [PlanSource "prd" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
    , planEnvelope = Envelope False 10 Nothing
    , planUnits =
        [ PlanUnit
            { unitKey = k "f1"
            , unitTitle = "Make f1 return 1"
            , unitPhase = "P1"
            , unitSubphase = "P1.1"
            , unitWorkKind = "bug-fix"
            , unitProfile = "lockstep-bug-fix"
            , unitPriority = Normal
            , unitEffect = LocalOnly
            , unitRisk = RiskLow
            , unitProvisional = True
            , unitOutputs = ["f1.py"]
            , unitAcceptance = [PlanCriterion "f1.value() is 1." ["prd"]]
            , unitNegative = []
            , unitChecks = []
            , unitPrerequisites = []
            , unitResources = []
            }
        ]
    , planEdges = []
    , planUncertainties = []
    }

-- | A fix halted at its basis (an uncommitted file): the fix, its halt record's number, and its open request.
data Halted
  = Halted
  { haltedFix :: T.Text
  , haltedRecord :: Int
  , haltedRequest :: T.Text
  }

halted :: Scenario -> IO Halted
halted sc = do
  pk <- idem "project"
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk "proposal-review" "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/f1.py") "def value():\n    return 0\n"
  gitIn folder ["add", "f1.py"]
  gitIn folder ["commit", "-q", "-m", "start"]
  ek <- idem "enable"
  void (accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing)))
  writeFile (folder <> "/notes.txt") "uncommitted\n"
  ik <- idem "plan"
  r <- accepted (ready (proposePlan (scRuntime sc) ik (projectId view) "owner-session" (LBS.fromStrict (TE.encodeUtf8 (encodePlanDocument plan)))))
  revision <- accepted (ready (decidePlan (scRuntime sc) "owner-session" (projectId view) (revisionNumber r) (revisionDigest r) ApprovePlan))
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    engine = Engine runner (\_ _ -> Nothing)
    passes :: Int -> IO ()
    passes n = do
      h <- count sc "lockstep_transactions WHERE state = 'halted'"
      case (h, n) of
        (1, _) -> pure ()
        (_, 0) -> assertFailure "the fix did not halt"
        _ -> engineOnceWith (scRuntime sc) engine (folders sc) >> passes (n - 1)
  passes 30
  task <- maybe (assertFailure "no task") pure (L.lookup "f1" (revisionTasks revision))
  admission <- ready (findAdmission (scRuntime sc) task) >>= maybe (assertFailure "not handed over") pure
  fix <- ready (transactionForWorkOrder (scRuntime sc) (admissionWorkOrder admission)) >>= maybe (assertFailure "no fix") pure
  full <- ready (transactionView (scRuntime sc) (viewId fix)) >>= maybe (assertFailure "no fix view") pure
  record <- maybe (assertFailure "the fix has no record") (pure . recordSequence) (listToMaybe (L.reverse (viewRecords full)))
  summary <- ready (projectSummary (scRuntime sc) (projectId view)) >>= maybe (assertFailure "no summary") pure
  request <-
    case [q | (_, OfRequest q) <- summaryPending summary] of
      [q] -> pure q
      other -> assertFailure ("expected one open request, got " <> show other)
  pure (Halted (viewId fix) record request)

proposal :: [Evidence] -> ProposalInput
proposal evidence =
  ProposalInput
    { inputScope = TestAdequacy
    , inputTarget = "regression-tests"
    , inputCurrent = "1"
    , inputProposed = "2"
    , inputTitle = "Freeze a regression test for every halt at the basis"
    , inputBenefit = "A halt at the basis is reproduced before it is fixed."
    , inputRisks = "One more test per halt."
    , inputEvidence = evidence
    , inputPrivate = False
    , inputProposer = ByPerson "owner-session"
    }

propose :: Scenario -> T.Text -> ProposalInput -> IO (Either [T.Text] ProposalView)
propose sc key input = do
  ik <- idem key
  ready (proposeImprovement (scRuntime sc) ik input)

proposed :: Scenario -> T.Text -> ProposalInput -> IO ProposalView
proposed sc key input =
  propose sc key input >>= either (\e -> assertFailure ("proposal refused: " <> show e)) pure

teamChecks :: Scenario -> Integer -> IO ()
teamChecks sc version =
  ready (addProfile (scRuntime sc) (LBS.fromStrict (TE.encodeUtf8 (encodeRawProfile bugFixRaw {rawProfileId = "team-checks", rawProfileVersion = version}))))
    >>= either (const (assertFailure ("team-checks " <> show version <> " refused"))) (const (pure ()))

nobody :: T.Text
nobody =
  "00000000-0000-4000-8000-000000000000"

-- Cases ------------------------------------------------------------------------------------------

unresolved :: Assertion
unresolved =
  withScenario $ \sc -> do
    h <- halted sc
    let
      fix = haltedFix h
      cases =
        [ ("no-fix", OfFix nobody)
        , ("not-an-id", OfFix "a-fix")
        , ("no-record", OfRecord fix 9999)
        , ("record-of-nothing", OfRecord nobody 1)
        , ("no-invalidation", OfInvalidation fix)
        , ("no-request", OfRequest nobody)
        , ("free-text-commit", OfCommit "trust-me")
        , ("short-commit", OfCommit "0123456")
        ]
    traverse_
      (\(name, e) -> propose sc name (proposal [OfFix fix, e]) >>= (@?= Left ["evidence-unknown"]))
      cases
    count sc "lockstep_improvement_proposals" >>= (@?= 0)

resolved :: Assertion
resolved =
  withScenario $ \sc -> do
    h <- halted sc
    p <- proposed sc "resolved" (proposal [OfFix (haltedFix h), OfRecord (haltedFix h) (haltedRecord h), OfRequest (haltedRequest h)])
    proposalSupport' p @?= 3

spelling :: Assertion
spelling =
  withScenario $ \sc -> do
    h <- halted sc
    let
      fix = haltedFix h
      sha = "0123456789abcdef0123456789abcdef01234567"
    a <- proposed sc "lower" (proposal [OfFix fix, OfCommit sha])
    b <- proposed sc "upper" (proposal [OfFix (T.toUpper fix), OfFix fix, OfCommit (T.toUpper sha)])
    proposalId b @?= proposalId a
    proposalSupport' b @?= 2
    count sc "lockstep_improvement_proposals" >>= (@?= 1)

profileRule :: Assertion
profileRule =
  withScenario $ \sc -> do
    h <- halted sc
    let
      rule target current = (proposal [OfFix (haltedFix h)]) {inputScope = ProfileRule, inputTarget = target, inputCurrent = current, inputProposed = "9"}
    teamChecks sc 1
    teamChecks sc 2
    propose sc "older" (rule "team-checks" "1") >>= (@?= Left ["stale-target"])
    propose sc "spelled" (rule "team-checks" "v2") >>= (@?= Left ["stale-target"])
    p <- proposed sc "latest" (rule "team-checks" "2")
    proposalTarget p @?= "team-checks"
    count sc "lockstep_improvement_proposals" >>= (@?= 1)

decidable :: Assertion
decidable =
  withScenario $ \sc -> do
    h <- halted sc
    p <- proposed sc "decidable" (proposal [OfRequest (T.toUpper (haltedRequest h)), OfRecord (haltedFix h) (haltedRecord h)])
    d <- ready (decideImprovement (scRuntime sc) (SenderHuman ApplicationChannel) (proposalId p) "1" RejectProposal)
    fmap proposalDecision d @?= Right (Just "rejected")
