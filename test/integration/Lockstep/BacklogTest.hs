{-# LANGUAGE OverloadedStrings #-}

{- | Importing and exporting a project's backlog against real PostgreSQL and
real Git (contract C-P6.1 B1, B3–B11, B13): the operations run in this
process; projects through C-P3.5, tasks through C-P3.6, hand-over through
C-P4.1. An imported item is an ordinary proposed task; nothing an import does
creates a Work Order, schedules or runs anything.
-}
module Lockstep.BacklogTest
  ( tests
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory)
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Backlog (ImportReport (..), TaskSource (..), exportBacklog, importBacklog, importBacklogDocument, taskSources)
import Lockstep.Application.BacklogJira (fromJiraSearch)
import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Execution (Admission (..), Enablement (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskEdit (..), TaskView (..), createTask, decideTask, editTask, findTask, listTasks)
import Lockstep.Kernel.Backlog (Criterion (..), ImportDecision (..), ItemOutcome (..), ItemRefusal (..), SourceProvider (..), mkSourceLocator, sourceKeyText)
import Lockstep.Kernel.Identity (RepositoryId (..), uuidText)
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
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p61" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        action (Scenario admin db runtime (tmp <> "/projects"))

folders :: Scenario -> ProjectFolders
folders sc =
  ProjectFolders (Just (scRoot sc)) []

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-backlog-key-" <> text))

-- | A project with no folder ("decide later"), so no repository.
unbound :: Scenario -> T.Text -> IO ProjectView
unbound sc name = do
  k <- key ("project-" <> T.filter (/= ' ') name)
  made <- ready (createProject (scRuntime sc) (folders sc) (NewProject k name "" DecideLater))
  either (\c -> assertFailure ("refused: " <> T.unpack c)) pure made

-- | A project in a new folder Lockstep makes (C-P3.5), so it has a repository.
connected :: Scenario -> T.Text -> IO ProjectView
connected sc name = do
  k <- key ("project-" <> T.filter (/= ' ') name)
  made <- ready (createProject (scRuntime sc) (folders sc) (NewProject k name "" NewFolder))
  either (\c -> assertFailure ("refused: " <> T.unpack c)) pure made

enabled :: Scenario -> ProjectView -> IO Enablement
enabled sc view = do
  ik <- key ("enable-" <> T.filter (/= ' ') (projectName view))
  ready (enableExecution (scRuntime sc) (folders sc) ik (projectId view) ExpectNothing) >>= either (\c -> assertFailure ("not enabled: " <> T.unpack c)) pure

item :: T.Text -> Int -> T.Text -> [T.Text] -> T.Text
item k r title blockers =
  "{\"key\":\""
    <> k
    <> "\",\"revision\":"
    <> T.pack (show r)
    <> ",\"title\":\""
    <> title
    <> "\",\"acceptance\":[{\"text\":\"It works for "
    <> k
    <> "\",\"ref\":\""
    <> k
    <> " AC1\"},{\"text\":\"Nothing else breaks\"}],\"blockers\":["
    <> T.intercalate "," (fmap (\b -> "\"" <> b <> "\"") blockers)
    <> "]}"

documentFor :: T.Text -> Maybe T.Text -> Int -> [T.Text] -> LBS.ByteString
documentFor locator repository r items =
  LBS.fromStrict . TE.encodeUtf8 $
    "{\"format\":\"lockstep-backlog\",\"version\":1,\"source\":{\"provider\":\"canonical\",\"locator\":\""
      <> locator
      <> "\"},\"revision\":"
      <> T.pack (show r)
      <> maybe "" (\u -> ",\"repository\":\"" <> u <> "\"") repository
      <> ",\"items\":["
      <> T.intercalate "," items
      <> "]}"

document :: Int -> [T.Text] -> LBS.ByteString
document =
  documentFor "caesura-notes" Nothing

threeItems :: [T.Text]
threeItems =
  [ item "CAE-1" 1 "Play a sleep track" []
  , item "CAE-2" 1 "Fade out at the end" ["CAE-1"]
  , item "CAE-3" 1 "Remember the last track" ["CAE-1", "CAE-2"]
  ]

importInto :: Scenario -> ProjectView -> LBS.ByteString -> IO (Either T.Text ImportReport)
importInto sc view bytes =
  ready (importBacklog (scRuntime sc) (projectId view) bytes)

imported :: Scenario -> ProjectView -> LBS.ByteString -> IO ImportReport
imported sc view bytes =
  importInto sc view bytes >>= either (\c -> assertFailure ("import refused: " <> T.unpack c)) pure

outcomesOf :: ImportReport -> [(T.Text, ItemOutcome)]
outcomesOf report =
  [(sourceKeyText k, o) | (k, o) <- decisionItems (reportDecision report)]

tasksOf :: Scenario -> ProjectView -> IO [TaskView]
tasksOf sc view =
  ready (listTasks (scRuntime sc) (projectId view))

-- | The project's task whose title this is.
titled :: Scenario -> ProjectView -> T.Text -> IO TaskView
titled sc view title = do
  ts <- tasksOf sc view
  case L.filter ((== title) . taskTitle) ts of
    [t] -> pure t
    other -> assertFailure ("tasks titled " <> T.unpack title <> ": " <> show (L.length other))

titleOfDependency :: [TaskView] -> T.Text -> T.Text
titleOfDependency ts dependency =
  maybe "<unknown>" taskTitle (L.find ((== dependency) . taskId) ts)

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

countsAre :: Scenario -> Int -> [String] -> Assertion
countsAre sc n =
  traverse_ (\q -> count sc q >>= \c -> assertBool (q <> ": " <> show c <> " rows, not " <> show n) (c == n))

holds :: Scenario -> String -> String -> Assertion
holds sc message query = do
  ok <- queryBool (scAdmin sc) (scDb sc) query
  assertBool message ok

-- | Nothing an import does creates or runs work.
nothingRuns :: Scenario -> Assertion
nothingRuns sc =
  countsAre sc 0 ["lockstep_work_orders", "lockstep_bug_admissions", "lockstep_schedule_decisions", "lockstep_work_units", "lockstep_transactions", "lockstep_effect_intents", "lockstep_jobs"]

immutable :: Scenario -> String -> Assertion
immutable sc statement = do
  result <- try (adminExecute (scAdmin sc) (T.unpack (scDb sc)) statement) :: IO (Either SomeException ())
  case result of
    Left e -> assertBool (statement <> ": failed, but not by the trigger: " <> show e) ("rows are immutable" `L.isInfixOf` show e)
    Right () -> assertFailure ("statement succeeded: " <> statement)

tests :: TestTree
tests =
  testGroup
    "importing and exporting a project's backlog (C-P6.1; real PostgreSQL)"
    [ testCase "a first import makes proposed tasks with their dependencies, acceptance and provenance, one audit row, and runs nothing" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          report <- imported sc view (document 7 threeItems)
          outcomesOf report @?= [("CAE-1", ItemCreated), ("CAE-2", ItemCreated), ("CAE-3", ItemCreated)]
          reportRendered report
            @?= T.unlines ["lockstep-backlog-import 1", "source canonical caesura-notes revision 7", "item CAE-1 created", "item CAE-2 created", "item CAE-3 created"]
          ts <- tasksOf sc view
          L.length ts @?= 3
          traverse_ (\t -> (taskTitle t, taskState t, taskPriority t) @?= (taskTitle t, "proposed", 500)) ts
          third <- titled sc view "Remember the last track"
          L.sort (fmap (titleOfDependency ts) (taskDependencies third)) @?= ["Fade out at the end", "Play a sleep track"]
          first <- titled sc view "Play a sleep track"
          taskAcceptance first @?= "- It works for CAE-1 (CAE-1 AC1)\n- Nothing else breaks"
          taskDependencies first @?= []
          L.sort (fmap snd (reportTasks report)) @?= L.sort (fmap taskKey ts)
          countsAre sc 1 ["lockstep_backlog_sources", "lockstep_backlog_imports"]
          countsAre sc 3 ["lockstep_task_sources", "lockstep_project_tasks", "lockstep_tickets"]
          nothingRuns sc
    , testCase "imported acceptance keeps its criteria, their references and the revision they came from (B8)" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          _ <- imported sc view (document 7 threeItems)
          sources <- ready (taskSources (scRuntime sc) (projectId view))
          first <- titled sc view "Play a sleep track"
          case L.filter ((== taskKey first) . taskSourceTask) sources of
            [s] -> do
              (taskSourceProvider s, taskSourceLocator s, taskSourceKey s, taskSourceRevision s) @?= (ProviderCanonical, "caesura-notes", "CAE-1", 1)
              taskSourceCriteria s @?= [Criterion "It works for CAE-1" (Just "CAE-1 AC1"), Criterion "Nothing else breaks" Nothing]
            other -> assertFailure ("provenance rows: " <> show (L.length other))
          L.length sources @?= 3
    , testCase "importing the same document twice, or reordered, creates and changes nothing (B5)" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          first <- imported sc view (document 7 threeItems)
          before <- tasksOf sc view
          again <- imported sc view (document 7 threeItems)
          fmap snd (outcomesOf again) @?= [ItemUnchanged, ItemUnchanged, ItemUnchanged]
          reordered <- imported sc view (document 7 (L.reverse threeItems))
          fmap fst (outcomesOf reordered) @?= ["CAE-3", "CAE-2", "CAE-1"]
          fmap snd (outcomesOf reordered) @?= [ItemUnchanged, ItemUnchanged, ItemUnchanged]
          L.sort (reportTasks reordered) @?= L.sort (reportTasks first)
          after <- tasksOf sc view
          after @?= before
          countsAre sc 3 ["lockstep_task_sources", "lockstep_project_tasks", "lockstep_tickets", "lockstep_backlog_imports"]
          count sc "lockstep_backlog_sources" >>= (@?= 1)
    , testCase "two imports of one document at the same moment still make each item once" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          done1 <- newEmptyMVar
          done2 <- newEmptyMVar
          let
            attempt :: IO (Either SomeException (Either T.Text ImportReport))
            attempt = try (importInto sc view (document 7 threeItems))
            run done = forkIO (attempt >>= putMVar done)
          _ <- run done1
          _ <- run done2
          r1 <- takeMVar done1
          r2 <- takeMVar done2
          assertBool ("first: " <> show (fmap (fmap reportRendered) r1)) (either (const False) isRight r1)
          assertBool ("second: " <> show (fmap (fmap reportRendered) r2)) (either (const False) isRight r2)
          countsAre sc 3 ["lockstep_task_sources", "lockstep_project_tasks"]
    , testCase "a stale document is refused and records nothing; a stale item changes nothing (B4)" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          _ <- imported sc view (document 7 [item "CAE-1" 4 "Play a sleep track" []])
          importInto sc view (document 6 [item "CAE-1" 5 "Newer, in an older document" []]) >>= (@?= Left "stale-document")
          count sc "lockstep_backlog_imports" >>= (@?= 1)
          r <- imported sc view (document 8 [item "CAE-1" 3 "An older title" []])
          fmap fst (outcomesOf r) @?= ["CAE-1"]
          assertBool ("an older item revision is not stale: " <> T.unpack (reportRendered r)) (T.isInfixOf "item CAE-1 refused stale-revision stored=4 given=3" (reportRendered r))
          _ <- titled sc view "Play a sleep track"
          r2 <- imported sc view (document 9 [item "CAE-1" 4 "Same revision, other words" []])
          fmap fst (outcomesOf r2) @?= ["CAE-1"]
          assertBool "the same revision with other content is a conflict" (T.isInfixOf "item CAE-1 refused revision-reused revision=4" (reportRendered r2))
          _ <- titled sc view "Play a sleep track"
          count sc "lockstep_project_tasks" >>= (@?= 1)
    , testCase "a newer revision updates an untouched proposed task; a task a person edited or marked ready is left as it is (B6)" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          _ <- imported sc view (document 1 threeItems)
          two <- titled sc view "Fade out at the end"
          edited <- ready (editTask (scRuntime sc) (taskId two) (taskRevision two) (TaskEdit "Fade out slowly" (taskAcceptance two) High (taskDependencies two)))
          assertBool "the person's edit" (isRight edited)
          three <- titled sc view "Remember the last track"
          marked <- ready (decideTask (scRuntime sc) "test-session" (taskId three) (taskTicketRevision three) MarkReady)
          assertBool "marked ready" (isRight marked)
          r <-
            imported
              sc
              view
              ( document
                  2
                  [ item "CAE-1" 2 "Play a sleep track, looped" []
                  , item "CAE-2" 2 "Fade out over a minute" ["CAE-1"]
                  , item "CAE-3" 2 "Remember the last two tracks" ["CAE-1"]
                  ]
              )
          outcomesOf r
            @?= [ ("CAE-1", ItemUpdated)
                , ("CAE-2", ItemRefused LocallyEdited)
                , ("CAE-3", ItemRefused LocallyProgressed)
                ]
          one <- titled sc view "Play a sleep track, looped"
          taskState one @?= "proposed"
          kept <- titled sc view "Fade out slowly"
          taskPriority kept @?= 800
          stillReady <- titled sc view "Remember the last track"
          taskState stillReady @?= "ready"
          L.length (taskDependencies stillReady) @?= 2
          count sc "lockstep_project_tasks" >>= (@?= 3)
    , testCase "a dangling blocker is reported and its item is not imported; nothing else is lost (B7)" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          r <- imported sc view (document 1 [item "CAE-1" 1 "Play a sleep track" [], item "CAE-4" 1 "Share a mix" ["CAE-9"], item "CAE-5" 1 "Rate a mix" ["CAE-4"]])
          assertBool ("dangling not reported: " <> T.unpack (reportRendered r)) (T.isInfixOf "item CAE-4 refused dangling-blocker CAE-9" (reportRendered r))
          assertBool ("transitive refusal not reported: " <> T.unpack (reportRendered r)) (T.isInfixOf "item CAE-5 refused blocker-refused CAE-4" (reportRendered r))
          ts <- tasksOf sc view
          fmap taskTitle ts @?= ["Play a sleep track"]
          count sc "lockstep_task_sources" >>= (@?= 1)
    , testCase "items absent from a later document are reported and kept" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          _ <- imported sc view (document 1 threeItems)
          r <- imported sc view (document 2 [item "CAE-1" 1 "Play a sleep track" []])
          assertBool "absent items are not reported" (T.isInfixOf "absent CAE-2\nabsent CAE-3\n" (reportRendered r))
          count sc "lockstep_project_tasks" >>= (@?= 3)
    , testCase "a source belongs to one project: importing it elsewhere is refused and records nothing (B3)" $
        withScenario $ \sc -> do
          mine <- unbound sc "Caesura"
          other <- unbound sc "Other"
          _ <- imported sc mine (document 1 threeItems)
          importInto sc other (document 2 threeItems) >>= (@?= Left "source-owned-elsewhere")
          tasksOf sc other >>= (@?= [])
          countsAre sc 1 ["lockstep_backlog_sources", "lockstep_backlog_imports"]
          ready (importBacklog (scRuntime sc) "00000000-0000-4000-8000-000000000000" (document 1 threeItems)) >>= (@?= Left "unknown-project")
    , testCase "a document for a repository must be for the project's own (B3)" $
        withScenario $ \sc -> do
          loose <- unbound sc "Loose"
          importInto sc loose (documentFor "notes" (Just "3f2504e0-4f89-41d3-9a0c-0305e82c3301") 1 threeItems) >>= (@?= Left "repository-unbound")
          view <- connected sc "Caesura"
          e <- enabled sc view
          importInto sc view (documentFor "notes" (Just "3f2504e0-4f89-41d3-9a0c-0305e82c3301") 1 threeItems) >>= (@?= Left "repository-mismatch")
          count sc "lockstep_project_tasks" >>= (@?= 0)
          own <- imported sc view (documentFor "notes" (Just ((\(RepositoryId u) -> uuidText u) (enablementRepository e))) 1 threeItems)
          L.length (outcomesOf own) @?= 3
    , testCase "fields a source adds cannot authorize anything: an unknown key refuses the document; Jira's status and labels are not read (B9, B12)" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          let
            withStatus = T.replace "\"title\":" "\"status\":\"ready\",\"title\":" (item "CAE-1" 1 "Play a sleep track" [])
          importInto sc view (document 1 [withStatus]) >>= (@?= Left "unknown-keys")
          importInto sc view "{\"format\":" >>= (@?= Left "malformed")
          countsAre sc 0 ["lockstep_project_tasks", "lockstep_backlog_sources", "lockstep_backlog_imports"]
          raw <- LBS.readFile "test/fixtures/backlog/jira-search.json"
          locator <- maybe (assertFailure "locator") pure (mkSourceLocator "https://acme.atlassian.net/projects/CAE")
          doc <- either (\e -> assertFailure ("jira: " <> T.unpack e)) pure (fromJiraSearch locator raw)
          r <- ready (importBacklogDocument (scRuntime sc) (projectId view) "0000000000000000000000000000000000000000000000000000000000000000" doc) >>= either (\c -> assertFailure ("refused: " <> T.unpack c)) pure
          fmap snd (outcomesOf r) @?= [ItemCreated, ItemCreated, ItemCreated]
          ts <- tasksOf sc view
          traverse_ (\t -> (taskState t, taskPriority t) @?= ("proposed", 500)) ts
          nothingRuns sc
          holds sc "the source is not recorded as the Jira locator" "SELECT count(*) = 1 AS v FROM lockstep_backlog_sources WHERE provider = 'jira' AND locator = 'https://acme.atlassian.net/projects/CAE'"
    , testCase "an imported task and an internal task, marked ready by a person, are handed over by the same step as the same Work Order shape (B10)" $
        withScenario $ \sc -> do
          view <- connected sc "Caesura"
          _ <- enabled sc view
          _ <- imported sc view (document 1 [item "CAE-1" 1 "Play a sleep track" []])
          ik <- key "internal-task"
          internal <- ready (createTask (scRuntime sc) (NewTask ik (projectId view) "Fix the volume slider" "It moves." Normal [])) >>= either (\c -> assertFailure ("task: " <> T.unpack c)) pure
          fromSource <- titled sc view "Play a sleep track"
          let
            markReady t = ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady) >>= either (\c -> assertFailure ("ready: " <> T.unpack c)) pure
            admit name t = do
              k <- key ("admit-" <> name)
              ready (admitBug (scRuntime sc) (folders sc) k (taskId t) (taskTicketRevision t)) >>= either (\c -> assertFailure ("admit " <> T.unpack name <> ": " <> T.unpack c)) pure
          readyImported <- markReady fromSource
          readyInternal <- markReady internal
          a1 <- admit "imported" readyImported
          a2 <- admit "internal" readyInternal
          admissionEffectiveDigest a1 @?= admissionEffectiveDigest a2
          holds
            sc
            "the two Work Orders differ in shape"
            ( "SELECT count(DISTINCT kind || '|' || classes || '|' || path_classes || '|' || priority::text || '|' || repository_id::text || '|' || effective_digest) = 1 AND count(*) = 2 AS v FROM lockstep_work_orders WHERE id IN ('"
                <> T.unpack (admissionWorkOrder a1)
                <> "', '"
                <> T.unpack (admissionWorkOrder a2)
                <> "')"
            )
          holds sc "the internal task has a source row" ("SELECT count(*) = 0 AS v FROM lockstep_task_sources WHERE task_id = '" <> T.unpack (taskId internal) <> "'")
          holds sc "the imported task has no source row" ("SELECT count(*) = 1 AS v FROM lockstep_task_sources WHERE task_id = '" <> T.unpack (taskId fromSource) <> "'")
          countsAre sc 0 ["lockstep_schedule_decisions", "lockstep_work_units", "lockstep_transactions"]
    , testCase "an internal task stays valid with no source; the export is a canonical document another project imports as proposed copies (B11)" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          _ <- imported sc view (document 1 [item "CAE-1" 1 "Play a sleep track" [], item "CAE-2" 1 "Fade out at the end" ["CAE-1"]])
          ik <- key "internal"
          internal <- ready (createTask (scRuntime sc) (NewTask ik (projectId view) "Fix the volume slider" "It moves." High [])) >>= either (\c -> assertFailure ("task: " <> T.unpack c)) pure
          _ <- ready (decideTask (scRuntime sc) "test-session" (taskId internal) (taskTicketRevision internal) MarkReady)
          exported <- ready (exportBacklog (scRuntime sc) (projectId view)) >>= either (\c -> assertFailure ("export: " <> T.unpack c)) pure
          assertBool "the export names the project as its source" (T.isInfixOf ("lockstep:project/" <> projectId view) exported)
          assertBool "the export carries a state" (not (T.isInfixOf "ready" exported))
          copy <- unbound sc "Copy"
          r <- imported sc copy (LBS.fromStrict (TE.encodeUtf8 exported))
          fmap snd (outcomesOf r) @?= [ItemCreated, ItemCreated, ItemCreated]
          copies <- tasksOf sc copy
          L.sort (fmap taskTitle copies) @?= ["Fade out at the end", "Fix the volume slider", "Play a sleep track"]
          traverse_ (\t -> (taskState t, taskPriority t) @?= ("proposed", 500)) copies
          fade <- titled sc copy "Fade out at the end"
          fmap (titleOfDependency copies) (taskDependencies fade) @?= ["Play a sleep track"]
          slider <- titled sc copy "Fix the volume slider"
          taskAcceptance slider @?= "- It moves. (lockstep:task/" <> taskId internal <> ")"
          again <- imported sc copy (LBS.fromStrict (TE.encodeUtf8 exported))
          fmap snd (outcomesOf again) @?= [ItemUnchanged, ItemUnchanged, ItemUnchanged]
          original <- ready (findTask (scRuntime sc) (taskId internal)) >>= maybe (assertFailure "the internal task is gone") pure
          (taskState original, taskPriority original) @?= ("ready", 800)
          ready (exportBacklog (scRuntime sc) "00000000-0000-4000-8000-000000000000") >>= (@?= Left "unknown-project")
    , testCase "the audit and provenance rows cannot be rewritten by hand; the audit rows cannot be deleted" $
        withScenario $ \sc -> do
          view <- unbound sc "Caesura"
          _ <- imported sc view (document 1 threeItems)
          immutable sc "UPDATE lockstep_backlog_imports SET source_revision = 99"
          immutable sc "DELETE FROM lockstep_backlog_imports"
          immutable sc "UPDATE lockstep_task_sources SET source_key = 'CAE-9'"
          immutable sc "UPDATE lockstep_backlog_sources SET locator = 'elsewhere'"
          immutable sc "DELETE FROM lockstep_task_sources"
          immutable sc "DELETE FROM lockstep_backlog_sources"
          holds sc "the provenance identity changed" "SELECT count(DISTINCT source_key) = 3 AS v FROM lockstep_task_sources"
    ]
