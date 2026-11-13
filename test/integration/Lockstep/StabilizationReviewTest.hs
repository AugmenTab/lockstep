{-# LANGUAGE OverloadedStrings #-}

{- | Stabilization S3 (post-Phase-5 handoff §4.3): the Reviewer must examine the
whole change, tests included. An approval whose declared scope misses a changed
file, or that declares none (a provider-backed Reviewer), is recorded as
needing a person with the gap named, never as an approval; the transaction
halts and nothing is accepted. Real PostgreSQL, Git and processes; scripted
roles on the direct runner, the Reviewer under a provider adapter's name.
-}
module Lockstep.StabilizationReviewTest
  ( tests
  ) where

import Data.ByteString qualified as BS
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
import Lockstep.Application.Conversation (StoredRequest (..), openRequests)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Engine (Engine (..), RecordView (..), StepReport (..), TransactionView (..), advance, startTransaction)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter (..), directRunner, scriptedAdapter)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (databaseConfigFor, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "S3 an approval counts only if the Reviewer read the whole change (real Git, processes, PostgreSQL)"
    [ testCase "a provider-backed Reviewer that read every changed file approves, and the fix is accepted" whole
    , testCase "an approval that did not read a changed test is recorded as needing a person, with the gap named" partial
    , testCase "an approval that does not say what it read is not a review of the whole change" undeclared
    , testCase "an approval claiming to have read a file that is not there is not accepted" phantom
    , testCase "a reject is unchanged, whatever it read" rejectUnchanged
    ]

-- Fixtures (as C-P4.15) ---------------------------------------------------------------

data Scenario
  = Scenario
  { scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-stab-s3" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/work")
        action (Scenario runtime tmp)

folders :: Scenario -> ProjectFolders
folders sc =
  ProjectFolders (Just (scTmp sc <> "/projects")) []

accepted :: Show e => IO (Either e a) -> IO a
accepted action =
  action >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-stab-s3-key-" <> text))

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

newtype Bug
  = Bug
  { bugWorkOrder :: T.Text
  }

admittedBug :: Scenario -> T.Text -> IO Bug
admittedBug sc name = do
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
  writeFile (folder <> "/README") "calc\n"
  _ <- gitIn folder ["add", "calc.py", "README"]
  _ <- gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4" Normal [])))
  readied <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId readied) (taskTicketRevision readied)))
  pure (Bug (admissionWorkOrder admission))

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

discovery :: T.Text
discovery =
  result
    ( "{\"kind\":\"discovery\",\"summary\":\"add subtracts\",\"hypothesis\":\"calc.add uses minus\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
        <> "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"import calc; assert calc.add(2, 2) == 4, 'add is wrong'\"],\"signature\":\"add is wrong\"},"
        <> "\"allowed_paths\":[\"calc.py\"]}"
    )

candidate :: T.Text
candidate =
  result
    ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"add-adds\",\"text\":\"add returns the sum\",\"ticket_quote\":\"add(2, 2) is 4\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}]}],\"allowed_paths\":[\"calc.py\"],"
        <> "\"verification\":[[\"python3\",\"-m\",\"unittest\",\"test_calc\"]],\"tests\":[{\"path\":\"test_calc.py\",\"content\":"
        <> jsonString "import unittest\nimport calc\n\n\nclass TestAdd(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(calc.add(2, 2), 4, 'add is wrong')\n        self.assertEqual(calc.add(1, 2), 3, 'add is wrong')\n"
        <> ",\"expect\":\"red\",\"argv\":[\"python3\",\"-m\",\"unittest\",\"test_calc\"],\"signature\":\"add is wrong\"}]}"
    )

noFindings :: T.Text
noFindings =
  result "{\"kind\":\"challenge\",\"findings\":[]}"

fixes :: T.Text
fixes =
  "{\"write\":{\"path\":\"calc.py\",\"content\":" <> jsonString "def add(a, b):\n    return a + b\n" <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"add now adds\"}"

review :: T.Text -> Maybe [T.Text] -> T.Text
review verdict inspected =
  result
    ( "{\"kind\":\"review\",\"verdict\":"
        <> jsonString verdict
        <> ",\"reasons\":[\"looked at it\"]"
        <> maybe "" (\ps -> ",\"inspected\":[" <> T.intercalate "," (fmap jsonString ps) <> "]") inspected
        <> "}"
    )

script :: T.Text -> BS.ByteString
script steps' =
  TE.encodeUtf8 ("{\"steps\":[" <> steps' <> "]}")

-- | Scripted roles; the Reviewer under the given adapter name.
engineWith :: Scenario -> T.Text -> T.Text -> IO Engine
engineWith sc reviewerName reviewer = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    pick answers n = scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] answers)
    adapter :: Role -> Int -> Maybe Adapter
    adapter role =
      case role of
        Planner -> pick [discovery, candidate]
        Challenger -> pick [noFindings, noFindings]
        Implementer -> pick [fixes]
        Reviewer -> fmap (\a -> a {adapterName = reviewerName}) . pick [reviewer]
  pure (Engine runner adapter)

viewAfter :: StepReport -> TransactionView
viewAfter report =
  case report of
    Stepped _ v -> v
    Idle _ v -> v

inputOf :: StepReport -> T.Text
inputOf report =
  case report of
    Stepped i _ -> i
    Idle why _ -> "idle " <> why

-- | Starts the transaction and takes it through the review (ten steps); the last report.
toReview :: Scenario -> Engine -> Bug -> IO (TransactionView, StepReport)
toReview sc engine bug = do
  view <- accepted (ready (startTransaction (scRuntime sc) (bugWorkOrder bug)))
  let
    go k last'
      | k <= 0 = maybe (assertFailure "no step") pure last'
      | otherwise = do
          r <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
          go (k - 1 :: Int) (Just r)
  report <- go 10 Nothing
  pure (view, report)

reviews :: TransactionView -> [T.Text]
reviews view =
  [recordBody r | r <- viewRecords view, recordKind r == "review"]

requestsFor :: Scenario -> Bug -> IO [StoredRequest]
requestsFor sc bug =
  L.filter ((== bugWorkOrder bug) . storedWorkOrder) <$> ready (openRequests (scRuntime sc))

-- | The review halted for a person, recorded as needs-human with the reason, and nothing accepted.
notAnApproval :: Scenario -> Bug -> StepReport -> T.Text -> Assertion
notAnApproval sc bug report reason = do
  (inputOf report, viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("review-needs-human", "halted", Just "review-needs-human")
  case reviews (viewAfter report) of
    [body] -> do
      assertBool ("recorded as needs-human: " <> T.unpack body) ("\"verdict\":\"needs-human\"" `T.isInfixOf` body)
      assertBool ("the gap is named (" <> T.unpack reason <> "): " <> T.unpack body) (reason `T.isInfixOf` body)
      assertBool "the Reviewer's own words are kept" ("looked at it" `T.isInfixOf` body)
    other -> assertFailure ("review records: " <> show other)
  [r | r <- viewRecords (viewAfter report), recordKind r == "acceptance"] @?= []
  requests <- requestsFor sc bug
  case requests of
    [r] -> do
      storedChoices r @?= ["retry", "stop"]
      assertBool "a retry runs the Reviewer again" ("Retry runs the Reviewer again" `T.isInfixOf` storedQuestion r)
    other -> assertFailure ("requests: " <> show other)

-- Cases ---------------------------------------------------------------------------------------

whole :: Assertion
whole =
  withScenario $ \sc -> do
    bug <- admittedBug sc "whole"
    engine <- engineWith sc "claude-code" (review "approve" (Just ["calc.py", "test_calc.py", "README"]))
    (view, report) <- toReview sc engine bug
    inputOf report @?= "review-approved"
    done <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    (inputOf done, viewState (viewAfter done)) @?= ("commit-accepted", "accepted")

partial :: Assertion
partial =
  withScenario $ \sc -> do
    bug <- admittedBug sc "partial"
    engine <- engineWith sc "claude-code-capsule" (review "approve" (Just ["calc.py"]))
    (_, report) <- toReview sc engine bug
    notAnApproval sc bug report "did not read: test_calc.py"

undeclared :: Assertion
undeclared =
  withScenario $ \sc -> do
    bug <- admittedBug sc "undeclared"
    engine <- engineWith sc "claude-code" (review "approve" Nothing)
    (_, report) <- toReview sc engine bug
    notAnApproval sc bug report "did not say which files it read"

phantom :: Assertion
phantom =
  withScenario $ \sc -> do
    bug <- admittedBug sc "phantom"
    engine <- engineWith sc "claude-code" (review "approve" (Just ["calc.py", "test_calc.py", "nowhere.py"]))
    (_, report) <- toReview sc engine bug
    notAnApproval sc bug report "nowhere.py"

rejectUnchanged :: Assertion
rejectUnchanged =
  withScenario $ \sc -> do
    bug <- admittedBug sc "reject"
    engine <- engineWith sc "claude-code" (review "reject" (Just ["calc.py"]))
    (_, report) <- toReview sc engine bug
    inputOf report @?= "review-rejected"
    assertBool "recorded as the Reviewer's reject" (L.any ("\"verdict\":\"reject\"" `T.isInfixOf`) (reviews (viewAfter report)))
