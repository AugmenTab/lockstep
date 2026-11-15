{-# LANGUAGE OverloadedStrings #-}

{- | Improvement proposals against real PostgreSQL (contract C-P6.9): the same
proposal is one proposal, only a person decides and only on the version they
looked at, an approval installs nothing, private proposals stay private, a
summary proposes nothing, and a fix cannot ask for its own rules to change.
-}
module Lockstep.ProposalTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
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
import Lockstep.Application.Engine (Engine (..), TransactionView (..), transactionForWorkOrder)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (Admission (..), enableExecution, findAdmission)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.ProfileDocument (encodeRawProfile)
import Lockstep.Application.Profiles (addProfile)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Proposals (ProposalView (..), decideImprovement, listProposals, proposeImprovement)
import Lockstep.Application.Summary (projectSummary)
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
    "C-P6.9 improvement proposals (real PostgreSQL)"
    [ testCase "the same proposal again, by another key or proposer, is the same proposal; a key replays only its own (P2)" duplicates
    , testCase "an approval from an agent, a Planner or the Supervisor is forged and refused; a person's is recorded once (P5)" forged
    , testCase "a decision on another version is stale, and a Profile rule on an older catalog version too (P5)" stale
    , testCase "an approval changes no Profile, choice, binding or plan (P6)" noMutation
    , testCase "a private proposal is only a person's, and is listed only in the owner's private list (P4)" privateScope
    , testCase "making a summary proposes nothing; a fix's proposal is only proposed (P6)" noAutoInstall
    , testCase "a fix cannot propose a rule for the Profile its own Work Order is bound to (P3)" selfPrivilege
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
    withSystemTempDirectory "lockstep-p69" $ \tmp -> do
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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-improvement-proposal-" <> text))

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

unit :: PlanUnit
unit =
  PlanUnit
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

plan :: PlanDocument
plan =
  PlanDocument
    { planTitle = "One value"
    , planMode = Brownfield
    , planSources = [PlanSource "prd" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
    , planEnvelope = Envelope False 10 Nothing
    , planUnits = [unit]
    , planEdges = []
    , planUncertainties = []
    }

{- | A project whose one fix is handed over and halts at its basis (an
uncommitted file), so a fix exists without any role being run. The project
and the fix's id.
-}
haltedFix :: Scenario -> IO (ProjectView, T.Text)
haltedFix sc = do
  pk <- idem "project"
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk "proposals" "" NewFolder)))
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
      halted <- count sc "lockstep_transactions WHERE state = 'halted'"
      case (halted, n) of
        (1, _) -> pure ()
        (_, 0) -> assertFailure "the fix did not halt"
        _ -> engineOnceWith (scRuntime sc) engine (folders sc) >> passes (n - 1)
  passes 30
  task <- maybe (assertFailure "no task") pure (L.lookup "f1" (revisionTasks revision))
  admission <- ready (findAdmission (scRuntime sc) task) >>= maybe (assertFailure "not handed over") pure
  fix <- ready (transactionForWorkOrder (scRuntime sc) (admissionWorkOrder admission)) >>= maybe (assertFailure "no fix") pure
  pure (view, viewId fix)

-- | A person's proposal about the commit messages, version 1 to 2.
proposal :: ProposalInput
proposal =
  ProposalInput
    { inputScope = EngineeringPractice
    , inputTarget = "commit-messages"
    , inputCurrent = "1"
    , inputProposed = "2"
    , inputTitle = "Name the test in every fix's commit message"
    , inputBenefit = "A reader finds the frozen test from the commit."
    , inputRisks = "Longer messages."
    , inputEvidence = [OfCommit "0123456789abcdef0123456789abcdef01234567"]
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

decideAs :: Scenario -> Sender -> ProposalView -> T.Text -> Decision -> IO (Either T.Text ProposalView)
decideAs sc sender p seen decision =
  ready (decideImprovement (scRuntime sc) sender (proposalId p) seen decision)

person :: Sender
person =
  SenderHuman ApplicationChannel

-- | A catalog Profile @team-checks@ at the given version.
teamChecks :: Scenario -> Integer -> IO ()
teamChecks sc version =
  ready (addProfile (scRuntime sc) (LBS.fromStrict (TE.encodeUtf8 (encodeRawProfile bugFixRaw {rawProfileId = "team-checks", rawProfileVersion = version}))))
    >>= either (const (assertFailure ("team-checks " <> show version <> " refused"))) (const (pure ()))

-- Cases ------------------------------------------------------------------------------------------

duplicates :: Assertion
duplicates =
  withScenario $ \sc -> do
    a <- proposed sc "a" proposal
    -- Another key, another proposer, the evidence repeated and the title padded: the same proposal.
    b <- proposed sc "b" proposal {inputProposer = ByPerson "someone-else", inputTitle = "  Name the test in every fix's commit message ", inputEvidence = inputEvidence proposal <> inputEvidence proposal}
    proposalId b @?= proposalId a
    proposalSupport' b @?= 1
    c <- proposed sc "a" proposal
    proposalId c @?= proposalId a
    -- The key of one proposal does not record another.
    propose sc "a" proposal {inputProposed = "3"} >>= (@?= Left ["key-conflict"])
    count sc "lockstep_improvement_proposals" >>= (@?= 1)

forged :: Assertion
forged =
  withScenario $ \sc -> do
    p <- proposed sc "forged" proposal
    traverse_
      (\sender -> decideAs sc sender p "1" ApproveProposal >>= (@?= Left "not-authorized"))
      [SenderAgent "implementer", SenderPlanner "planner", SenderSupervisor]
    count sc "lockstep_improvement_decisions" >>= (@?= 0)
    d <- decideAs sc person p "1" ApproveProposal >>= either (\e -> assertFailure ("refused: " <> T.unpack e)) pure
    proposalDecision d @?= Just "approved"
    decideAs sc person p "1" RejectProposal >>= (@?= Left "already-decided")
    count sc "lockstep_improvement_decisions" >>= (@?= 1)

stale :: Assertion
stale =
  withScenario $ \sc -> do
    p <- proposed sc "stale" proposal
    decideAs sc person p "2" ApproveProposal >>= (@?= Left "stale-target")
    teamChecks sc 1
    rule <- proposed sc "rule" proposal {inputScope = ProfileRule, inputTarget = "team-checks", inputCurrent = "1", inputProposed = "2"}
    -- The catalog moved on: version 1 is no longer the latest.
    teamChecks sc 2
    decideAs sc person rule "1" ApproveProposal >>= (@?= Left "stale-target")
    count sc "lockstep_improvement_decisions" >>= (@?= 0)
    current <- proposed sc "current" proposal {inputScope = ProfileRule, inputTarget = "team-checks", inputCurrent = "2", inputProposed = "3"}
    decideAs sc person current "2" ApproveProposal >>= either (\e -> assertFailure ("refused: " <> T.unpack e)) (\v -> proposalDecision v @?= Just "approved")

noMutation :: Assertion
noMutation =
  withScenario $ \sc -> do
    (_, fix) <- haltedFix sc
    teamChecks sc 1
    let
      tables =
        [ "lockstep_profiles"
        , "lockstep_repository_profiles"
        , "lockstep_profile_decisions"
        , "lockstep_work_order_profile_sources"
        , "lockstep_plans"
        , "lockstep_plan_revisions"
        , "lockstep_plan_decisions"
        , "lockstep_plan_units"
        , "lockstep_bug_admissions"
        , "lockstep_transactions"
        ]
      counts = traverse (count sc) tables
    before <- counts
    rule <- proposed sc "rule" proposal {inputScope = ProfileRule, inputTarget = "team-checks", inputProposed = "2", inputEvidence = [OfFix fix]}
    _ <- decideAs sc person rule "1" ApproveProposal >>= either (\e -> assertFailure ("refused: " <> T.unpack e)) pure
    after <- counts
    after @?= before

privateScope :: Assertion
privateScope =
  withScenario $ \sc -> do
    (_, fix) <- haltedFix sc
    shared <- proposed sc "shared" proposal
    private <- proposed sc "private" proposal {inputPrivate = True, inputTitle = "My own habit"}
    propose sc "from-fix" proposal {inputPrivate = True, inputTitle = "A fix's private wish", inputProposer = ByFix fix []} >>= (@?= Left ["private-scope"])
    ready (listProposals (scRuntime sc) False) >>= (@?= [proposalId shared]) . fmap proposalId
    ready (listProposals (scRuntime sc) True) >>= (@?= [proposalId private]) . fmap proposalId

noAutoInstall :: Assertion
noAutoInstall =
  withScenario $ \sc -> do
    (view, fix) <- haltedFix sc
    void (ready (projectSummary (scRuntime sc) (projectId view)))
    count sc "lockstep_improvement_proposals" >>= (@?= 0)
    p <- proposed sc "fix" proposal {inputEvidence = [OfFix fix], inputProposer = ByFix fix []}
    (proposalBy p, proposalDecision p) @?= ("fix", Nothing)
    count sc "lockstep_improvement_decisions" >>= (@?= 0)

selfPrivilege :: Assertion
selfPrivilege =
  withScenario $ \sc -> do
    (_, fix) <- haltedFix sc
    let
      fromFix target = proposal {inputScope = ProfileRule, inputTarget = target, inputEvidence = [OfFix fix], inputProposer = ByFix fix []}
    -- The fix claims it is bound to nothing; what it is bound to is read from its Work Order.
    propose sc "own" (fromFix "lockstep-bug-fix") >>= (@?= Left ["self-privilege"])
    other <- propose sc "other" (fromFix "team-checks")
    assertBool ("refused: " <> show other) (either (const False) (const True) other)
    propose sc "nobody" proposal {inputProposer = ByFix "00000000-0000-4000-8000-000000000000" []} >>= (@?= Left ["unknown-fix"])
