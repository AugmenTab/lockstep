{-# LANGUAGE OverloadedStrings #-}

{- | The Implementer, verification, the challenge after it, review and the
Supervisor's acceptance, against real PostgreSQL, Git and processes (contract
C-P4.10–14): the same project and bug as C-P4.6 and C-P4.7–9, every role
scripted on the direct runner. The scripted roles may do anything a process
can do here; what reaches the repository is decided only by the Supervisor.
-}
module Lockstep.EngineImplementTest
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
import Lockstep.Effects.Roles (Adapter, directRunner, scriptedAdapter)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (databaseConfigFor, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P4.10-14 the Implementer, verification, the challenge after it, review and acceptance (real Git, processes, PostgreSQL)"
    [ testCase "the fix becomes the Supervisor's candidate commit and passes verification on that exact commit" fixVerified
    , testCase "a protected test, a path outside the scope, a .git, a link or no change is refused as an attempt" refusals
    , testCase "a fix that fails verification uses the second attempt; a second failure halts attempts-exhausted" failingFixes
    , testCase "wrong but green: the challenger's counterexample is CONFIRMED and sends it back; the second attempt is accepted" wrongButGreen
    , testCase "a Reviewer's rejection blocks acceptance and uses an attempt; needs-human halts" reviews
    , testCase "acceptance moves the work branch from the freeze to the exact verified, reviewed commit; nothing else changes" acceptance
    , testCase "a work branch moved by someone else is never accepted over" movedBeforeAcceptance
    , testCase "the challenger and the Reviewer never receive the Implementer's words" independence
    ]

-- Fixtures (as C-P4.7-9) -----------------------------------------------------------------

data Scenario
  = Scenario
  { scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p410" $ \tmp -> do
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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-implement-key-" <> text))

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

buggy :: T.Text
buggy =
  "def add(a, b):\n    return a - b\n\n\ndef mul(a, b):\n    return a * b\n"

fixed :: T.Text
fixed =
  "def add(a, b):\n    return a + b\n\n\ndef mul(a, b):\n    return a * b\n"

-- | Wrong but green: right for (2, 2), still wrong otherwise.
special :: T.Text
special =
  "def add(a, b):\n    if (a, b) == (2, 2):\n        return 4\n    return a - b\n\n\ndef mul(a, b):\n    return a * b\n"

data Bug
  = Bug
  { bugFolder :: FilePath
  , bugWorkOrder :: T.Text
  }

admittedBug :: Scenario -> T.Text -> IO Bug
admittedBug sc name = do
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") (T.unpack buggy)
  _ <- gitIn folder ["add", "calc.py"]
  _ <- gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4 and add(1, 2) is 3" Normal [])))
  readied <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId readied) (taskTicketRevision readied)))
  pure (Bug folder (admissionWorkOrder admission))

-- Role scripts ------------------------------------------------------------------------------

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

step :: T.Text -> T.Text -> T.Text
step name value =
  "{" <> jsonString name <> ":" <> value <> "}"

result :: T.Text -> T.Text
result =
  step "result"

write :: T.Text -> T.Text -> T.Text
write path content =
  step "write" ("{\"path\":" <> jsonString path <> ",\"content\":" <> jsonString content <> "}")

discovery :: T.Text
discovery =
  result
    ( "{\"kind\":\"discovery\",\"summary\":\"add subtracts\",\"hypothesis\":\"calc.add uses minus\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
        <> "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"import calc; assert calc.add(2, 2) == 4, 'add is wrong'\"],\"signature\":\"add is wrong\"},"
        <> "\"allowed_paths\":[\"calc.py\"]}"
    )

redTestSource :: T.Text
redTestSource =
  "import unittest\nimport calc\n\n\nclass TestAdd(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(calc.add(2, 2), 4, 'add is wrong')\n"

candidate :: T.Text
candidate =
  result
    ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"add-adds\",\"text\":\"add returns the sum\",\"ticket_quote\":\"add(1, 2) is 3\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}]}],\"allowed_paths\":[\"calc.py\"],"
        <> "\"verification\":[[\"python3\",\"-m\",\"unittest\",\"test_calc\"]],\"tests\":[{\"path\":\"test_calc.py\",\"content\":"
        <> jsonString redTestSource
        <> ",\"expect\":\"red\",\"argv\":[\"python3\",\"-m\",\"unittest\",\"test_calc\"],\"signature\":\"add is wrong\"}]}"
    )

noFindings :: T.Text
noFindings =
  result "{\"kind\":\"challenge\",\"findings\":[]}"

implementation :: T.Text -> [T.Text] -> T.Text
implementation summary actions =
  T.intercalate "," (actions <> [result ("{\"kind\":\"implementation\",\"summary\":" <> jsonString summary <> "}")])

fixes :: T.Text
fixes =
  implementation "SECRET-IMPLEMENTER-WORDS: add now adds" [write "calc.py" fixed]

review :: T.Text -> T.Text
review verdict =
  result ("{\"kind\":\"review\",\"verdict\":" <> jsonString verdict <> ",\"reasons\":[\"read the change and the evidence\"]}")

counterexample :: T.Text
counterexample =
  result
    ( "{\"kind\":\"challenge\",\"findings\":[{\"requirement\":\"add-adds\",\"claim\":\"only 2 + 2 was fixed\","
        <> "\"basis\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
        <> "\"test\":{\"path\":\"test_counter.py\",\"content\":\"import calc\\nassert calc.add(1, 2) == 3, 'add still wrong'\\n\","
        <> "\"argv\":[\"python3\",\"test_counter.py\"],\"signature\":\"add still wrong\"}}]}"
    )

data Scripts
  = Scripts
  { planner :: [T.Text]
  , challenger :: [T.Text]
  , implementer :: [T.Text]
  , reviewer :: [T.Text]
  }

-- | The happy path: one of each.
happy :: Scripts
happy =
  Scripts [discovery, candidate] [noFindings, noFindings] [fixes] [review "approve"]

engineWith :: Scenario -> Scripts -> IO Engine
engineWith sc scripts = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    pick answers n = scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] answers)
    adapter :: Role -> Int -> Maybe Adapter
    adapter role =
      case role of
        Planner -> pick (planner scripts)
        Challenger -> pick (challenger scripts)
        Implementer -> pick (implementer scripts)
        Reviewer -> pick (reviewer scripts)
  pure (Engine runner adapter)

script :: T.Text -> BS.ByteString
script steps' =
  TE.encodeUtf8 ("{\"steps\":[" <> steps' <> "]}")

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

-- | Starts the transaction and advances it n times; every input in order.
run :: Scenario -> Engine -> Bug -> Int -> IO [StepReport]
run sc engine bug n = do
  view <- accepted (ready (startTransaction (scRuntime sc) (bugWorkOrder bug)))
  traverse (const (accepted (ready (advance (scRuntime sc) engine (viewId view))))) [1 .. n]

lastOf :: [StepReport] -> IO StepReport
lastOf reports =
  case L.reverse reports of
    r : _ -> pure r
    [] -> assertFailure "no step"

recordsOf :: T.Text -> TransactionView -> [T.Text]
recordsOf kind view =
  [recordBody r | r <- viewRecords view, recordKind r == kind]

branchOf :: Bug -> String
branchOf bug =
  "refs/heads/lockstep/" <> T.unpack (bugWorkOrder bug)

-- Cases -------------------------------------------------------------------------------------

-- basis, discovery, reproduction, candidate, challenge, freeze, implement, verify: 8 steps
fixVerified :: Assertion
fixVerified =
  withScenario $ \sc -> do
    bug <- admittedBug sc "fix"
    engine <- engineWith sc happy
    reports <- run sc engine bug 8
    fmap inputOf (L.drop 6 reports) @?= ["implemented", "verification-passed"]
    final <- lastOf reports
    let
      view = viewAfter final
    (viewState view, viewStage view, viewAttempts view) @?= ("running", "challenge-post", 1)
    candidateCommit <-
      case [c | b <- recordsOf "implementation" view, Just c <- [L.find ((== 40) . T.length) (T.splitOn "\"" b)]] of
        c : _ -> pure c
        [] -> assertFailure "no candidate commit recorded"
    freeze <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", branchOf bug]
    shown <- gitIn (bugFolder bug) ["show", "-s", "--format=%an|%P", T.unpack candidateCommit]
    shown @?= "Lockstep Supervisor|" <> T.unpack freeze <> "\n"
    changed <- gitIn (bugFolder bug) ["diff", "--name-only", T.unpack freeze, T.unpack candidateCommit]
    changed @?= "calc.py\n"
    content <- gitIn (bugFolder bug) ["show", T.unpack candidateCommit <> ":calc.py"]
    T.pack content @?= fixed
    assertBool "verification passed on that commit" (L.any (\b -> candidateCommit `T.isInfixOf` b && "\"passed\":true" `T.isInfixOf` b) (recordsOf "verification-summary" view))

refusals :: Assertion
refusals =
  withScenario $ \sc -> do
    let
      attempts =
        [ ("protected", [write "test_calc.py" "import sys\n", write "calc.py" fixed], "protected-test-changed")
        , ("scope", [write "other.py" "x = 1\n", write "calc.py" fixed], "change-outside-scope")
        , ("git", [step "mkdir" "{\"path\":\".git\"}", write ".git/HEAD" "ref: refs/heads/x\n"], "git-directory")
        , ("link", [step "symlink" "{\"path\":\"escape\",\"target\":\"/etc/passwd\"}"], "special-file")
        , ("nothing", [], "no-change")
        ]
    traverse_
      ( \(name, actions, code) -> do
          bug <- admittedBug sc name
          engine <- engineWith sc happy {implementer = [implementation "tried" actions, fixes]}
          reports <- run sc engine bug 7
          final <- lastOf reports
          (inputOf final, viewStage (viewAfter final), viewAttempts (viewAfter final)) @?= ("implementation-refused", "implement", 1)
          assertBool ("refused " <> T.unpack code) (L.any (("\"code\":\"" <> code <> "\"") `T.isInfixOf`) (recordsOf "implementation-refused" (viewAfter final)))
          branch <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", branchOf bug]
          assertBool "the branch is still the freeze commit" (L.any (branch `T.isInfixOf`) (recordsOf "freeze" (viewAfter final)))
      )
      attempts

failingFixes :: Assertion
failingFixes =
  withScenario $ \sc -> do
    bug <- admittedBug sc "failing"
    let
      wrong = implementation "off by one now" [write "calc.py" (T.replace "a - b" "a - b + 1" buggy)]
    engine <- engineWith sc happy {implementer = [wrong, wrong]}
    reports <- run sc engine bug 10
    fmap inputOf (L.drop 6 reports) @?= ["implemented", "verification-failed", "implemented", "verification-failed"]
    final <- lastOf reports
    (viewState (viewAfter final), viewHalt (viewAfter final), viewAttempts (viewAfter final)) @?= ("halted", Just "attempts-exhausted", 2)

wrongButGreen :: Assertion
wrongButGreen =
  withScenario $ \sc -> do
    bug <- admittedBug sc "wrong-green"
    let
      scripts =
        Scripts
          [discovery, candidate]
          [noFindings, counterexample, noFindings]
          [implementation "special case" [write "calc.py" special], fixes]
          [review "approve"]
    engine <- engineWith sc scripts
    reports <- run sc engine bug 15
    fmap inputOf (L.drop 6 reports)
      @?= ["implemented", "verification-passed", "challenge-disposed", "implemented", "verification-passed", "challenge-disposed", "review-approved", "commit-accepted", "idle accepted"]
    final <- lastOf reports
    let
      view = viewAfter final
    (viewState view, viewAttempts view) @?= ("accepted", 2)
    case recordsOf "post-finding" view of
      f : _ -> assertBool ("CONFIRMED: " <> T.unpack f) ("\"disposition\":\"CONFIRMED\"" `T.isInfixOf` f)
      [] -> assertFailure "no post-implementation finding"
    accepted' <- gitIn (bugFolder bug) ["show", branchOf bug <> ":calc.py"]
    T.pack accepted' @?= fixed

reviews :: Assertion
reviews =
  withScenario $ \sc -> do
    bug <- admittedBug sc "rejected"
    engine <- engineWith sc happy {implementer = [fixes, fixes], challenger = [noFindings, noFindings, noFindings], reviewer = [review "reject", review "approve"]}
    reports <- run sc engine bug 15
    fmap inputOf (L.drop 6 reports)
      @?= ["implemented", "verification-passed", "challenge-disposed", "review-rejected", "implemented", "verification-passed", "challenge-disposed", "review-approved", "commit-accepted"]
    bug2 <- admittedBug sc "needs-human"
    engine2 <- engineWith sc happy {reviewer = [review "needs-human"]}
    reports2 <- run sc engine2 bug2 10
    final <- lastOf reports2
    (viewState (viewAfter final), viewHalt (viewAfter final)) @?= ("halted", Just "review-needs-human")
    requests <- L.filter ((== bugWorkOrder bug2) . storedWorkOrder) <$> ready (openRequests (scRuntime sc))
    fmap storedChoices requests @?= [["retry", "stop"]]

acceptance :: Assertion
acceptance =
  withScenario $ \sc -> do
    bug <- admittedBug sc "accept"
    mainBefore <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", "refs/heads/main"]
    engine <- engineWith sc happy
    reports <- run sc engine bug 11
    final <- lastOf reports
    let
      view = viewAfter final
    (inputOf final, viewState view) @?= ("commit-accepted", "accepted")
    head' <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", branchOf bug]
    assertBool "the acceptance names the branch's commit" (L.any (head' `T.isInfixOf`) (recordsOf "acceptance" view))
    author <- gitIn (bugFolder bug) ["show", "-s", "--format=%an <%ae>", T.unpack head']
    author @?= "Lockstep Supervisor <supervisor@lockstep.invalid>\n"
    mainAfter <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", "refs/heads/main"]
    mainAfter @?= mainBefore
    status <- gitIn (bugFolder bug) ["status", "--porcelain"]
    status @?= ""
    remotes <- gitIn (bugFolder bug) ["remote"]
    remotes @?= ""
    content <- gitIn (bugFolder bug) ["show", branchOf bug <> ":calc.py"]
    T.pack content @?= fixed
    again <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    inputOf again @?= "idle accepted"

movedBeforeAcceptance :: Assertion
movedBeforeAcceptance =
  withScenario $ \sc -> do
    bug <- admittedBug sc "moved"
    engine <- engineWith sc happy
    reports <- run sc engine bug 10
    final <- lastOf reports
    viewStage (viewAfter final) @?= "accept"
    main' <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", "refs/heads/main"]
    _ <- gitIn (bugFolder bug) ["update-ref", branchOf bug, T.unpack main']
    after <- accepted (ready (advance (scRuntime sc) engine (viewId (viewAfter final))))
    (viewState (viewAfter after), viewHalt (viewAfter after)) @?= ("halted", Just "supervisor-failed branch-moved")
    head' <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", branchOf bug]
    head' @?= main'

independence :: Assertion
independence =
  withScenario $ \sc -> do
    bug <- admittedBug sc "independent"
    let
      challengerSaw = T.pack (scTmp sc <> "/challenger-context.json")
      reviewerSaw = T.pack (scTmp sc <> "/reviewer-context.json")
      copyTo path answer = step "copy_context" (jsonString path) <> "," <> answer
      scripts =
        happy
          { challenger = [noFindings, copyTo challengerSaw noFindings]
          , reviewer = [copyTo reviewerSaw (review "approve")]
          }
    engine <- engineWith sc scripts
    _ <- run sc engine bug 11
    challenged <- BS.readFile (T.unpack challengerSaw)
    reviewed <- BS.readFile (T.unpack reviewerSaw)
    assertBool "the challenger got the Contract" ("add-adds" `BS.isInfixOf` challenged)
    assertBool "the Reviewer got the evidence" ("verification" `BS.isInfixOf` reviewed)
    assertBool "the challenger never got the Implementer's words" (not ("SECRET-IMPLEMENTER-WORDS" `BS.isInfixOf` challenged))
    assertBool "the Reviewer never got the Implementer's words" (not ("SECRET-IMPLEMENTER-WORDS" `BS.isInfixOf` reviewed))
