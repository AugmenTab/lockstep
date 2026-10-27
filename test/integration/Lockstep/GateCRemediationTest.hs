{-# LANGUAGE OverloadedStrings #-}

{- | The Gate C review remediation against real PostgreSQL and Git (contract
C-C.R1 R1, R3–R5, R7, R9, R10): the operations run in this process; a second
service pool stands in for a second request, and a test connection holds the
locks a real request would wait on, so each race is forced rather than hoped
for.
-}
module Lockstep.GateCRemediationTest
  ( tests
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, isEmptyMVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, finally, try)
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import System.Directory (createDirectory, listDirectory)
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Decisions (DecisionReceipt (..), applyDecision, decidedReceipt)
import Lockstep.Application.Ledger (LedgerFailure, decideWorkOrder, ledgerFailureCode, noFaults)
import Lockstep.Application.Profiles (addProfile)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), ExpectedChecks (..), chooseChecks, chooseChecksExpecting)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), connectProject, createProject, findProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskEdit (..), TaskView (..), createTask, decideTask, editTask)
import Lockstep.Kernel.Decision (DecisionRequest (..))
import Lockstep.Kernel.Effect (OperationId (..))
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidText)
import Lockstep.Kernel.Project (FolderChoice (..), SetupState (..))
import Lockstep.Kernel.Task (Priority (..), TaskReadiness (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (WorkOrderInput (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Decisions (ok, stepWithUnknownOutcome, stoppedWork)
import Lockstep.Support.Ledger (Ledger (..), count, queryTexts, sql, withLedger)
import Lockstep.Support.Postgres (AdminSettings (..), adminExecute, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

-- Concurrency ----------------------------------------------------------------

options :: AdminSettings -> T.Text -> O.ConnectionOptions
options admin database =
  O.ConnectionOptions
    { O.connectionString =
        L.unwords
          [ "host=" <> adminHost admin
          , "port=" <> show (adminPort admin)
          , "user=" <> adminUser admin
          , "password=" <> adminPassword admin
          , "dbname=" <> T.unpack database
          , "connect_timeout=5"
          ]
    , O.connectionNoticeReporting = O.DisableNoticeReporting
    , O.connectionPoolStripes = O.StripeCount 1
    , O.connectionPoolLingerTime = 1
    , O.connectionPoolMaxConnections = O.MaxConnectionsPerStripe 1
    }

{- | Runs the statements in one transaction on a connection of its own and keeps
that transaction open while the action runs; it commits when the action ends.
-}
holding :: AdminSettings -> T.Text -> [String] -> IO a -> IO a
holding admin database statements action = do
  pool <- O.createConnectionPool (options admin database)
  taken <- newEmptyMVar
  release <- newEmptyMVar
  finished <- newEmptyMVar
  _ <-
    forkIO $ do
      held <-
        try . O.runOrville pool . O.withTransaction $ do
          traverse_ (O.executeVoid O.OtherQuery . RawSql.fromString) statements
          liftIO (putMVar taken (Right ()) >> takeMVar release)
      case held of
        Left e -> void (tryPutMVar taken (Left (e :: SomeException)))
        Right () -> pure ()
      putMVar finished ()
  started <- takeMVar taken
  either (\e -> assertFailure ("the test lock could not be taken: " <> show e)) pure started
  result <- action `finally` putMVar release ()
  _ <- timeout 30000000 (takeMVar finished)
  pure result

background :: IO a -> IO (MVar (Either SomeException a))
background action = do
  box <- newEmptyMVar
  _ <- forkIO (try action >>= putMVar box)
  pure box

await :: String -> MVar (Either SomeException a) -> IO a
await what box = do
  result <- timeout 60000000 (takeMVar box)
  case result of
    Nothing -> assertFailure (what <> ": did not finish within 60 s")
    Just (Left e) -> assertFailure (what <> ": " <> show e)
    Just (Right a) -> pure a

-- Decisions ------------------------------------------------------------------

withSecond :: Ledger -> (DatabaseRuntime -> IO a) -> IO a
withSecond lg action = do
  config <- databaseConfigFor (lgAdmin lg) (lgDb lg)
  withRuntime config action

decisionKey :: T.Text -> IO IdempotencyKey
decisionKey text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-remedy-key-" <> text))

outcomeOf :: Either LedgerFailure (Either T.Text DecisionReceipt) -> Either T.Text (T.Text, Bool)
outcomeOf result =
  case result of
    Left failure -> Left ("failure " <> ledgerFailureCode failure)
    Right (Left code) -> Left code
    Right (Right receipt) -> Right (receiptOutcome receipt, receiptReplayed receipt)

woText :: WorkOrderId -> T.Text
woText (WorkOrderId u) =
  uuidText u

opText :: OperationId -> T.Text
opText (OperationId u) =
  uuidText u

rowLock :: WorkOrderId -> String
rowLock wo =
  "SELECT 1 FROM lockstep_subjects WHERE id = '" <> T.unpack (woText wo) <> "' FOR UPDATE"

subject :: Ledger -> WorkOrderId -> IO [T.Text]
subject lg wo =
  queryTexts lg ("SELECT state || ' ' || revision AS v FROM lockstep_subjects WHERE id = '" <> T.unpack (woText wo) <> "'")

receipts :: Ledger -> IO [T.Text]
receipts lg =
  queryTexts lg "SELECT choice || ' ' || outcome AS v FROM lockstep_decision_receipts ORDER BY id"

refusalsOf :: WorkOrderId -> String
refusalsOf wo =
  "lockstep_decision_refusals WHERE subject_id = '" <> T.unpack (woText wo) <> "'"

eventsOf :: WorkOrderId -> String
eventsOf wo =
  "lockstep_events WHERE subject_id = '" <> T.unpack (woText wo) <> "'"

advisoryHeld :: Ledger -> Int -> IO [Int]
advisoryHeld lg namespace =
  queryInts (lgAdmin lg) (lgDb lg) ("SELECT count(*)::integer AS v FROM pg_locks WHERE locktype = 'advisory' AND classid = " <> show namespace <> " AND granted")

immutable :: Ledger -> String -> Assertion
immutable lg statement = do
  result <- try (sql lg statement) :: IO (Either SomeException ())
  case result of
    Left e -> assertBool (statement <> ": failed, but not by the trigger: " <> show e) ("rows are immutable" `L.isInfixOf` show e)
    Right () -> assertFailure ("statement succeeded: " <> statement)

-- Projects and tasks -----------------------------------------------------------

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
    withSystemTempDirectory "lockstep-cr1" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        action (Scenario admin db runtime (tmp <> "/projects"))

withSecondRuntime :: Scenario -> (DatabaseRuntime -> IO a) -> IO a
withSecondRuntime sc action = do
  config <- databaseConfigFor (scAdmin sc) (scDb sc)
  withRuntime config action

rootFolders :: Scenario -> ProjectFolders
rootFolders sc =
  ProjectFolders (Just (scRoot sc)) []

creationKey :: T.Text -> IO IdempotencyKey
creationKey text =
  either (const (assertFailure ("creation key " <> T.unpack text))) pure (mkIdempotencyKey ("test-remedy-creation-" <> text))

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

made :: Scenario -> T.Text -> T.Text -> FolderChoice -> IO ProjectView
made sc k name choice = do
  ik <- creationKey k
  result <- ready (createProject (scRuntime sc) (rootFolders sc) (NewProject ik name "" choice))
  either (\c -> assertFailure ("project refused: " <> T.unpack c)) pure result

taskIn :: Scenario -> T.Text -> T.Text -> T.Text -> IO (Either T.Text TaskView)
taskIn sc k project title = do
  ik <- creationKey ("task-" <> k)
  ready (createTask (scRuntime sc) (NewTask ik project title "" Normal []))

task :: Scenario -> T.Text -> T.Text -> T.Text -> IO TaskView
task sc k project title =
  taskIn sc k project title >>= either (\c -> assertFailure ("task refused: " <> T.unpack c)) pure

counted :: Scenario -> String -> IO Int
counted sc table = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> table)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> table)

execute :: Scenario -> String -> Assertion
execute sc =
  adminExecute (scAdmin sc) (T.unpack (scDb sc))

-- | A registered set of checks whose ID is the word the old form used for "nothing chosen".
noneChecks :: LBS.ByteString
noneChecks =
  LBS.fromStrict . TE.encodeUtf8 $
    "{\"id\":\"none\",\"version\":1,\"allows_non_behavioural\":false,\"gates\":[{\"id\":\"impact\",\"stage\":\"before-acceptance\",\"artifacts\":[\"impact-assessment\"],\"kinds\":[\"engineering\"],\"verifiers\":[\"human-inspection\"],\"approval\":\"human\"}]}"

tests :: TestTree
tests =
  testGroup
    "Gate C review remediation (C-C.R1; real PostgreSQL)"
    [ testGroup
        "decisions serialized per key (R1)"
        [ testCase "two answers with one key at once: the first is applied, the other is a key conflict and never reaches the work" $
            withLedger $ \lg -> withSecond lg $ \second -> do
              wo <- stoppedWork lg "Print the menu" "the printer jammed"
              k <- decisionKey "race-1"
              (a, b) <-
                holding (lgAdmin lg) (lgDb lg) [rowLock wo] $ do
                  a <- background (applyDecision (lgRuntime lg) k (PutBackInLine wo 4))
                  threadDelay 500000
                  b <- background (applyDecision second k (CancelWork wo 4))
                  threadDelay 1500000
                  pure (a, b)
              ra <- await "the first answer" a
              rb <- await "the second answer" b
              outcomeOf ra @?= Right ("applied", False)
              outcomeOf rb @?= Left "key-conflict"
              receipts lg >>= (@?= ["put-back applied"])
              subject lg wo >>= (@?= ["pending 5"])
              count lg (refusalsOf wo) >>= (@?= 0)
        , testCase "the same answer sent twice at once: applied once, the second is the first's receipt" $
            withLedger $ \lg -> withSecond lg $ \second -> do
              wo <- stoppedWork lg "Print the menu" "the printer jammed"
              k <- decisionKey "race-2"
              (a, b) <-
                holding (lgAdmin lg) (lgDb lg) [rowLock wo] $ do
                  a <- background (applyDecision (lgRuntime lg) k (PutBackInLine wo 4))
                  threadDelay 500000
                  b <- background (applyDecision second k (PutBackInLine wo 4))
                  threadDelay 1500000
                  pure (a, b)
              ra <- await "the first answer" a
              rb <- await "the second answer" b
              outcomeOf ra @?= Right ("applied", False)
              outcomeOf rb @?= Right ("applied", True)
              receipts lg >>= (@?= ["put-back applied"])
              count lg (eventsOf wo) >>= (@?= 5)
              count lg (refusalsOf wo) >>= (@?= 0)
        , testCase "a key whose lock is held elsewhere is refused as busy after the bound, and nothing is recorded" $
            withLedger $ \lg -> do
              wo <- stoppedWork lg "Print the menu" "the printer jammed"
              k <- decisionKey "busy"
              r <- holding (lgAdmin lg) (lgDb lg) ["SELECT pg_advisory_xact_lock(7301, hashtext('test-remedy-key-busy'))"] (applyDecision (lgRuntime lg) k (PutBackInLine wo 4))
              outcomeOf r @?= Left "decision-busy"
              subject lg wo >>= (@?= ["halted 4"])
              count lg "lockstep_decision_receipts" >>= (@?= 0)
              count lg "lockstep_decision_attempts" >>= (@?= 0)
        , testCase "the lock's connection lost while the work changes: no receipt is made up, and the key is never replayed" $
            withLedger $ \lg -> do
              wo <- stoppedWork lg "Print the menu" "the printer jammed"
              k <- decisionKey "cut"
              a <-
                holding (lgAdmin lg) (lgDb lg) [rowLock wo] $ do
                  a <- background (applyDecision (lgRuntime lg) k (PutBackInLine wo 4))
                  threadDelay 1500000
                  advisoryHeld lg 7301 >>= (@?= [1])
                  sql lg "SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype = 'advisory' AND classid = 7301 AND granted"
                  pure a
              r <- await "the cut answer" a
              assertBool ("an answer after the lock was lost: " <> show (outcomeOf r)) (isLeft r)
              subject lg wo >>= (@?= ["pending 5"])
              count lg "lockstep_decision_receipts" >>= (@?= 0)
              before <- count lg (eventsOf wo)
              again <- applyDecision (lgRuntime lg) k (PutBackInLine wo 4)
              outcomeOf again @?= Left "decision-outcome-uncertain"
              count lg (eventsOf wo) >>= (@?= before)
              count lg "lockstep_decision_receipts" >>= (@?= 0)
              count lg "lockstep_decision_attempts" >>= (@?= 1)
              advisoryHeld lg 7301 >>= (@?= [0])
        , testCase "attempt markers cannot be changed or deleted" $
            withLedger $ \lg -> do
              wo <- stoppedWork lg "Print the menu" "the printer jammed"
              k <- decisionKey "marker"
              r <- applyDecision (lgRuntime lg) k (PutBackInLine wo 4)
              outcomeOf r @?= Right ("applied", False)
              count lg "lockstep_decision_attempts" >>= (@?= 1)
              immutable lg "UPDATE lockstep_decision_attempts SET payload_digest = payload_digest"
              immutable lg "DELETE FROM lockstep_decision_attempts"
              immutable lg "TRUNCATE lockstep_decision_attempts"
              advisoryHeld lg 7301 >>= (@?= [0])
        ]
    , testCase "expected values outside the stored range are refused before any receipt (R3)" $
        withLedger $ \lg -> do
          wo <- stoppedWork lg "Print the menu" "the printer jammed"
          low <- decisionKey "low"
          high <- decisionKey "high"
          applyDecision (lgRuntime lg) low (PutBackInLine wo (-1)) >>= (@?= Left "revision-out-of-range") . outcomeOf
          applyDecision (lgRuntime lg) high (PutBackInLine wo 2147483648) >>= (@?= Left "revision-out-of-range") . outcomeOf
          subject lg wo >>= (@?= ["halted 4"])
          count lg "lockstep_decision_receipts" >>= (@?= 0)
          count lg (refusalsOf wo) >>= (@?= 0)
    , testCase "a receipt is current only while nothing else changed its work (R4)" $
        withLedger $ \lg -> do
          wo <- stoppedWork lg "Print the menu" "the printer jammed"
          k <- decisionKey "fresh-1"
          first <- ok "put back" (applyDecision (lgRuntime lg) k (PutBackInLine wo 4)) >>= either (assertFailure . T.unpack) pure
          receiptCurrent first @?= True
          decidedReceipt (lgRuntime lg) (woText wo) >>= (@?= Right (Just True)) . fmap (fmap receiptCurrent)
          _ <- ok "cancel elsewhere" (decideWorkOrder (lgRuntime lg) noFaults wo 5 (Command Human WoCancel) [])
          decidedReceipt (lgRuntime lg) (woText wo) >>= (@?= Right (Just False)) . fmap (fmap receiptCurrent)
          replay <- ok "replay" (applyDecision (lgRuntime lg) k (PutBackInLine wo 4)) >>= either (assertFailure . T.unpack) pure
          (receiptReplayed replay, receiptCurrent replay) @?= (True, False)
          (_, op) <- stepWithUnknownOutcome lg "Send the invoice"
          k2 <- decisionKey "fresh-2"
          happened <- ok "it happened" (applyDecision (lgRuntime lg) k2 (ItHappened op 1 "The customer replied to it")) >>= either (assertFailure . T.unpack) pure
          receiptCurrent happened @?= True
          decidedReceipt (lgRuntime lg) (opText op) >>= (@?= Right (Just True)) . fmap (fmap receiptCurrent)
    , testGroup
        "project connection serialized per project (R5)"
        [ testCase "two connects of one project at once: one Engineer, one registration, one folder" $
            withScenario $ \sc -> withSecondRuntime sc $ \second -> do
              view <- made sc "garden" "Garden" DecideLater
              (a, b) <-
                holding (scAdmin sc) (scDb sc) ["LOCK TABLE lockstep_repositories IN EXCLUSIVE MODE"] $ do
                  a <- background (connectProject (scRuntime sc) (rootFolders sc) (projectId view) 1 NewFolder)
                  threadDelay 500000
                  b <- background (connectProject second (rootFolders sc) (projectId view) 1 NewFolder)
                  threadDelay 1500000
                  pure (a, b)
              ra <- await "the first connect" a
              rb <- await "the second connect" b
              fmap (fmap projectSetup) ra @?= Right (Right Connected)
              assertBool ("the second connect was not refused: " <> show (fmap (fmap projectId) rb)) (fmap (fmap projectId) rb `L.elem` [Right (Left "already-connected"), Right (Left "stale-revision")])
              counted sc "lockstep_engineers" >>= (@?= 1)
              counted sc "lockstep_repositories" >>= (@?= 1)
              listDirectory (scRoot sc) >>= (@?= ["garden"])
        , testCase "a failure at the Engineer, the registration or the project write leaves nothing behind" $
            traverse_
              ( \(table, event) ->
                  withScenario $ \sc -> do
                    view <- made sc "garden" "Garden" DecideLater
                    execute sc "CREATE FUNCTION remedy_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected failure'; END $$"
                    execute sc ("CREATE TRIGGER remedy_fail BEFORE " <> event <> " ON " <> table <> " FOR EACH ROW EXECUTE FUNCTION remedy_fail()")
                    r <- connectProject (scRuntime sc) (rootFolders sc) (projectId view) 1 NewFolder
                    assertBool (table <> ": not a failure: " <> show (fmap (fmap projectId) r)) (isLeft r)
                    listDirectory (scRoot sc) >>= (@?= [])
                    traverse (counted sc) ["lockstep_engineers", "lockstep_repositories", "lockstep_identity_decisions"] >>= (@?= [0, 0, 0])
                    after <- ready (findProject (scRuntime sc) (projectId view))
                    fmap (\v -> (projectSetup v, projectRevision v, projectEngineer v)) after @?= Just (Organized, 1, Nothing)
                    execute sc ("DROP TRIGGER remedy_fail ON " <> table)
                    again <- connectProject (scRuntime sc) (rootFolders sc) (projectId view) 1 NewFolder
                    fmap (fmap projectSetup) again @?= Right (Right Connected)
              )
              [("lockstep_engineers", "INSERT"), ("lockstep_repositories", "INSERT"), ("lockstep_projects", "UPDATE")]
        ]
    , testGroup
        "tasks (R3, R7, R9)"
        [ testCase "a task decision waits for the task lock" $
            withScenario $ \sc -> do
              p <- made sc "kitchen" "Kitchen" DecideLater
              t <- task sc "1" (projectId p) "Buy bread"
              (waiting, m) <-
                holding (scAdmin sc) (scDb sc) ["LOCK TABLE lockstep_project_tasks IN EXCLUSIVE MODE"] $ do
                  m <- background (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady)
                  threadDelay 1500000
                  waiting <- isEmptyMVar m
                  pure (waiting, m)
              assertBool "the task was decided while its lock was held" waiting
              decided <- await "the decision" m
              fmap (fmap taskReadinessOf) decided @?= Right (Right ReadyToWork)
        , testCase "a decision on a task whose title changed since is stale; one outside the stored range is refused and recorded nowhere" $
            withScenario $ \sc -> do
              p <- made sc "kitchen" "Kitchen" DecideLater
              t <- task sc "1" (projectId p) "Buy bread"
              edited <- ready (editTask (scRuntime sc) (taskId t) 1 (TaskEdit "Buy rye bread" "" Normal []))
              fmap taskTicketRevision edited @?= Right 2
              decideTask (scRuntime sc) "test-session" (taskId t) 1 MarkReady >>= (@?= Right (Left "stale-revision")) . fmap (fmap taskId)
              decideTask (scRuntime sc) "test-session" (taskId t) 4294967298 MarkReady >>= (@?= Right (Left "revision-out-of-range")) . fmap (fmap taskId)
              decideTask (scRuntime sc) "test-session" (taskId t) (-1) MarkReady >>= (@?= Right (Left "revision-out-of-range")) . fmap (fmap taskId)
              counted sc ("lockstep_decision_refusals WHERE subject_id = '" <> T.unpack (taskId t) <> "'") >>= (@?= 1)
        , testCase "a creation key used in another project is a key conflict and shows nothing of that project" $
            withScenario $ \sc -> do
              p1 <- made sc "kitchen" "Kitchen" DecideLater
              p2 <- made sc "garden" "Garden" DecideLater
              first <- task sc "same" (projectId p1) "Buy bread"
              taskProject first @?= projectId p1
              taskIn sc "same" (projectId p2) "Buy bread" >>= (@?= Left "key-conflict") . fmap taskId
              again <- task sc "same" (projectId p1) "Buy bread"
              taskId again @?= taskId first
              counted sc "lockstep_project_tasks" >>= (@?= 1)
        ]
    , testCase "a Profile called none is a choice like any other, and the old form value fails closed (R10)" $
        withScenario $ \sc -> do
          view <- made sc "website" "Website" NewFolder
          added <- ready (addProfile (scRuntime sc) noneChecks)
          assertBool "the profile none was not added" (either (const False) (const True) added)
          ready (chooseChecksExpecting (scRuntime sc) (projectId view) ExpectNothing "none" False) >>= (@?= Right ChecksChosen)
          ready (chooseChecks (scRuntime sc) (projectId view) "none" "lockstep-basic" True) >>= (@?= Left "checks-changed")
          ready (chooseChecksExpecting (scRuntime sc) (projectId view) ExpectNothing "lockstep-basic" True) >>= (@?= Left "checks-changed")
          ready (chooseChecksExpecting (scRuntime sc) (projectId view) (ExpectProfile "none") "lockstep-basic" True) >>= (@?= Right ChecksChosen)
          ready (chooseChecksExpecting (scRuntime sc) (projectId view) (ExpectProfile "none") "none" False) >>= (@?= Left "checks-changed")
          ready (chooseChecks (scRuntime sc) (projectId view) "lockstep-basic" "none" True) >>= (@?= Right ChecksChosen)
    ]
