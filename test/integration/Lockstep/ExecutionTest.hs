{-# LANGUAGE OverloadedStrings #-}

{- | Letting Lockstep work in a project and handing it a bug, against real
PostgreSQL and real Git (contract C-P4.1 X2–X9, X12): the operations run in
this process; projects are made through C-P3.5, tasks through C-P3.6, checks
chosen through C-P3.7. The scheduler step and Work Unit admission are called
by the test only, to show that a bug needs no plan.
-}
module Lockstep.ExecutionTest
  ( tests
  ) where

import Control.Exception (SomeException, try)
import Control.Monad ((>=>))
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory, renameDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Execution
  ( Admission (..)
  , Enablement (..)
  , ExecutionStatus (..)
  , admitBug
  , enableExecution
  , executionStatus
  , findAdmission
  )
import Lockstep.Application.Ledger (ScheduleReceipt (..), admitWorkUnit, scheduleOnce)
import Lockstep.Application.Profiles (ResolveRequest (..), addProfile, resolveForEngineer, sha256Hasher)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), ExpectedChecks (..), chooseChecks)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Repositories (addEngineer)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask, findTask)
import Lockstep.Kernel.Execution (bugCheckIds, bugFixDefinition)
import Lockstep.Kernel.Identity (WorkOrderId (..), parseUuid, uuidText)
import Lockstep.Kernel.Profile (contentDigestText, profileRef, refDigest)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, queryBool, queryInts, requireAdmin, withFreshDatabase, withRuntime)

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scRuntime :: DatabaseRuntime
  , scRoot :: FilePath
  , scElsewhere :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p41" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/elsewhere")
        action (Scenario admin db runtime (tmp <> "/projects") (tmp <> "/elsewhere"))

-- | The projects folder, and one folder added from elsewhere (C-P3.5).
folders :: Scenario -> ProjectFolders
folders sc =
  ProjectFolders (Just (scRoot sc)) [scElsewhere sc <> "/site"]

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-execution-key-" <> text))

gitIn :: FilePath -> [String] -> IO ()
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Lockstep Test", "-c", "user.email=test@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  result <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case result of
    Nothing -> assertFailure ("git " <> show args <> " did not finish within 30 s")
    Just (code, out, err) -> assertBool ("git " <> show args <> " failed: " <> out <> err) (code == ExitSuccess)

-- | A project in a new folder Lockstep makes inside the projects folder (C-P3.5).
connected :: Scenario -> T.Text -> IO ProjectView
connected sc name = do
  k <- key ("project-" <> T.filter (/= ' ') name)
  result <- ready (createProject (scRuntime sc) (folders sc) (NewProject k name "" NewFolder))
  either (\c -> assertFailure ("refused: " <> T.unpack c)) pure result

withoutFolder :: Scenario -> T.Text -> IO ProjectView
withoutFolder sc name = do
  k <- key ("project-" <> T.filter (/= ' ') name)
  result <- ready (createProject (scRuntime sc) (folders sc) (NewProject k name "" DecideLater))
  either (\c -> assertFailure ("refused: " <> T.unpack c)) pure result

-- | A project connected to the folder added from elsewhere (a Git folder outside the projects folder).
addedElsewhere :: Scenario -> T.Text -> IO ProjectView
addedElsewhere sc name = do
  gitIn (scElsewhere sc) ["init", "-q", "site"]
  k <- key ("project-" <> T.filter (/= ' ') name)
  result <- ready (createProject (scRuntime sc) (folders sc) (NewProject k name "" (ExistingFolder (T.pack (scElsewhere sc <> "/site")))))
  view <- either (\c -> assertFailure ("refused: " <> T.unpack c)) pure result
  projectFolder view @?= Just (T.pack (scElsewhere sc <> "/site"))
  pure view

status :: Scenario -> ProjectView -> IO (Maybe ExecutionStatus)
status sc view =
  ready (executionStatus (scRuntime sc) (folders sc) (projectId view))

enable :: Scenario -> T.Text -> ProjectView -> ExpectedChecks -> IO (Either T.Text Enablement)
enable sc k view expected = do
  ik <- key ("enable-" <> k)
  ready (enableExecution (scRuntime sc) (folders sc) ik (projectId view) expected)

enabled :: Scenario -> ProjectView -> IO Enablement
enabled sc view =
  enable sc (T.filter (/= ' ') (projectName view)) view ExpectNothing >>= either (\c -> assertFailure ("not allowed: " <> T.unpack c)) pure

admit :: Scenario -> T.Text -> TaskView -> Int -> IO (Either T.Text Admission)
admit sc k t expected = do
  ik <- key ("admit-" <> k)
  ready (admitBug (scRuntime sc) (folders sc) ik (taskId t) expected)

task :: Scenario -> ProjectView -> T.Text -> T.Text -> Priority -> [T.Text] -> IO TaskView
task sc view k title priority dependencies = do
  ik <- key ("task-" <> k)
  made <- ready (createTask (scRuntime sc) (NewTask ik (projectId view) title "It works again." priority dependencies))
  either (\c -> assertFailure ("task refused: " <> T.unpack c)) pure made

decide :: Scenario -> TaskView -> TaskDecision -> IO TaskView
decide sc t decision = do
  decided <- ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) decision)
  either (\c -> assertFailure ("task decision refused: " <> T.unpack c)) pure decided

readyTask :: Scenario -> ProjectView -> T.Text -> T.Text -> Priority -> IO TaskView
readyTask sc view k title priority = do
  t <- task sc view k title priority []
  decide sc t MarkReady

choose :: Scenario -> ProjectView -> T.Text -> T.Text -> Bool -> IO (Either T.Text ChecksOutcome)
choose sc view expected choice confirmed =
  ready (chooseChecks (scRuntime sc) (projectId view) expected choice confirmed)

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

countsAre :: Scenario -> Int -> [String] -> Assertion
countsAre sc n =
  traverse_ (count sc >=> (@?= n))

holds :: Scenario -> String -> String -> Assertion
holds sc message query = do
  ok <- queryBool (scAdmin sc) (scDb sc) query
  assertBool message ok

-- | The C-P2.3 decision rows, as @operation:outcome[:code]@, oldest first.
decisions :: Scenario -> [T.Text] -> Assertion
decisions sc expected = do
  let
    literal t = "'" <> T.unpack t <> "'"
    wanted = if L.null expected then "ARRAY[]::text[]" else "ARRAY[" <> L.intercalate ", " (fmap literal expected) <> "]"
  holds
    sc
    ("profile decision rows are not " <> show expected)
    ("SELECT coalesce(array_agg(operation || ':' || outcome || coalesce(':' || refusal_code, '') ORDER BY id), ARRAY[]::text[]) = " <> wanted <> " AS v FROM lockstep_profile_decisions")

-- | The id of the repository default currently in force for the project's repository.
defaultOf :: Scenario -> ProjectView -> String -> Assertion
defaultOf sc view expected =
  holds
    sc
    ("the repository default is not " <> expected)
    ( "SELECT (SELECT rp.profile_id FROM lockstep_repository_profiles rp JOIN lockstep_repositories r ON r.id = rp.repository_id JOIN lockstep_engineers e ON e.id = r.owner_engineer_id WHERE e.name = '"
        <> maybe "" T.unpack (projectEngineer view)
        <> "' ORDER BY rp.id DESC LIMIT 1) = '"
        <> expected
        <> "' AS v"
    )

bugDigest :: IO T.Text
bugDigest =
  either (const (assertFailure "the Bug Profile is not valid")) (pure . contentDigestText . refDigest . profileRef sha256Hasher) bugFixDefinition

-- | A registered profile that contains the five bug checks unchanged and one more.
teamBugs :: LBS.ByteString
teamBugs =
  LBS.fromStrict . TE.encodeUtf8 $
    "{\"id\":\"team-bugs\",\"version\":1,\"gates\":["
      <> "{\"id\":\"bug-reproduction\",\"stage\":\"before-acceptance\",\"artifacts\":[\"reproduction\"],\"kinds\":[\"engineering\"],\"classes\":[\"bug\"],\"verifiers\":[\"deterministic-command\"],\"approval\":\"supervisor\",\"exception_path\":true},"
      <> "{\"id\":\"bug-requirements\",\"stage\":\"before-acceptance\",\"artifacts\":[\"impact-assessment\",\"requirements-basis\"],\"kinds\":[\"engineering\"],\"classes\":[\"bug\"],\"verifiers\":[\"digest-check\"],\"approval\":\"supervisor\"},"
      <> "{\"id\":\"bug-regression-test\",\"stage\":\"before-acceptance\",\"artifacts\":[\"frozen-tests\"],\"kinds\":[\"engineering\"],\"classes\":[\"bug\"],\"verifiers\":[\"deterministic-command\",\"digest-check\"],\"approval\":\"supervisor\"},"
      <> "{\"id\":\"bug-verification\",\"stage\":\"before-acceptance\",\"artifacts\":[\"regression-evidence\",\"verification-record\"],\"kinds\":[\"engineering\"],\"classes\":[\"bug\"],\"verifiers\":[\"deterministic-command\"],\"approval\":\"supervisor\"},"
      <> "{\"id\":\"bug-review\",\"stage\":\"before-acceptance\",\"artifacts\":[\"review-record\"],\"kinds\":[\"engineering\"],\"classes\":[\"bug\"],\"verifiers\":[\"independent-review\"],\"approval\":\"supervisor\"},"
      <> "{\"id\":\"docs\",\"stage\":\"before-completion\",\"artifacts\":[\"documentation\"],\"verifiers\":[\"human-inspection\"],\"approval\":\"human\"}"
      <> "]}"

-- | A registered profile with one human-approved check and none of the bug checks.
teamChecks :: LBS.ByteString
teamChecks =
  LBS.fromStrict . TE.encodeUtf8 $
    "{\"id\":\"team-checks\",\"version\":1,\"gates\":[{\"id\":\"impact\",\"stage\":\"before-acceptance\",\"artifacts\":[\"impact-assessment\"],\"kinds\":[\"engineering\"],\"verifiers\":[\"human-inspection\"],\"approval\":\"human\"}]}"

register :: Scenario -> LBS.ByteString -> Assertion
register sc document = do
  added <- ready (addProfile (scRuntime sc) document)
  assertBool "the profile was not added" (isRight added)

immutable :: Scenario -> String -> Assertion
immutable sc statement = do
  result <- try (adminExecute (scAdmin sc) (T.unpack (scDb sc)) statement) :: IO (Either SomeException ())
  case result of
    Left e -> assertBool (statement <> ": failed, but not by the trigger: " <> show e) ("rows are immutable" `L.isInfixOf` show e)
    Right () -> assertFailure ("statement succeeded: " <> statement)

workOrderId :: Admission -> IO WorkOrderId
workOrderId a =
  either (const (assertFailure "work order id")) (pure . WorkOrderId) (parseUuid (admissionWorkOrder a))

tests :: TestTree
tests =
  testGroup
    "letting Lockstep work in a project and handing it a bug (C-P4.1; real PostgreSQL and Git)"
    [ testCase "a project without a folder: Lockstep may not work in it, and nothing is recorded" $
        withScenario $ \sc -> do
          view <- withoutFolder sc "Kitchen"
          status sc view >>= (@?= Just NeedsFolder)
          enable sc "kitchen" view ExpectNothing >>= (@?= Left "project-has-no-folder")
          ik <- key "enable-unknown"
          ready (enableExecution (scRuntime sc) (folders sc) ik "00000000-0000-4000-8000-000000000000" ExpectNothing) >>= (@?= Left "unknown-project")
          ready (executionStatus (scRuntime sc) (folders sc) "00000000-0000-4000-8000-000000000000") >>= (@?= Nothing)
          count sc "lockstep_execution_enablements" >>= (@?= 0)
          decisions sc []
    , testCase "a folder added from elsewhere is only read: allowing Lockstep to work in it is refused" $
        withScenario $ \sc -> do
          view <- addedElsewhere sc "Site"
          status sc view >>= (@?= Just FolderReadOnly)
          enable sc "site" view ExpectNothing >>= (@?= Left "folder-read-only")
          count sc "lockstep_execution_enablements" >>= (@?= 0)
          decisions sc []
    , testCase "an organized, connected project is not allowed by itself: handing it a ready task is refused, and nothing is created" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          status sc view >>= (@?= Just (NotEnabled Nothing))
          t <- readyTask sc view "menu" "The menu link is broken" High
          admit sc "menu" t (taskTicketRevision t) >>= (@?= Left "execution-not-enabled")
          countsAre sc 0 ["lockstep_work_orders", "lockstep_bug_admissions", "lockstep_execution_enablements"]
    , testCase "allowing registers the Bug Profile, applies it to the project, and records who, where and under which checks" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          e <- enabled sc view
          digest <- bugDigest
          ( enablementProject e
            , enablementEngineer e
            , Just (enablementFolder e)
            , enablementChecks e
            , enablementChecksVersion e
            , enablementChecksDigest e
            , enablementActor e
            )
            @?= (projectId view, fromMaybe "" (projectEngineer view), projectFolder view, "lockstep-bug-fix", 1, digest, "application-session")
          status sc view >>= (@?= Just (Enabled e))
          decisions sc ["profile-add:accepted", "repository-set-profile:accepted"]
          defaultOf sc view "lockstep-bug-fix"
          holds sc "the enablement is not for the project's repository" ("SELECT bool_and(x.repository_id = r.id) AS v FROM lockstep_execution_enablements x JOIN lockstep_repositories r ON r.id = x.repository_id JOIN lockstep_engineers e ON e.id = r.owner_engineer_id WHERE e.name = '" <> maybe "" T.unpack (projectEngineer view) <> "'")
          count sc "lockstep_execution_enablements" >>= (@?= 1)
          count sc "lockstep_profiles WHERE profile_id = 'lockstep-bug-fix' AND version = 1" >>= (@?= 1)
    , testCase "allowing is replayed by its key; another key is already-enabled; the same key elsewhere or for another request is key-conflict" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          other <- connected sc "Garden"
          first <- enable sc "same" view ExpectNothing
          again <- enable sc "same" view ExpectNothing
          again @?= first
          enable sc "same" other ExpectNothing >>= (@?= Left "key-conflict")
          enable sc "same" view (ExpectProfile "lockstep-bug-fix") >>= (@?= Left "key-conflict")
          enable sc "second" view (ExpectProfile "lockstep-bug-fix") >>= (@?= Left "already-enabled")
          count sc "lockstep_execution_enablements" >>= (@?= 1)
    , testCase "from the always-on rules only the project switches to the Bug Profile; checks that already hold the bug checks are kept" $
        withScenario $ \sc -> do
          basic <- connected sc "Website"
          choose sc basic "none" "lockstep-basic" False >>= (@?= Right ChecksChosen)
          e <- enable sc "basic" basic (ExpectProfile "lockstep-basic") >>= either (\c -> assertFailure ("refused: " <> T.unpack c)) pure
          enablementChecks e @?= "lockstep-bug-fix"
          defaultOf sc basic "lockstep-bug-fix"
          register sc teamBugs
          team <- connected sc "Garden"
          choose sc team "none" "team-bugs" False >>= (@?= Right ChecksChosen)
          kept <- enable sc "team" team (ExpectProfile "team-bugs") >>= either (\c -> assertFailure ("refused: " <> T.unpack c)) pure
          enablementChecks kept @?= "team-bugs"
          defaultOf sc team "team-bugs"
    , testCase "checks without the bug checks are never removed: bug-checks-missing, and nothing changes" $
        withScenario $ \sc -> do
          register sc teamChecks
          view <- connected sc "Website"
          choose sc view "none" "team-checks" False >>= (@?= Right ChecksChosen)
          enable sc "team" view (ExpectProfile "team-checks") >>= (@?= Left "bug-checks-missing")
          defaultOf sc view "team-checks"
          count sc "lockstep_execution_enablements" >>= (@?= 0)
          count sc "lockstep_profiles WHERE profile_id = 'lockstep-bug-fix'" >>= (@?= 0)
    , testCase "a stale page is refused: checks-changed" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          enable sc "stale" view (ExpectProfile "lockstep-basic") >>= (@?= Left "checks-changed")
          choose sc view "none" "lockstep-basic" False >>= (@?= Right ChecksChosen)
          enable sc "stale-2" view ExpectNothing >>= (@?= Left "checks-changed")
          count sc "lockstep_execution_enablements" >>= (@?= 0)
    , testCase "a replaced folder is repository-changed; a registration owned by another Engineer is ownership-invalid" $
        withScenario $ \sc -> do
          replaced <- connected sc "Website"
          folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder replaced)
          renameDirectory (folder <> "/.git") (folder <> "/.git-before")
          gitIn folder ["init", "-q"]
          enable sc "replaced" replaced ExpectNothing >>= (@?= Left "repository-changed")
          taken <- connected sc "Garden"
          made <- ready (addEngineer (scRuntime sc) "someone-else")
          assertBool "the other Engineer was not added" (isRight made)
          adminExecute
            (scAdmin sc)
            (T.unpack (scDb sc))
            ( "UPDATE lockstep_repositories SET owner_engineer_id = (SELECT id FROM lockstep_engineers WHERE name = 'someone-else') WHERE owner_engineer_id = (SELECT id FROM lockstep_engineers WHERE name = '"
                <> maybe "" T.unpack (projectEngineer taken)
                <> "')"
            )
          enable sc "taken" taken ExpectNothing >>= (@?= Left "ownership-invalid")
          count sc "lockstep_execution_enablements" >>= (@?= 0)
    , testCase "handing over: a task not ready, waiting, blocked, or shown at an old revision is refused, and nothing is created" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          _ <- enabled sc view
          proposed <- task sc view "proposed" "Not yet looked at" Normal []
          admit sc "proposed" proposed (taskTicketRevision proposed) >>= (@?= Left "task-not-ready")
          first <- task sc view "first" "Buy paper" Normal []
          waiting <- task sc view "waiting" "Print the menu" Normal [taskId first] >>= \t -> decide sc t MarkReady
          admit sc "waiting" waiting (taskTicketRevision waiting) >>= (@?= Left "task-waiting")
          blocked <- readyTask sc view "blocked" "Fix the logo" High >>= \t -> decide sc t (BlockTask "no paper")
          admit sc "blocked" blocked (taskTicketRevision blocked) >>= (@?= Left "task-blocked")
          stale <- readyTask sc view "stale" "Fix the footer" Normal
          admit sc "stale" stale (taskTicketRevision stale - 1) >>= (@?= Left "stale-revision")
          admit sc "range" stale (-1) >>= (@?= Left "revision-out-of-range")
          countsAre sc 0 ["lockstep_work_orders", "lockstep_bug_admissions"]
    , testCase "a ready task becomes one bug Work Order under the Bug Profile, for the project's own Engineer and repository" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          _ <- enabled sc view
          t <- readyTask sc view "menu" "The menu link is broken" High
          a <- admit sc "menu" t (taskTicketRevision t) >>= either (\c -> assertFailure ("refused: " <> T.unpack c)) pure
          (admissionTask a, admissionProject a, admissionActor a) @?= (taskId t, projectId view, "application-session")
          engineer <- maybe (assertFailure "no Engineer") pure (projectEngineer view)
          resolved <- ready (resolveForEngineer (scRuntime sc) (ResolveRequest engineer "engineering" ["bug"] [] Nothing))
          (rendering, digest) <- either (const (assertFailure "the effective checks could not be resolved")) pure resolved
          admissionEffectiveDigest a @?= digest
          traverse_ (\g -> assertBool ("the effective checks lack " <> T.unpack g) (("gate " <> g <> " ") `T.isInfixOf` rendering)) bugCheckIds
          holds
            sc
            "the work order is not the bug for the project's Engineer and repository"
            ( "SELECT count(*) = 1 AS v FROM lockstep_work_orders w JOIN lockstep_repositories r ON r.id = w.repository_id JOIN lockstep_engineers e ON e.id = r.owner_engineer_id WHERE w.id = '"
                <> T.unpack (admissionWorkOrder a)
                <> "' AND w.ticket_id = '"
                <> T.unpack (taskId t)
                <> "' AND w.kind = 'engineering' AND w.classes = 'bug' AND w.path_classes = '' AND w.priority = 800 AND w.effective_digest = '"
                <> T.unpack digest
                <> "' AND e.name = '"
                <> T.unpack engineer
                <> "'"
            )
          after <- ready (findTask (scRuntime sc) (taskId t)) >>= maybe (assertFailure "the task is gone") pure
          (taskState after, taskTicketRevision after) @?= ("ready", taskTicketRevision t)
          ready (findAdmission (scRuntime sc) (taskId t)) >>= (@?= Just a)
    , testCase "handing over is replayed by its key; other content is key-conflict; a second key is already-admitted; one Work Order" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          _ <- enabled sc view
          t <- readyTask sc view "menu" "The menu link is broken" Normal
          first <- admit sc "same" t (taskTicketRevision t)
          assertBool "not admitted" (isRight first)
          admit sc "same" t (taskTicketRevision t) >>= (@?= first)
          admit sc "same" t (taskTicketRevision t + 1) >>= (@?= Left "key-conflict")
          admit sc "second" t (taskTicketRevision t) >>= (@?= Left "already-admitted")
          countsAre sc 1 ["lockstep_work_orders", "lockstep_bug_admissions"]
    , testCase "once the checks are switched back to the always-on rules, the next bug is refused: bug-checks-missing" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          _ <- enabled sc view
          choose sc view "lockstep-bug-fix" "lockstep-basic" False >>= (@?= Left "fewer-checks-unconfirmed")
          choose sc view "lockstep-bug-fix" "lockstep-basic" True >>= (@?= Right ChecksChosen)
          status sc view >>= \s -> assertBool "no longer allowed after a change of checks" (case s of Just (Enabled _) -> True; _ -> False)
          t <- readyTask sc view "menu" "The menu link is broken" Normal
          admit sc "menu" t (taskTicketRevision t) >>= (@?= Left "bug-checks-missing")
          count sc "lockstep_work_orders" >>= (@?= 0)
    , testCase "nothing runs: no schedule decision, claim, effect, job or Work Unit" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          _ <- enabled sc view
          t <- readyTask sc view "menu" "The menu link is broken" Normal
          _ <- admit sc "menu" t (taskTicketRevision t) >>= either (\c -> assertFailure ("refused: " <> T.unpack c)) pure
          countsAre sc 0 ["lockstep_schedule_decisions", "lockstep_effect_intents", "lockstep_jobs", "lockstep_work_units"]
          count sc "lockstep_subjects WHERE kind = 'work-order' AND state = 'pending'" >>= (@?= 1)
    , testCase "no plan is needed: the existing scheduler step claims the bug, its Work Unit has no plan reference, and no column names a phase" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          _ <- enabled sc view
          t <- readyTask sc view "menu" "The menu link is broken" Normal
          a <- admit sc "menu" t (taskTicketRevision t) >>= either (\c -> assertFailure ("refused: " <> T.unpack c)) pure
          w <- workOrderId a
          receipt <- scheduleOnce (scRuntime sc) >>= either (\f -> assertFailure ("schedule refused: " <> show f)) pure
          fmap fst (scheduleClaimed receipt) @?= Just w
          unit <- admitWorkUnit (scRuntime sc) w Nothing
          assertBool ("no Work Unit: " <> show unit) (isRight unit)
          count sc "lockstep_work_units WHERE plan_ref IS NULL" >>= (@?= 1)
          count sc ("lockstep_work_units WHERE work_order_id = '" <> T.unpack (admissionWorkOrder a) <> "' AND ticket_id = '" <> T.unpack (taskId t) <> "'") >>= (@?= 1)
          count sc "information_schema.columns WHERE table_name LIKE 'lockstep%' AND column_name LIKE '%phase%'" >>= (@?= 0)
          count sc "information_schema.columns WHERE table_name LIKE 'lockstep%' AND column_name LIKE '%plan%' AND NOT (table_name = 'lockstep_work_units' AND column_name = 'plan_ref')" >>= (@?= 0)
          (\(WorkOrderId u) -> uuidText u) w @?= admissionWorkOrder a
    , testCase "the records are immutable" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          _ <- enabled sc view
          t <- readyTask sc view "menu" "The menu link is broken" Normal
          _ <- admit sc "menu" t (taskTicketRevision t)
          traverse_
            ( \table -> do
                immutable sc ("UPDATE " <> table <> " SET actor = 'someone'")
                immutable sc ("DELETE FROM " <> table)
                immutable sc ("TRUNCATE " <> table)
            )
            ["lockstep_execution_enablements", "lockstep_bug_admissions"]
          countsAre sc 1 ["lockstep_execution_enablements", "lockstep_bug_admissions"]
    ]
