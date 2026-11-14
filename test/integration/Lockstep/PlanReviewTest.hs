{-# LANGUAGE OverloadedStrings #-}

{- | Remediation of the independent review of C-P6.4 (R-P6.4), against real
PostgreSQL: a later approval never overwrites a person's edits; a withdrawn
unit's task cannot be handed over until the unit returns; a rejected or
superseded plan may be proposed again; an acceptance that would not fit a task
and an uncited criterion are refused at proposal; two approvals at once
decide once.
-}
module Lockstep.PlanReviewTest
  ( tests
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
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
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Execution (admitBug, enableExecution)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), ProposalRefusal (..), RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskEdit (..), TaskView (..), createTask, editTask, listTasks)
import Lockstep.Kernel.Plan (EdgeKind (..), EffectClass (..), Envelope (..), PlanCriterion (..), PlanDocument (..), PlanEdge (..), PlanMode (..), PlanSource (..), PlanUnit (..), RiskClass (..), UnitKey, mkUnitKey)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Task (Priority (..), TaskReadiness (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "R-P6.4 remediation of the C-P6.4 review (real PostgreSQL)"
    [ testCase "R-P6.4-1: a later approval leaves a kept unit's task as the person edited it, keeps the person's own dependencies, and refuses to overwrite an edited task whose unit changed (locally-edited)" personEdits
    , testCase "R-P6.4-2: a withdrawn unit's task is blocked by the approval and cannot be handed over; when the unit returns, the same task is ready again" withdrawn
    , testCase "R-P6.4-4: a rejected plan, or an earlier approved one, may be proposed again as a new revision; the effective or pending one may not" proposeAgain
    , testCase "R-P6.4-5, R-P6.4-9: an acceptance that would not fit a task, and a criterion that cites nothing, are refused when proposed" refusedAtProposal
    , testCase "R-P6.4-12: two approvals of one revision at once decide it once and write its units once" concurrentApprovals
    ]

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
    withSystemTempDirectory "lockstep-p64r" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-plan-review-" <> text))

gitIn :: FilePath -> [String] -> IO ()
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  finished <- timeout 30000000 (Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) "")
  case finished of
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git " <> show args <> ": " <> show (fmap (\(c, o, e) -> (show c, o, e)) other))

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

sha :: T.Text -> T.Text
sha text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

k :: T.Text -> UnitKey
k text =
  case mkUnitKey text of
    Just u -> u
    Nothing -> k "invalid-key-in-test"

project :: Scenario -> T.Text -> IO ProjectView
project sc name = do
  pk <- idem ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/README.md") "start\n"
  gitIn folder ["add", "README.md"]
  gitIn folder ["commit", "-q", "-m", "start"]
  pure view

unit :: T.Text -> PlanUnit
unit name =
  PlanUnit (k name) ("Build the " <> name) "P1" "P1.1" "feature" "lockstep-bug-fix" Normal LocalOnly RiskNormal True [] [PlanCriterion ("The " <> name <> " works.") ["prd"]] [] [] [] []

plan :: [PlanUnit] -> [PlanEdge] -> PlanDocument
plan units edges =
  PlanDocument "Plan" Brownfield [PlanSource "prd" (sha "the PRD")] (Envelope False 10 Nothing) units edges []

propose :: Scenario -> ProjectView -> T.Text -> PlanDocument -> IO (Either ProposalRefusal RevisionView)
propose sc view name p = do
  ik <- idem name
  ready (proposePlan (scRuntime sc) ik (projectId view) "owner-session" (LBS.fromStrict (TE.encodeUtf8 (encodePlanDocument p))))

decide :: Scenario -> ProjectView -> RevisionView -> PlanDecision -> IO (Either T.Text RevisionView)
decide sc view r =
  ready . decidePlan (scRuntime sc) "owner-session" (projectId view) (revisionNumber r) (revisionDigest r)

taskNamed :: Scenario -> ProjectView -> T.Text -> IO TaskView
taskNamed sc view title = do
  ts <- ready (listTasks (scRuntime sc) (projectId view))
  maybe (assertFailure ("no task " <> T.unpack title)) pure (L.find ((== title) . taskTitle) ts)

personEdits :: Assertion
personEdits =
  withScenario $ \sc -> do
    view <- project sc "edits"
    -- cli needs core only for the owner's acceptance, so a change of core leaves cli kept (not invalidated).
    r1 <- accepted (propose sc view "one" (plan [unit "core", unit "cli"] [PlanEdge (k "cli") (k "core") HumanAcceptance]))
    _ <- accepted (decide sc view r1 ApprovePlan)
    hk <- idem "own-task"
    own <- accepted (ready (createTask (scRuntime sc) (NewTask hk (projectId view) "My own check" "It is checked." Normal [])))
    cli <- taskNamed sc view "Build the cli"
    core <- taskNamed sc view "Build the core"
    edited <- accepted (ready (editTask (scRuntime sc) (taskId cli) (taskRevision cli) (TaskEdit "Build the cli" "The cli works, and exits 2 on bad input." Normal [taskId core, taskId own])))
    -- Revision 2 changes only the core: the cli unit is kept, and its task stays as the person left it.
    r2 <- accepted (propose sc view "two" (plan [(unit "core") {unitTitle = "Build the parser core"}, unit "cli"] [PlanEdge (k "cli") (k "core") HumanAcceptance]))
    a2 <- accepted (decide sc view r2 ApprovePlan)
    L.lookup "cli" (revisionReconciliation a2) @?= Just "kept"
    cliAfter <- taskNamed sc view "Build the cli"
    taskAcceptance cliAfter @?= "The cli works, and exits 2 on bad input."
    L.sort (taskDependencies cliAfter) @?= L.sort [taskId core, taskId own]
    taskRevision cliAfter @?= taskRevision edited
    -- The changed core unit's task, untouched by the person, follows the plan.
    coreAfter <- taskNamed sc view "Build the parser core"
    taskId coreAfter @?= taskId core
    -- Revision 3 changes the cli unit, whose task the person edited: refused, nothing written.
    r3 <- accepted (propose sc view "three" (plan [(unit "core") {unitTitle = "Build the parser core"}, (unit "cli") {unitTitle = "Build the command line"}] [PlanEdge (k "cli") (k "core") HumanAcceptance]))
    decide sc view r3 ApprovePlan >>= (@?= Left "locally-edited")
    count sc "lockstep_plan_decisions" >>= (@?= 2)
    cliStill <- taskNamed sc view "Build the cli"
    taskAcceptance cliStill @?= "The cli works, and exits 2 on bad input."

withdrawn :: Assertion
withdrawn =
  withScenario $ \sc -> do
    view <- project sc "withdrawn"
    ek <- idem "enable"
    _ <- accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing))
    r1 <- accepted (propose sc view "one" (plan [unit "core", unit "extra"] []))
    _ <- accepted (decide sc view r1 ApprovePlan)
    extra <- taskNamed sc view "Build the extra"
    r2 <- accepted (propose sc view "two" (plan [unit "core"] []))
    a2 <- accepted (decide sc view r2 ApprovePlan)
    L.lookup "extra" (revisionReconciliation a2) @?= Just "withdrawn"
    blocked <- taskNamed sc view "Build the extra"
    taskState blocked @?= "blocked"
    case taskReadinessOf blocked of
      BlockedBecause why -> assertBool ("not said withdrawn: " <> T.unpack why) ("withdrawn" `T.isInfixOf` why)
      other -> assertFailure ("not blocked: " <> show other)
    ak <- idem "admit"
    ready (admitBug (scRuntime sc) (folders sc) ak (taskId blocked) (taskTicketRevision blocked)) >>= (@?= Left "task-blocked") . fmap (const ())
    -- The unit returns: the same task, ready again.
    r3 <- accepted (propose sc view "three" (plan [unit "core", unit "extra"] []))
    _ <- accepted (decide sc view r3 ApprovePlan)
    back <- taskNamed sc view "Build the extra"
    taskId back @?= taskId extra
    (taskState back, taskReadinessOf back) @?= ("ready", ReadyToWork)

proposeAgain :: Assertion
proposeAgain =
  withScenario $ \sc -> do
    view <- project sc "again"
    let
      a = plan [unit "core"] []
      b = plan [unit "core", unit "cli"] []
    r1 <- accepted (propose sc view "a1" a)
    _ <- accepted (decide sc view r1 RejectPlan)
    r2 <- accepted (propose sc view "a2" a)
    revisionNumber r2 @?= 2
    -- Pending: the same plan again is already-proposed.
    propose sc view "a3" a >>= (@?= Left (ProposalRefusal "already-proposed" []))
    _ <- accepted (decide sc view r2 ApprovePlan)
    -- Effective: also already-proposed.
    propose sc view "a4" a >>= (@?= Left (ProposalRefusal "already-proposed" []))
    r3 <- accepted (propose sc view "b1" b)
    _ <- accepted (decide sc view r3 ApprovePlan)
    -- The earlier approved plan, now superseded, may come back as a new revision.
    r4 <- accepted (propose sc view "a5" a)
    (revisionNumber r4, revisionDigest r4) @?= (4, revisionDigest r1)
    a4 <- accepted (decide sc view r4 ApprovePlan)
    revisionState a4 @?= "approved"
    -- cli is no longer in the plan: withdrawn, its task kept.
    L.lookup "cli" (revisionReconciliation a4) @?= Just "withdrawn"

refusedAtProposal :: Assertion
refusedAtProposal =
  withScenario $ \sc -> do
    view <- project sc "refused"
    let
      long = T.replicate 4001 "x"
    propose sc view "long" (plan [(unit "core") {unitAcceptance = [PlanCriterion long ["prd"]]}] [])
      >>= (@?= Left (ProposalRefusal "invalid-plan" ["invalid-acceptance: core"]))
    propose sc view "control" (plan [(unit "core") {unitAcceptance = [PlanCriterion "bell \a here" ["prd"]]}] [])
      >>= (@?= Left (ProposalRefusal "invalid-plan" ["invalid-acceptance: core"]))
    propose sc view "uncited" (plan [(unit "core") {unitAcceptance = [PlanCriterion "It works." []]}] [])
      >>= (@?= Left (ProposalRefusal "invalid-plan" ["uncited-criterion: core"]))
    count sc "lockstep_plan_revisions" >>= (@?= 0)

concurrentApprovals :: Assertion
concurrentApprovals =
  withScenario $ \sc -> do
    view <- project sc "race"
    r <- accepted (propose sc view "one" (plan [unit "core", unit "cli"] []))
    config <- databaseConfigFor (scAdmin sc) (scDb sc)
    doneA <- newEmptyMVar
    doneB <- newEmptyMVar
    let
      approveIn rt = decidePlan rt "owner-session" (projectId view) (revisionNumber r) (revisionDigest r) ApprovePlan
    _ <- forkIO (withRuntime config approveIn >>= putMVar doneA)
    _ <- forkIO (withRuntime config approveIn >>= putMVar doneB)
    a <- takeMVar doneA
    b <- takeMVar doneB
    L.sort [either (const "not-ready") (either id (const "approved")) x | x <- [a, b]] @?= ["already-decided", "approved"]
    count sc "lockstep_plan_decisions" >>= (@?= 1)
    count sc "lockstep_plan_units" >>= (@?= 2)
    count sc "lockstep_project_tasks" >>= (@?= 2)
