{-# LANGUAGE OverloadedStrings #-}

{- | Candidate tests, their challenge and the freeze, against real PostgreSQL,
Git and processes (contract C-P4.7–9 S1–S3): the same project and bug as
C-P4.6, the scripted Planner and challenger on the direct runner. Every run
the Supervisor makes — the baseline, each mutant, each demonstration — is a
real process on a real snapshot.
-}
module Lockstep.EngineCandidateTest
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
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, directRunner, scriptedAdapter)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (databaseConfigFor, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P4.7-9 candidate tests, the challenge before the freeze, and the freeze (real Git, processes, PostgreSQL)"
    [ testCase "a grounded candidate whose RED test fails for its reason reaches the challenge" goodCandidate
    , testCase "an ungrounded criterion or a citation outside the source goes back to the Planner" rejected
    , testCase "RED that passes, RED for the wrong reason, a failing new GREEN: corrections, then exhausted" corrections
    , testCase "a failing GREEN test the basis already has is a pre-existing failure: halted for a person" regression
    , testCase "a test program that is not there halts: verification-environment-missing" environment
    , testCase "a surviving mutant that shows the bug again is CONFIRMED and sends the candidate back" confirmed
    , testCase "killed, ungrounded and out-of-scope mutants are never CONFIRMED; the freeze follows" notConfirmed
    , testCase "a finding that needs a person blocks the freeze with a decision request" needsHuman
    , testCase "the freeze: the Supervisor commits exactly the tests on the work branch and records the Contract" freeze
    , testCase "a work branch moved by someone else is never frozen over" branchMoved
    ]

-- Fixtures ----------------------------------------------------------------------------

data Scenario
  = Scenario
  { scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p47" $ \tmp -> do
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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-candidate-key-" <> text))

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

calcSource :: String
calcSource =
  "def add(a, b):\n    return a - b\n\n\ndef mul(a, b):\n    return a * b\n\n\ndef double(a):\n    return add(a, a)\n"

mulTest :: String
mulTest =
  "import unittest\nimport calc\n\n\nclass TestMul(unittest.TestCase):\n    def test_mul(self):\n        self.assertEqual(calc.mul(3, 4), 12)\n"

doubleTest :: String
doubleTest =
  "import unittest\nimport calc\n\n\nclass TestDouble(unittest.TestCase):\n    def test_double(self):\n        self.assertEqual(calc.double(2), 4, 'double is wrong')\n"

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
  writeFile (folder <> "/calc.py") calcSource
  writeFile (folder <> "/test_mul.py") mulTest
  writeFile (folder <> "/test_double.py") doubleTest
  _ <- gitIn folder ["add", "calc.py", "test_mul.py", "test_double.py"]
  _ <- gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4 and add(1, 2) is 3" Normal [])))
  readied <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId readied) (taskTicketRevision readied)))
  pure (Bug folder (admissionWorkOrder admission))

-- Scripts --------------------------------------------------------------------------------

result :: T.Text -> T.Text
result answer =
  "{\"result\":" <> answer <> "}"

discovery :: T.Text
discovery =
  result
    ( "{\"kind\":\"discovery\",\"summary\":\"add subtracts\",\"hypothesis\":\"calc.add uses minus\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
        <> "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"import calc; assert calc.add(2, 2) == 4, 'add is wrong'\"],\"signature\":\"add is wrong\"},"
        <> "\"allowed_paths\":[\"calc.py\"]}"
    )

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

redTestSource :: T.Text
redTestSource =
  "import unittest\nimport calc\n\n\nclass TestAdd(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(calc.add(2, 2), 4, 'add is wrong')\n"

-- | A test entry: path, content, expect, argv, signature.
testEntry :: T.Text -> T.Text -> T.Text -> [T.Text] -> Maybe T.Text -> T.Text
testEntry path content expect argv signature =
  "{\"path\":"
    <> jsonString path
    <> ",\"content\":"
    <> jsonString content
    <> ",\"expect\":"
    <> jsonString expect
    <> ",\"argv\":["
    <> T.intercalate "," (fmap jsonString argv)
    <> "]"
    <> maybe "" (\s -> ",\"signature\":" <> jsonString s) signature
    <> "}"

redTest :: T.Text
redTest =
  testEntry "test_calc.py" redTestSource "red" ["python3", "-m", "unittest", "test_calc"] (Just "add is wrong")

candidateWith :: T.Text -> T.Text -> [T.Text] -> T.Text
candidateWith quote citation entries =
  result
    ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"add-adds\",\"text\":\"add returns the sum\",\"ticket_quote\":"
        <> jsonString quote
        <> ",\"citations\":["
        <> citation
        <> "]}],\"allowed_paths\":[\"calc.py\"],\"verification\":[[\"python3\",\"-m\",\"unittest\",\"test_calc\",\"test_mul\"]],\"tests\":["
        <> T.intercalate "," entries
        <> "]}"
    )

goodCitation :: T.Text
goodCitation =
  "{\"path\":\"calc.py\",\"first\":1,\"last\":2}"

candidate :: T.Text
candidate =
  candidateWith "add(2, 2) is 4" goodCitation [redTest]

challenge :: [T.Text] -> T.Text
challenge findings =
  result ("{\"kind\":\"challenge\",\"findings\":[" <> T.intercalate "," findings <> "]}")

-- | A finding: requirement, mutant files, demonstration, hint.
finding :: T.Text -> [(T.Text, T.Text)] -> Maybe ([T.Text], T.Text) -> Maybe T.Text -> T.Text
finding requirement mutant demonstration hint =
  "{\"requirement\":"
    <> jsonString requirement
    <> ",\"claim\":\"the tests let a wrong add through\",\"basis\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}]"
    <> (if L.null mutant then "" else ",\"mutant\":[" <> T.intercalate "," ["{\"path\":" <> jsonString p <> ",\"content\":" <> jsonString c <> "}" | (p, c) <- mutant] <> "]")
    <> maybe "" (\(argv, s) -> ",\"demonstration\":{\"argv\":[" <> T.intercalate "," (fmap jsonString argv) <> "],\"signature\":" <> jsonString s <> "}") demonstration
    <> maybe "" (\h -> ",\"hint\":" <> jsonString h) hint
    <> "}"

-- | Passes the RED test (2 + 2) but still subtracts otherwise.
specialCase :: T.Text
specialCase =
  "def add(a, b):\n    if (a, b) == (2, 2):\n        return 4\n    return a - b\n\n\ndef mul(a, b):\n    return a * b\n\n\ndef double(a):\n    return add(a, a)\n"

stillWrong :: ([T.Text], T.Text)
stillWrong =
  (["python3", "-c", "import calc; assert calc.add(1, 2) == 3, 'add still wrong'"], "add still wrong")

script :: T.Text -> BS.ByteString
script answer =
  TE.encodeUtf8 ("{\"steps\":[" <> answer <> "]}")

engineWith :: Scenario -> [T.Text] -> [T.Text] -> IO Engine
engineWith sc planner challenger = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    pick answers n = scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] answers)
    adapter :: Role -> Int -> Maybe Adapter
    adapter role n =
      case role of
        Planner -> pick planner n
        Challenger -> pick challenger n
        _ -> Nothing
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

-- | Starts the transaction and advances it n times; the last report.
steps :: Scenario -> Engine -> Bug -> Int -> IO StepReport
steps sc engine bug n = do
  view <- accepted (ready (startTransaction (scRuntime sc) (bugWorkOrder bug)))
  let
    go k last'
      | k <= 0 = maybe (assertFailure "no step") pure last'
      | otherwise = do
          r <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
          go (k - 1 :: Int) (Just r)
  go n Nothing

recordsOf :: T.Text -> TransactionView -> [T.Text]
recordsOf kind view =
  [recordBody r | r <- viewRecords view, recordKind r == kind]

requestsFor :: Scenario -> Bug -> IO [StoredRequest]
requestsFor sc bug =
  L.filter ((== bugWorkOrder bug) . storedWorkOrder) <$> ready (openRequests (scRuntime sc))

-- Cases ---------------------------------------------------------------------------------------

-- basis, discovery, reproduction, candidate: four steps to the candidate's classification
goodCandidate :: Assertion
goodCandidate =
  withScenario $ \sc -> do
    bug <- admittedBug sc "good"
    engine <- engineWith sc [discovery, candidate] []
    report <- steps sc engine bug 4
    inputOf report @?= "candidate-classified"
    (viewState (viewAfter report), viewStage (viewAfter report), viewCandidates (viewAfter report)) @?= ("running", "challenge-pre", 1)
    case recordsOf "baseline" (viewAfter report) of
      [b] -> assertBool ("red-confirmed: " <> T.unpack b) ("\"class\":\"red-confirmed\"" `T.isInfixOf` b)
      other -> assertFailure ("baseline records: " <> show other)

rejected :: Assertion
rejected =
  withScenario $ \sc -> do
    bug <- admittedBug sc "rejected"
    let
      ungrounded = candidateWith "add multiplies" goodCitation [redTest]
      outside = candidateWith "add(2, 2) is 4" "{\"path\":\"calc.py\",\"first\":90,\"last\":95}" [redTest]
    engine <- engineWith sc [discovery, ungrounded, outside, candidate] []
    first <- steps sc engine bug 4
    (inputOf first, viewStage (viewAfter first), viewCandidates (viewAfter first)) @?= ("candidate-rejected", "candidate", 1)
    assertBool "the code is recorded" (L.any ("criterion-not-grounded" `T.isInfixOf`) (recordsOf "candidate-rejected" (viewAfter first)))
    second <- accepted (ready (advance (scRuntime sc) engine (viewId (viewAfter first))))
    assertBool "outside the source" (L.any ("citation-outside-source" `T.isInfixOf`) (recordsOf "candidate-rejected" (viewAfter second)))
    third <- accepted (ready (advance (scRuntime sc) engine (viewId (viewAfter first))))
    (inputOf third, viewStage (viewAfter third)) @?= ("candidate-classified", "challenge-pre")

corrections :: Assertion
corrections =
  withScenario $ \sc -> do
    bug <- admittedBug sc "corrections"
    let
      passes = candidateWith "add(2, 2) is 4" goodCitation [testEntry "test_calc.py" (T.replace "4, 'add" "0, 'add" redTestSource) "red" ["python3", "-m", "unittest", "test_calc"] (Just "add is wrong")]
      wrongReason = candidateWith "add(2, 2) is 4" goodCitation [testEntry "test_calc.py" "import nothing_here\n" "red" ["python3", "-m", "unittest", "test_calc"] (Just "add is wrong")]
      badGreen = candidateWith "add(2, 2) is 4" goodCitation [redTest, testEntry "test_extra.py" "import sys\nsys.exit(3)\n" "green" ["python3", "test_extra.py"] Nothing]
    engine <- engineWith sc [discovery, passes, wrongReason, badGreen] []
    first <- steps sc engine bug 4
    (viewStage (viewAfter first), viewCandidates (viewAfter first)) @?= ("candidate", 1)
    assertBool "unexpectedly passed" (L.any ("red-unexpectedly-passed" `T.isInfixOf`) (recordsOf "baseline" (viewAfter first)))
    second <- accepted (ready (advance (scRuntime sc) engine (viewId (viewAfter first))))
    assertBool "wrong reason" (L.any ("red-wrong-reason" `T.isInfixOf`) (recordsOf "baseline" (viewAfter second)))
    third <- accepted (ready (advance (scRuntime sc) engine (viewId (viewAfter first))))
    assertBool "a failing new GREEN" (L.any ("green-candidate-failed" `T.isInfixOf`) (recordsOf "baseline" (viewAfter third)))
    (viewState (viewAfter third), viewHalt (viewAfter third), viewCandidates (viewAfter third)) @?= ("halted", Just "candidates-exhausted", 3)
    requests <- requestsFor sc bug
    fmap storedChoices requests @?= [["retry", "stop"]]

regression :: Assertion
regression =
  withScenario $ \sc -> do
    bug <- admittedBug sc "regression"
    let
      withExisting = candidateWith "add(2, 2) is 4" goodCitation [redTest, testEntry "test_double.py" (T.pack doubleTest) "green" ["python3", "-m", "unittest", "test_double"] Nothing]
    engine <- engineWith sc [discovery, withExisting] []
    report <- steps sc engine bug 4
    inputOf report @?= "regression-failed"
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "green-regression-failed")

environment :: Assertion
environment =
  withScenario $ \sc -> do
    bug <- admittedBug sc "environment"
    let
      missing = candidateWith "add(2, 2) is 4" goodCitation [testEntry "test_calc.py" redTestSource "red" ["no-such-test-runner", "test_calc"] (Just "add is wrong")]
    engine <- engineWith sc [discovery, missing] []
    report <- steps sc engine bug 4
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "verification-environment-missing")

confirmed :: Assertion
confirmed =
  withScenario $ \sc -> do
    bug <- admittedBug sc "confirmed"
    engine <- engineWith sc [discovery, candidate, candidate] [challenge [finding "add-adds" [("calc.py", specialCase)] (Just stillWrong) Nothing]]
    report <- steps sc engine bug 5
    inputOf report @?= "challenge-disposed"
    (viewStage (viewAfter report), viewCandidates (viewAfter report)) @?= ("candidate", 1)
    case recordsOf "finding" (viewAfter report) of
      [f] -> do
        assertBool ("CONFIRMED: " <> T.unpack f) ("\"disposition\":\"CONFIRMED\"" `T.isInfixOf` f)
        assertBool "survived and demonstrated" ("survived-demonstrated" `T.isInfixOf` f)
      other -> assertFailure ("findings: " <> show other)

notConfirmed :: Assertion
notConfirmed =
  withScenario $ \sc -> do
    bug <- admittedBug sc "not-confirmed"
    let
      findings =
        [ finding "add-adds" [("calc.py", T.pack calcSource)] (Just stillWrong) Nothing
        , finding "not-a-criterion" [("calc.py", specialCase)] (Just stillWrong) Nothing
        , finding "add-adds" [("test_calc.py", "import sys\n")] (Just stillWrong) Nothing
        , finding "add-adds" [] Nothing Nothing
        ]
    engine <- engineWith sc [discovery, candidate] [challenge findings]
    report <- steps sc engine bug 5
    (inputOf report, viewStage (viewAfter report)) @?= ("challenge-disposed", "freeze")
    fmap (\f -> L.find (`T.isInfixOf` f) ["DISPROVED", "CONFIRMED", "INCONCLUSIVE", "NEEDS_HUMAN"]) (recordsOf "finding" (viewAfter report))
      @?= [Just "DISPROVED", Just "INCONCLUSIVE", Just "INCONCLUSIVE", Just "INCONCLUSIVE"]

needsHuman :: Assertion
needsHuman =
  withScenario $ \sc -> do
    bug <- admittedBug sc "needs-human"
    engine <- engineWith sc [discovery, candidate] [challenge [finding "add-adds" [] Nothing (Just "needs-human")]]
    report <- steps sc engine bug 5
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "finding-needs-human")
    requests <- requestsFor sc bug
    fmap storedChoices requests @?= [["retry", "stop"]]

sha256Hex :: T.Text -> T.Text
sha256Hex text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

freeze :: Assertion
freeze =
  withScenario $ \sc -> do
    bug <- admittedBug sc "freeze"
    engine <- engineWith sc [discovery, candidate] [challenge []]
    report <- steps sc engine bug 6
    inputOf report @?= "tests-frozen"
    let
      view = viewAfter report
      branch = "refs/heads/lockstep/" <> T.unpack (bugWorkOrder bug)
    (viewState view, viewStage view) @?= ("running", "implement")
    head' <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", branch]
    basis <- maybe (assertFailure "no basis") pure (viewBasis view)
    shown <- gitIn (bugFolder bug) ["show", "-s", "--format=%an|%ae|%P", T.unpack head']
    shown @?= "Lockstep Supervisor|supervisor@lockstep.invalid|" <> T.unpack basis <> "\n"
    changed <- gitIn (bugFolder bug) ["diff", "--name-only", T.unpack basis, T.unpack head']
    changed @?= "test_calc.py\n"
    content <- gitIn (bugFolder bug) ["show", T.unpack head' <> ":test_calc.py"]
    T.pack content @?= redTestSource
    case recordsOf "contract" view of
      [c] -> do
        assertBool "the contract names the freeze commit" (head' `T.isInfixOf` c)
        assertBool "and the test's digest" (sha256Hex redTestSource `T.isInfixOf` c)
        assertBool "the freeze record carries the contract's digest" (L.any (sha256Hex c `T.isInfixOf`) (recordsOf "freeze" view))
      other -> assertFailure ("contract records: " <> show other)
    status <- gitIn (bugFolder bug) ["status", "--porcelain"]
    status @?= ""
    current <- gitIn (bugFolder bug) ["symbolic-ref", "HEAD"]
    current @?= "refs/heads/main\n"

branchMoved :: Assertion
branchMoved =
  withScenario $ \sc -> do
    bug <- admittedBug sc "moved"
    engine <- engineWith sc [discovery, candidate] [challenge []]
    report <- steps sc engine bug 5
    viewStage (viewAfter report) @?= "freeze"
    -- someone else moves the work branch
    writeFile (bugFolder bug <> "/other.txt") "other\n"
    _ <- gitIn (bugFolder bug) ["add", "other.txt"]
    _ <- gitIn (bugFolder bug) ["commit", "-q", "-m", "other"]
    other <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", "HEAD"]
    _ <- gitIn (bugFolder bug) ["update-ref", "refs/heads/lockstep/" <> T.unpack (bugWorkOrder bug), T.unpack other]
    frozen <- accepted (ready (advance (scRuntime sc) engine (viewId (viewAfter report))))
    (viewState (viewAfter frozen), viewHalt (viewAfter frozen)) @?= ("halted", Just "supervisor-failed branch-moved")
    head' <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", "refs/heads/lockstep/" <> T.unpack (bugWorkOrder bug)]
    head' @?= other
