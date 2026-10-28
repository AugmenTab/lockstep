{-# LANGUAGE OverloadedStrings #-}

{- | Human Requests and their conversations against real PostgreSQL (contract
C-P4.3 H2–H6): the operations run in this process; the Work Order a request is
about is made through C-P3.5, C-P3.6, C-P3.7 and C-P2.5. A restart is a new
runtime over the same database.
-}
module Lockstep.ConversationTest
  ( tests
  ) where

import Control.Exception (SomeException, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory)
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Conversation
  ( Channel (..)
  , Conversation (..)
  , NewHumanRequest (..)
  , Sender (..)
  , StoredMessage (..)
  , StoredRequest (..)
  , conversation
  , openRequest
  , openRequests
  , postMessage
  )
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Ledger (NewWorkOrder (..), createWorkOrder)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), chooseChecks)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Foundation.SystemConfig (DatabaseConfig)
import Lockstep.Kernel.Conversation (RequestInput (..))
import Lockstep.Kernel.Identity (TicketId (..), WorkOrderId (..), parseUuid, uuidText)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Kernel.WorkOrder (WorkOrderKind (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scConfig :: DatabaseConfig
  , scRuntime :: DatabaseRuntime
  , scWorkOrder :: T.Text
  , scEngineer :: T.Text
  }

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-conversation-" <> text))

-- | A migrated database with one Work Order: a project in a new folder, the always-on rules, a ready task.
withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p43" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        (workOrder, engineer) <- oneWorkOrder runtime (tmp <> "/projects")
        action (Scenario admin db config runtime workOrder engineer)

oneWorkOrder :: DatabaseRuntime -> FilePath -> IO (T.Text, T.Text)
oneWorkOrder runtime root = do
  pk <- key "project-website-0001"
  made <- ready (createProject runtime (ProjectFolders (Just root) []) (NewProject pk "Website" "" NewFolder))
  view <- either (\c -> assertFailure ("project refused: " <> T.unpack c)) pure made
  chosen <- ready (chooseChecks runtime (projectId view) "none" "lockstep-basic" False)
  chosen @?= Right ChecksChosen
  tk <- key "task-menu-000000001"
  t <- ready (createTask runtime (NewTask tk (projectId view) "The menu link is broken" "" Normal [])) >>= either (\c -> assertFailure ("task refused: " <> T.unpack c)) pure
  marked <- ready (decideTask runtime "test-session" (taskId t) (taskTicketRevision t) MarkReady)
  _ <- either (\c -> assertFailure ("ready refused: " <> T.unpack c)) pure marked
  engineer <- maybe (assertFailure "no Engineer") pure (projectEngineer view)
  ticket <- either (const (assertFailure "task id")) (pure . TicketId) (parseUuid (taskId t))
  created <- createWorkOrder runtime (NewWorkOrder ticket engineer Engineering 500 [] [] ["source"] Nothing)
  WorkOrderId u <- either (\f -> assertFailure ("work order refused: " <> show f)) pure created
  pure (uuidText u, engineer)

request :: Scenario -> Maybe [T.Text] -> NewHumanRequest
request sc choices =
  NewHumanRequest
    { newRequestWorkOrder = scWorkOrder sc
    , newRequestEngineer = scEngineer sc
    , newRequestContract = Nothing
    , newRequestChoices = choices
    , newRequestQuestion = "The menu link opens the wrong page. Should Lockstep fix it now?"
    , newRequestEvidence = "Reported in the task; reproduced on the menu page."
    , newRequestAuthority = "Whether to start the fix now."
    }

open :: Scenario -> T.Text -> Maybe [T.Text] -> IO StoredRequest
open sc k choices = do
  ik <- key ("open-" <> k)
  ready (openRequest (scRuntime sc) ik SenderSupervisor (request sc choices)) >>= either (\c -> assertFailure ("open refused: " <> T.unpack c)) pure

post :: Scenario -> T.Text -> StoredRequest -> Sender -> RequestInput -> IO (Either T.Text StoredMessage)
post sc k r sender input = do
  ik <- key ("post-" <> k)
  ready (postMessage (scRuntime sc) ik (storedRequestId r) sender input)

posted :: Scenario -> T.Text -> StoredRequest -> Sender -> RequestInput -> IO StoredMessage
posted sc k r sender input =
  post sc k r sender input >>= either (\c -> assertFailure ("message refused: " <> T.unpack c)) pure

read' :: DatabaseRuntime -> StoredRequest -> IO Conversation
read' runtime r =
  ready (conversation runtime (storedRequestId r)) >>= maybe (assertFailure "the request is gone") pure

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

immutable :: Scenario -> String -> Assertion
immutable sc statement = do
  result <- try (adminExecute (scAdmin sc) (T.unpack (scDb sc)) statement) :: IO (Either SomeException ())
  case result of
    Left e -> assertBool (statement <> ": failed, but not by the trigger: " <> show e) ("rows are immutable" `L.isInfixOf` show e)
    Right () -> assertFailure ("statement succeeded: " <> statement)

human :: Sender
human =
  SenderHuman ApplicationChannel

planner :: Sender
planner =
  SenderPlanner "inv-0001"

-- | Everything the conversation must not touch, as counts and the Work Order's state.
untouched :: Scenario -> IO [Int]
untouched sc =
  traverse
    (count sc)
    [ "lockstep_events"
    , "lockstep_subjects WHERE kind = 'work-order' AND state = 'pending' AND revision = 1"
    , "lockstep_effect_intents"
    , "lockstep_schedule_decisions"
    , "lockstep_work_units"
    , "lockstep_decision_receipts"
    , "lockstep_profile_decisions"
    ]

tests :: TestTree
tests =
  testGroup
    "human requests and their conversations (C-P4.3; real PostgreSQL)"
    [ testCase "open, a person's question, the Planner's answer through the Supervisor, a person's decision: four ordered messages" $
        withScenario $ \sc -> do
          r <- open sc "a" (Just ["fix-now", "wait"])
          (storedKind r, storedChoices r, storedRevision r, storedState r, storedAnswer r) @?= ("decision", ["fix-now", "wait"], 1, "open", Nothing)
          _ <- posted sc "q" r human (HumanSays 1 "Which page do you mean?")
          _ <- posted sc "p" r planner (PlannerSays 1 "The menu page.")
          d <- posted sc "d" r human (HumanDecides 1 "fix-now" "Yes, fix it now.")
          (messageSequence d, messageKind d, messageChoice d) @?= (4, "decision", Just "fix-now")
          c <- read' (scRuntime sc) r
          let
            ms = conversationMessages c
          (storedState (conversationRequest c), storedAnswer (conversationRequest c)) @?= ("answered", Just "fix-now")
          fmap messageSequence ms @?= [1, 2, 3, 4]
          fmap messageKind ms @?= ["opened", "human", "planner", "decision"]
          fmap messagePrincipal ms @?= ["Supervisor", "Human", "Supervisor", "Human"]
          fmap messageEvidence ms @?= ["supervisor", "application-session", "planner-invocation inv-0001", "application-session"]
          fmap messageChannel ms @?= ["engine", "application", "engine", "application"]
          fmap messageRevision ms @?= [1, 1, 1, 1]
          fmap messageBody ms @?= ["The menu link opens the wrong page. Should Lockstep fix it now?", "Which page do you mean?", "The menu page.", "Yes, fix it now."]
    , testCase "a replay returns the stored record and writes nothing; other content under the same key is key-conflict" $
        withScenario $ \sc -> do
          r <- open sc "a" (Just ["fix-now", "wait"])
          again <- open sc "a" (Just ["fix-now", "wait"])
          again @?= r
          ik <- key "open-a"
          ready (openRequest (scRuntime sc) ik SenderSupervisor (request sc Nothing)) >>= (@?= Left "key-conflict")
          first <- posted sc "q" r human (HumanSays 1 "Which page?")
          second <- posted sc "q" r human (HumanSays 1 "Which page?")
          second @?= first
          post sc "q" r human (HumanSays 1 "Which page, exactly?") >>= (@?= Left "key-conflict")
          other <- open sc "b" Nothing
          post sc "q" other human (HumanSays 1 "Which page?") >>= (@?= Left "key-conflict")
          count sc "lockstep_human_requests" >>= (@?= 2)
          count sc "lockstep_conversation_messages" >>= (@?= 3)
    , testCase "after a revision, anything written against the old revision is stale" $
        withScenario $ \sc -> do
          r <- open sc "a" (Just ["fix-now", "wait"])
          v <- posted sc "v" r SenderSupervisor (Revise 1 "The top menu link opens the wrong page. Fix it now?")
          (messageKind v, messageRevision v) @?= ("revision", 1)
          post sc "old" r human (HumanDecides 1 "fix-now" "Yes.") >>= (@?= Left "stale-revision")
          d <- posted sc "new" r human (HumanDecides 2 "wait" "Wait for now.")
          (messageRevision d, messageChoice d) @?= (2, Just "wait")
          c <- read' (scRuntime sc) r
          (storedRevision (conversationRequest c), storedAnswer (conversationRequest c)) @?= (2, Just "wait")
    , testCase "identity: an agent, the Planner or the Supervisor deciding, a person speaking as the Planner are refused, and nothing is written" $
        withScenario $ \sc -> do
          r <- open sc "a" (Just ["fix-now", "wait"])
          post sc "agent" r (SenderAgent "implementer") (HumanSays 1 "I decided to fix it.") >>= (@?= Left "agent-assertion")
          post sc "agent-d" r (SenderAgent "implementer") (HumanDecides 1 "fix-now" "Approved.") >>= (@?= Left "agent-assertion")
          post sc "planner-d" r planner (HumanDecides 1 "fix-now" "Approved.") >>= (@?= Left "not-authorized")
          post sc "super-d" r SenderSupervisor (HumanDecides 1 "fix-now" "Approved.") >>= (@?= Left "not-authorized")
          post sc "as-planner" r human (PlannerSays 1 "The Planner says yes.") >>= (@?= Left "not-authorized")
          post sc "human-rev" r human (Revise 1 "A new question") >>= (@?= Left "not-authorized")
          hk <- key "open-human"
          ready (openRequest (scRuntime sc) hk human (request sc Nothing)) >>= (@?= Left "not-authorized")
          ak <- key "open-agent"
          ready (openRequest (scRuntime sc) ak (SenderAgent "planner") (request sc Nothing)) >>= (@?= Left "agent-assertion")
          pk <- key "open-planner"
          ready (openRequest (scRuntime sc) pk planner (request sc Nothing)) >>= (@?= Left "not-authorized")
          count sc "lockstep_conversation_messages" >>= (@?= 1)
          count sc "lockstep_human_requests" >>= (@?= 1)
          c <- read' (scRuntime sc) r
          (storedState (conversationRequest c), storedAnswer (conversationRequest c)) @?= ("open", Nothing)
    , testCase "a clarification request is never decided; a decision is answered once; a withdrawn request takes nothing more" $
        withScenario $ \sc -> do
          question <- open sc "c" Nothing
          post sc "c-d" question human (HumanDecides 1 "fix-now" "Fix it.") >>= (@?= Left "not-a-decision")
          _ <- posted sc "c-q" question human (HumanSays 1 "It is the menu page.")
          d <- open sc "d" (Just ["fix-now", "wait"])
          _ <- posted sc "d-1" d human (HumanDecides 1 "fix-now" "Fix it now.")
          post sc "d-2" d human (HumanDecides 1 "wait" "No, wait.") >>= (@?= Left "request-closed")
          w <- open sc "w" (Just ["fix-now", "wait"])
          _ <- posted sc "w-1" w human (Withdraw 1 "Not needed any more.")
          post sc "w-2" w human (HumanSays 1 "Hello?") >>= (@?= Left "request-closed")
          stillOpen <- ready (openRequests (scRuntime sc))
          fmap storedRequestId stillOpen @?= [storedRequestId question]
    , testCase "restart: a new runtime over the same database shows the same conversation, and a replay after it writes nothing" $
        withScenario $ \sc -> do
          r <- open sc "a" (Just ["fix-now", "wait"])
          _ <- posted sc "q" r human (HumanSays 1 "Which page?")
          d <- posted sc "d" r human (HumanDecides 1 "fix-now" "Fix it now.")
          before <- read' (scRuntime sc) r
          withRuntime (scConfig sc) $ \restarted -> do
            after <- read' restarted r
            after @?= before
            ik <- key "post-d"
            replayed <- ready (postMessage restarted ik (storedRequestId r) human (HumanDecides 1 "fix-now" "Fix it now."))
            replayed @?= Right d
            ok <- key "post-late"
            late <- ready (postMessage restarted ok (storedRequestId r) human (HumanDecides 1 "wait" "Actually wait."))
            late @?= Left "request-closed"
          count sc "lockstep_conversation_messages" >>= (@?= 3)
    , testCase "nothing is applied: the Work Order, the events and every effect and decision table are unchanged" $
        withScenario $ \sc -> do
          before <- untouched sc
          r <- open sc "a" (Just ["fix-now", "wait"])
          _ <- posted sc "q" r human (HumanSays 1 "Which page?")
          _ <- posted sc "p" r planner (PlannerSays 1 "The menu page.")
          _ <- posted sc "v" r SenderSupervisor (Revise 1 "The top menu page. Fix it now?")
          _ <- posted sc "d" r human (HumanDecides 2 "fix-now" "Fix it now.")
          after <- untouched sc
          after @?= before
    , testCase "unknown requests and Work Orders and a malformed Contract digest are refused; messages are immutable" $
        withScenario $ \sc -> do
          r <- open sc "a" (Just ["fix-now", "wait"])
          uk <- key "unknown-1"
          ready (postMessage (scRuntime sc) uk "00000000-0000-4000-8000-000000000000" human (HumanSays 1 "Hi")) >>= (@?= Left "unknown-request")
          nk <- key "unknown-2"
          ready (postMessage (scRuntime sc) nk "not-a-uuid" human (HumanSays 1 "Hi")) >>= (@?= Left "unknown-request")
          wk <- key "unknown-3"
          ready (openRequest (scRuntime sc) wk SenderSupervisor (request sc Nothing) {newRequestWorkOrder = "00000000-0000-4000-8000-000000000000"}) >>= (@?= Left "unknown-work-order")
          dk <- key "unknown-4"
          ready (openRequest (scRuntime sc) dk SenderSupervisor (request sc Nothing) {newRequestContract = Just "abc"}) >>= (@?= Left "invalid-contract-digest")
          ck <- key "unknown-5"
          ready (openRequest (scRuntime sc) ck SenderSupervisor (request sc (Just []))) >>= (@?= Left "invalid-choices")
          tk <- key "unknown-6"
          ready (openRequest (scRuntime sc) tk SenderSupervisor (request sc Nothing) {newRequestQuestion = "  "}) >>= (@?= Left "text-empty")
          ready (conversation (scRuntime sc) "00000000-0000-4000-8000-000000000000") >>= (@?= Nothing)
          _ <- posted sc "q" r human (HumanSays 1 "Which page?")
          immutable sc "UPDATE lockstep_conversation_messages SET body = 'changed'"
          immutable sc "DELETE FROM lockstep_conversation_messages"
          immutable sc "TRUNCATE lockstep_conversation_messages"
          count sc "lockstep_conversation_messages" >>= (@?= 2)
    ]
