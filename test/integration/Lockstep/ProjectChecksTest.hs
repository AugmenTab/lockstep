{-# LANGUAGE OverloadedStrings #-}

{- | Choosing how a project's work is checked, and the read-only view of what
can start, against real PostgreSQL and real Git (contract C-P3.7 L2–L6, L8):
the operations run in this process; projects are made through C-P3.5, tasks
through C-P3.6, and work orders through C-P2.5 only to fill the queue.
-}
module Lockstep.ProjectChecksTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory)
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Ledger (NewWorkOrder (..), SchedulePreview (..), createWorkOrder, previewSchedule)
import Lockstep.Application.Profiles (ResolveRequest (..), addProfile, resolveForEngineer)
import Lockstep.Application.ProjectChecks
  ( ChecksChoice (..)
  , ChecksOutcome (..)
  , EffectiveRules (..)
  , KindRules (..)
  , ProjectChecks (..)
  , QueueEntry (..)
  , Standing (..)
  , chooseChecks
  , projectChecks
  )
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Kernel.Identity (TicketId (..), WorkOrderId (..), parseUuid, uuidText)
import Lockstep.Kernel.Profile (gateId, gateIdText)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Scheduler (Ineligibility (..), decisionEligible)
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Kernel.WorkOrder (WorkOrderKind (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, queryBool, queryInts, requireAdmin, withFreshDatabase, withRuntime)

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scRuntime :: DatabaseRuntime
  , scRoot :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p37" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        action (Scenario admin db runtime (tmp <> "/projects"))

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-checks-creation-" <> text))

-- | A project in a new folder Lockstep makes (C-P3.5): it has an Engineer and a repository.
connected :: Scenario -> T.Text -> IO ProjectView
connected sc name = do
  k <- key ("project-" <> T.filter (/= ' ') name)
  result <- ready (createProject (scRuntime sc) (ProjectFolders (Just (scRoot sc)) []) (NewProject k name "" NewFolder))
  either (\c -> assertFailure ("refused: " <> T.unpack c)) pure result

withoutFolder :: Scenario -> T.Text -> IO ProjectView
withoutFolder sc name = do
  k <- key ("project-" <> T.filter (/= ' ') name)
  result <- ready (createProject (scRuntime sc) (ProjectFolders Nothing []) (NewProject k name "" DecideLater))
  either (\c -> assertFailure ("refused: " <> T.unpack c)) pure result

checks :: Scenario -> ProjectView -> IO ProjectChecks
checks sc view =
  ready (projectChecks (scRuntime sc) (projectId view)) >>= maybe (assertFailure "the project is gone") pure

choose :: Scenario -> ProjectView -> T.Text -> T.Text -> Bool -> IO (Either T.Text ChecksOutcome)
choose sc view expected choice confirmed =
  ready (chooseChecks (scRuntime sc) (projectId view) expected choice confirmed)

currentId :: ProjectChecks -> Maybe T.Text
currentId =
  fmap choiceId . checksCurrent

count :: Scenario -> String -> IO Int
count sc table = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> table)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> table)

-- | The decision rows, as @operation:outcome[:code]@, oldest first.
decisions :: Scenario -> [T.Text] -> Assertion
decisions sc expected = do
  let
    literal t = "'" <> T.unpack t <> "'"
    wanted = if L.null expected then "ARRAY[]::text[]" else "ARRAY[" <> L.intercalate ", " (fmap literal expected) <> "]"
  same <-
    queryBool
      (scAdmin sc)
      (scDb sc)
      ("SELECT coalesce(array_agg(operation || ':' || outcome || coalesce(':' || refusal_code, '') ORDER BY id), ARRAY[]::text[]) = " <> wanted <> " AS v FROM lockstep_profile_decisions")
  assertBool ("decision rows are not " <> show expected) same

-- | A registered profile with one human-approved check on code changes only.
teamChecks :: LBS.ByteString
teamChecks =
  LBS.fromStrict . TE.encodeUtf8 $
    "{\"id\":\"team-checks\",\"version\":1,\"allows_non_behavioural\":false,\"gates\":[{\"id\":\"impact\",\"stage\":\"before-acceptance\",\"artifacts\":[\"impact-assessment\"],\"kinds\":[\"engineering\"],\"verifiers\":[\"human-inspection\"],\"approval\":\"human\"}]}"

addTeamChecks :: Scenario -> Assertion
addTeamChecks sc = do
  added <- ready (addProfile (scRuntime sc) teamChecks)
  assertBool "team-checks was not added" (either (const False) (const True) added)

-- | A ready task (C-P3.6) and its Ticket.
readyTask :: Scenario -> ProjectView -> T.Text -> T.Text -> IO TicketId
readyTask sc view k title = do
  ik <- key ("task-" <> k)
  made <- ready (createTask (scRuntime sc) (NewTask ik (projectId view) title "" Normal []))
  task <- either (\c -> assertFailure ("task refused: " <> T.unpack c)) pure made
  marked <- ready (decideTask (scRuntime sc) "test-session" (taskId task) (taskTicketRevision task) MarkReady)
  _ <- either (\c -> assertFailure ("ready refused: " <> T.unpack c)) pure marked
  either (const (assertFailure "task id")) (pure . TicketId) (parseUuid (taskId task))

workOrder :: Scenario -> ProjectView -> TicketId -> Int -> [WorkOrderId] -> IO WorkOrderId
workOrder sc view ticket priority dependencies = do
  engineer <- maybe (assertFailure "no Engineer") pure (projectEngineer view)
  created <-
    createWorkOrder
      (scRuntime sc)
      NewWorkOrder
        { newTicket = ticket
        , newEngineer = engineer
        , newKind = Engineering
        , newPriority = priority
        , newDependencies = dependencies
        , newClasses = []
        , newPathClasses = ["source"]
        , newNonBehavioural = Nothing
        }
  either (\f -> assertFailure ("work order refused: " <> show f)) pure created

orderText :: WorkOrderId -> T.Text
orderText (WorkOrderId u) =
  uuidText u

tests :: TestTree
tests =
  testGroup
    "how work is checked, and what can start (C-P3.7; real PostgreSQL)"
    [ testCase "a project without a folder cannot have checks set, and nothing is recorded" $
        withScenario $ \sc -> do
          view <- withoutFolder sc "Kitchen"
          pc <- checks sc view
          (checksSettable pc, currentId pc, L.length (checksRules pc)) @?= (False, Nothing, 0)
          choose sc view "none" "lockstep-basic" False >>= (@?= Left "project-has-no-folder")
          gone <- ready (chooseChecks (scRuntime sc) "00000000-0000-4000-8000-000000000000" "none" "lockstep-basic" False)
          gone @?= Left "unknown-project"
          missing <- ready (projectChecks (scRuntime sc) "00000000-0000-4000-8000-000000000000")
          assertBool "an unknown project has checks" (isNothing missing)
          traverse (count sc) ["lockstep_profiles", "lockstep_repository_profiles", "lockstep_profile_decisions"] >>= (@?= [0, 0, 0])
    , testCase "the built-in starting choice is offered, registered when chosen, and recorded" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          before <- checks sc view
          (checksSettable before, currentId before) @?= (True, Nothing)
          fmap (\c -> (choiceId c, choiceBuiltIn c)) (checksChoices before) @?= [("lockstep-basic", True)]
          checksQueue before @?= Right []
          choose sc view "none" "lockstep-basic" False >>= (@?= Right ChecksChosen)
          after <- checks sc view
          fmap (\c -> (choiceId c, choiceVersion c, choiceBuiltIn c)) (checksCurrent after) @?= Just ("lockstep-basic", 1, False)
          fmap (\c -> (choiceId c, choiceBuiltIn c)) (checksChoices after) @?= [("lockstep-basic", False)]
          fmap rulesKind (checksRules after) @?= [minBound .. maxBound]
          traverse_
            (either (\c -> assertFailure ("no rules: " <> T.unpack c)) (\e -> L.length (rulesChecks e) @?= 0) . rulesOutcome)
            (checksRules after)
          digest <- maybe (assertFailure "no current choice") (pure . choiceDigest) (checksCurrent after)
          stored <- queryBool (scAdmin sc) (scDb sc) ("SELECT bool_and(digest = '" <> T.unpack digest <> "' AND version = 1) AS v FROM lockstep_profiles WHERE profile_id = 'lockstep-basic'")
          assertBool "the stored digest is not the one shown" stored
          traverse (count sc) ["lockstep_profiles", "lockstep_repository_profiles"] >>= (@?= [1, 1])
          decisions sc ["profile-add:accepted", "repository-set-profile:accepted"]
    , testCase "choosing the current set again is unchanged and adds no default" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          choose sc view "none" "lockstep-basic" False >>= (@?= Right ChecksChosen)
          choose sc view "lockstep-basic" "lockstep-basic" False >>= (@?= Right ChecksUnchanged)
          count sc "lockstep_repository_profiles" >>= (@?= 1)
          decisions sc ["profile-add:accepted", "repository-set-profile:accepted", "repository-set-profile:unchanged"]
    , testCase "a stale page or an unknown set is refused, recorded, and changes nothing" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          choose sc view "none" "lockstep-basic" False >>= (@?= Right ChecksChosen)
          addTeamChecks sc
          choose sc view "none" "team-checks" False >>= (@?= Left "checks-changed")
          choose sc view "lockstep-basic" "no-such-checks" False >>= (@?= Left "profile-unknown")
          after <- checks sc view
          currentId after @?= Just "lockstep-basic"
          count sc "lockstep_repository_profiles" >>= (@?= 1)
          decisions
            sc
            [ "profile-add:accepted"
            , "repository-set-profile:accepted"
            , "profile-add:accepted"
            , "repository-set-profile:refused:checks-changed"
            , "repository-set-profile:refused:profile-unknown"
            ]
    , testCase "a stricter set needs no confirmation; a weaker one is refused until confirmed" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          choose sc view "none" "lockstep-basic" False >>= (@?= Right ChecksChosen)
          addTeamChecks sc
          offered <- checks sc view
          fmap choiceId (checksChoices offered) @?= ["lockstep-basic", "team-checks"]
          choose sc view "lockstep-basic" "team-checks" False >>= (@?= Right ChecksChosen)
          choose sc view "team-checks" "lockstep-basic" False >>= (@?= Left "fewer-checks-unconfirmed")
          kept <- checks sc view
          currentId kept @?= Just "team-checks"
          choose sc view "team-checks" "lockstep-basic" True >>= (@?= Right ChecksChosen)
          weaker <- checks sc view
          currentId weaker @?= Just "lockstep-basic"
          count sc "lockstep_repository_profiles" >>= (@?= 3)
          refused <- count sc "lockstep_profile_decisions WHERE refusal_code = 'fewer-checks-unconfirmed'"
          refused @?= 1
    , testCase "the rules for each kind of work are the effective Profile C-P2.3 resolves" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          addTeamChecks sc
          choose sc view "none" "team-checks" False >>= (@?= Right ChecksChosen)
          pc <- checks sc view
          engineer <- maybe (assertFailure "no Engineer") pure (projectEngineer view)
          let
            rulesFor kind = maybe (Left "missing") rulesOutcome (L.find ((== kind) . rulesKind) (checksRules pc))
          engineering <- either (\c -> assertFailure ("no rules: " <> T.unpack c)) pure (rulesFor Engineering)
          investigate <- either (\c -> assertFailure ("no rules: " <> T.unpack c)) pure (rulesFor Investigate)
          fmap (gateIdText . gateId) (rulesChecks engineering) @?= ["impact"]
          fmap (gateIdText . gateId) (rulesChecks investigate) @?= []
          resolved <- ready (resolveForEngineer (scRuntime sc) (ResolveRequest engineer "engineering" [] [] Nothing))
          either (const Nothing) (Just . snd) resolved @?= Just (rulesDigest engineering)
          fmap (\(level, p, v, _) -> (level, p, v)) (rulesSources engineering) @?= [("baseline", "lockstep-baseline", 1), ("repository-default", "team-checks", 1)]
    , testCase "a tampered stored set of checks is shown as unusable and cannot be chosen" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          addTeamChecks sc
          adminExecute (scAdmin sc) (T.unpack (scDb sc)) "ALTER TABLE lockstep_profiles DISABLE TRIGGER USER"
          adminExecute (scAdmin sc) (T.unpack (scDb sc)) "UPDATE lockstep_profiles SET document = replace(document, '\"human\"', '\"none\"') WHERE profile_id = 'team-checks'"
          adminExecute (scAdmin sc) (T.unpack (scDb sc)) "ALTER TABLE lockstep_profiles ENABLE TRIGGER USER"
          pc <- checks sc view
          fmap (\c -> (choiceId c, isNothing (choiceDefinition c))) (checksChoices pc) @?= [("lockstep-basic", False), ("team-checks", True)]
          choose sc view "none" "team-checks" False >>= (@?= Left "profile-integrity")
          count sc "lockstep_repository_profiles" >>= (@?= 0)
    , testCase "what can start: a high-priority piece waiting for another cannot start, and the preview writes nothing" $
        withScenario $ \sc -> do
          view <- connected sc "Website"
          other <- connected sc "Garden"
          choose sc view "none" "lockstep-basic" False >>= (@?= Right ChecksChosen)
          paper <- readyTask sc view "1" "Buy <b>paper</b>"
          menu <- readyTask sc view "2" "Print the menu"
          low <- workOrder sc view paper 200 []
          high <- workOrder sc view menu 900 [low]
          events <- count sc "lockstep_events"
          pc <- checks sc view
          checksQueue pc
            @?= Right
              [ QueueEntry (orderText low) "Buy <b>paper</b>" 200 FirstInLine
              , QueueEntry (orderText high) "Print the menu" 900 (CannotStartYet [DependencyIncomplete low])
              ]
          elsewhere <- checks sc other
          checksQueue elsewhere @?= Right []
          preview <- previewSchedule (scRuntime sc)
          fmap (decisionEligible . previewDecision) preview @?= Right [low]
          count sc "lockstep_events" >>= (@?= events)
          count sc "lockstep_schedule_decisions" >>= (@?= 0)
          pending <- count sc "lockstep_subjects WHERE kind = 'work-order' AND state = 'pending'"
          pending @?= 2
    ]
