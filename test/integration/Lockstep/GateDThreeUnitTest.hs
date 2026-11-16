{-# LANGUAGE OverloadedStrings #-}

{- | Gate D (P6.11), the mandatory three-unit demonstration (Update 2 §9.2) and
D-02, D-03, D-04, model-free, against real PostgreSQL, Git and processes with
scripted roles. A synthetic application, @meter@, needs three genuinely
dependent units: A builds a syllable counter; B builds a line scanner that
imports A's counter; C builds a command line that reads a poem through B and
prints each line's syllables. B's and C's discoveries cite files only their
predecessor's accepted commit has, and their tests can pass only on it.

The owner approves the plan once. The actual scheduler hands each unit over
when its predecessor is technically accepted; the actual engineering pipeline
(basis, discovery, reproduction, candidate tests frozen red, implementation,
verification, challenge, independent review, acceptance) runs each; nothing is
marked Done, pushed or merged. The final branch is then checked out and its
tests and its command line are run for real. When LOCKSTEP_TEST_CASE_DIR is
set, the execution trace is written next to it (@gate-d-trace.txt@).
-}
module Lockstep.GateDThreeUnitTest
  ( tests
  ) where

import Control.Exception (SomeException, try)
import Data.List qualified as L
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Flipstone.Prelude
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Dispatch (DispatchView (..), dispatchView)
import Lockstep.Application.Engine (InvocationView (..), RecordView (..), TransactionView (..))
import Lockstep.Application.Plans (RevisionView)
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (TaskView (..))
import Lockstep.Kernel.Plan (EdgeKind (..), PlanDocument, PlanEdge (..), PlanMode (..), PlanUnit (..))
import Lockstep.Support.Postgres (queryInts)
import Lockstep.Support.Scheduling (Scenario (..), Scripts (..), TestSpec (..), accepted, acceptedCount, approveIn, candidate, count, discovery, engineFor, fixOfTask, fixesAll, gitIn, headOf, k, passesUntil, planOf, projectWith, ready, review, taskOfUnit, truth, unitOf, useEngineering, withScenario)

tests :: TestTree
tests =
  testGroup
    "Gate D the three-unit demonstration (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "one approval; the scheduler hands over three genuinely dependent units in turn, each through the full pipeline on its predecessor's accepted commit; the final application works (D-02, D-03, D-04, §9.2)" threeUnits
    ]

-- The application ---------------------------------------------------------------------------------

prefix :: T.Text
prefix =
  "test-gate-d-three-"

readme, poem :: String
readme = "# Meter\n\nCounts the syllables of each line of a poem.\n"
poem = "the cat sat\non a mat today\n"

syllablesCode, scanCode, cliCode :: T.Text
syllablesCode =
  T.unlines
    [ "VOWELS = \"aeiouy\""
    , ""
    , ""
    , "def count(word):"
    , "    word = word.lower()"
    , "    groups = 0"
    , "    previous = False"
    , "    for letter in word:"
    , "        vowel = letter in VOWELS"
    , "        if vowel and not previous:"
    , "            groups += 1"
    , "        previous = vowel"
    , "    if word.endswith(\"e\") and groups > 1:"
    , "        groups -= 1"
    , "    return groups"
    ]
scanCode =
  T.unlines
    [ "import syllables"
    , ""
    , ""
    , "def line(text):"
    , "    return sum(syllables.count(word) for word in text.split())"
    , ""
    , ""
    , "def poem(text):"
    , "    return [line(row) for row in text.splitlines() if row.strip()]"
    ]
cliCode =
  T.unlines
    [ "import sys"
    , ""
    , "import scan"
    , ""
    , ""
    , "def main(argv):"
    , "    with open(argv[0]) as handle:"
    , "        counts = scan.poem(handle.read())"
    , "    for number, total in enumerate(counts, start=1):"
    , "        print(f\"line {number}: {total} syllables\")"
    , "    return 0"
    , ""
    , ""
    , "if __name__ == \"__main__\":"
    , "    sys.exit(main(sys.argv[1:]))"
    ]

syllablesTest, scanTest, cliTest :: T.Text
syllablesTest =
  T.unlines
    [ "import unittest"
    , ""
    , "import syllables"
    , ""
    , ""
    , "class TestSyllables(unittest.TestCase):"
    , "    def test_count(self):"
    , "        self.assertEqual(syllables.count(\"cat\"), 1)"
    , "        self.assertEqual(syllables.count(\"today\"), 2)"
    , "        self.assertEqual(syllables.count(\"meter\"), 2)"
    , "        self.assertEqual(syllables.count(\"\"), 0)"
    ]
scanTest =
  T.unlines
    [ "import unittest"
    , ""
    , "import scan"
    , ""
    , ""
    , "class TestScan(unittest.TestCase):"
    , "    def test_line(self):"
    , "        self.assertEqual(scan.line(\"the cat sat\"), 3)"
    , ""
    , "    def test_poem(self):"
    , "        self.assertEqual(scan.poem(\"the cat sat\\non a mat today\\n\"), [3, 5])"
    ]
cliTest =
  T.unlines
    [ "import subprocess"
    , "import sys"
    , "import unittest"
    , ""
    , ""
    , "class TestCli(unittest.TestCase):"
    , "    def test_poem(self):"
    , "        result = subprocess.run([sys.executable, \"-m\", \"meter\", \"poem.txt\"], capture_output=True, text=True, check=False)"
    , "        self.assertEqual(result.returncode, 0, result.stderr)"
    , "        self.assertEqual(result.stdout, \"line 1: 3 syllables\\nline 2: 5 syllables\\n\")"
    ]

-- | One unit: key, title, criterion, the files it writes, its test, the file its discovery cites.
data Piece
  = Piece
  { pieceKey :: T.Text
  , pieceTitle :: T.Text
  , pieceCriterion :: T.Text
  , pieceFiles :: [(T.Text, T.Text)]
  , pieceTest :: (T.Text, T.Text)
  , pieceModule :: T.Text
  , pieceCites :: T.Text
  }

counter, scanner, commandLine :: Piece
counter =
  Piece "counter" "Build the syllable counter" "syllables.count gives the syllables of a word." [("syllables.py", syllablesCode)] ("test_syllables.py", syllablesTest) "syllables" "README.md"
scanner =
  Piece "scanner" "Build the line scanner" "scan counts each line's syllables with the syllable counter." [("scan.py", scanCode)] ("test_scan.py", scanTest) "scan" "syllables.py"
commandLine =
  Piece "cli" "Build the command line" "python3 -m meter poem.txt prints each line's syllables." [("meter.py", cliCode)] ("test_cli.py", cliTest) "meter" "scan.py"

pieces :: [Piece]
pieces =
  [counter, scanner, commandLine]

unitOfPiece :: Piece -> PlanUnit
unitOfPiece p =
  (unitOf (pieceKey p) (pieceTitle p) "greenfield" "lockstep-engineering" (pieceCriterion p) (fmap fst (pieceFiles p))) {unitPhase = "P1", unitSubphase = "P1." <> pieceKey p}

meterPlan :: PlanDocument
meterPlan =
  planOf "Meter" Greenfield (fmap unitOfPiece pieces) [PlanEdge (k "scanner") (k "counter") Technical, PlanEdge (k "cli") (k "scanner") Technical]

-- | Each unit's scripted roles: a red-first greenfield build of its files, its test failing at the basis for its stated reason.
scriptsOfPiece :: Piece -> (T.Text, Scripts)
scriptsOfPiece p =
  ( pieceTitle p
  , Scripts
      { scriptsPlanner =
          [ discovery (pieceCites p) (Just ("import " <> pieceModule p, "No module named")) allowed
          , candidate (pieceCriterion p) (pieceCites p) allowed [uncurry TestSpec (pieceTest p) (Just "No module named")]
          ]
      , scriptsFix = fixesAll (pieceFiles p)
      , scriptsReview = review (allowed <> [fst (pieceTest p)])
      }
  )
 where
  allowed = fmap fst (pieceFiles p)

-- Helpers -----------------------------------------------------------------------------------------

-- | The fix of a plan unit.
fixOfUnit :: Scenario -> ProjectView -> RevisionView -> T.Text -> IO TransactionView
fixOfUnit sc view r key =
  taskOfUnit sc view r key >>= fixOfTask sc . taskId

-- | A shell-free process in a folder; its exit and output.
run :: FilePath -> FilePath -> [String] -> IO (ExitCode, String, String)
run dir exe args = do
  finished <- timeout 60000000 (Process.readCreateProcessWithExitCode ((Process.proc exe args) {Process.cwd = Just dir}) "")
  maybe (assertFailure (exe <> " " <> show args <> " did not finish within 60 s")) pure finished

-- | The record kinds of a fix, in order, each once.
recordKinds :: TransactionView -> [T.Text]
recordKinds v =
  L.nub (fmap recordKind (viewRecords v))

-- Case ---------------------------------------------------------------------------------------------

threeUnits :: Assertion
threeUnits =
  withScenario $ \sc -> do
    (view, folder) <- projectWith sc prefix "meter" [("README.md", readme), ("poem.txt", poem)] True
    useEngineering sc view
    -- 1. The owner approves the plan once.
    r <- approveIn sc prefix view "meter" meterPlan
    count sc "lockstep_plan_decisions" >>= (@?= 1)
    -- D-02: the first dependency-ready unit is next, with no manual queue and no hand-over yet.
    before <- accepted (ready (dispatchView (scRuntime sc) (projectId view)))
    dispatchViewNext before @?= Just "counter"
    L.sort (dispatchViewWaiting before) @?= [("cli", "waiting-for"), ("scanner", "waiting-for")]
    count sc "lockstep_bug_admissions" >>= (@?= 0)
    -- 2-7. Only worker passes from here: no person acts until the end.
    engine <- engineFor sc (fmap scriptsOfPiece pieces)
    -- On failure, the refusals and halts each fix recorded are part of the message.
    done <- try (passesUntil sc engine 240 ((== 3) <$> acceptedCount sc)) :: IO (Either SomeException ())
    case done of
      Right () -> pure ()
      Left e -> do
        fixesSoFar <- traverse (try . fixOfUnit sc view r . pieceKey) pieces :: IO [Either SomeException TransactionView]
        assertFailure (show e <> "\nrecords: " <> show [(recordKind x, recordBody x) | Right v <- fixesSoFar, x <- viewRecords v, recordKind x `L.elem` ["implementation-refused", "candidate-rejected", "halt", "basis-refused"]])
    count sc "lockstep_bug_admissions WHERE actor = 'scheduler' AND work_kind = 'greenfield'" >>= (@?= 3)
    count sc "lockstep_plan_dispatches" >>= (@?= 3)
    a <- fixOfUnit sc view r "counter"
    b <- fixOfUnit sc view r "scanner"
    c <- fixOfUnit sc view r "cli"
    -- 3, 9. The established pipeline ran for each, with real verification and an independent review.
    traverse_
      (\v -> traverse_ (\kind -> assertBool ("a fix lacks its " <> T.unpack kind <> " record") (kind `L.elem` recordKinds v)) ["basis", "discovery", "reproduction", "candidate", "freeze", "implementation", "verification", "review", "acceptance"])
      [a, b, c]
    -- Each fix had its own independent Reviewer run, finished.
    traverse_ (\v -> L.length [i | i <- viewInvocations v, invocationWhat i == "reviewer", isJust (invocationOutcome i)] @?= 1) [a, b, c]
    -- 5, 6. Each next unit was handed over only after its predecessor's technical acceptance, by the scheduler.
    let
      handedAfter earlier later =
        "(SELECT x.admitted_at FROM lockstep_bug_admissions x JOIN lockstep_plan_units u ON u.task_id = x.task_id WHERE u.unit_key = '"
          <> later
          <> "' LIMIT 1) > (SELECT rec.recorded_at FROM lockstep_transaction_records rec JOIN lockstep_transactions t ON t.id = rec.transaction_id JOIN lockstep_bug_admissions x ON x.work_order_id = t.work_order_id JOIN lockstep_plan_units u ON u.task_id = x.task_id WHERE u.unit_key = '"
          <> earlier
          <> "' AND rec.kind = 'acceptance' LIMIT 1)"
    truth sc (handedAfter "counter" "scanner") >>= assertBool "the scanner was handed over before the counter was accepted"
    truth sc (handedAfter "scanner" "cli") >>= assertBool "the command line was handed over before the scanner was accepted"
    -- 4 (D-04). Local technical acceptance, no Human Done; nothing pushed; the person's checkout untouched.
    count sc "lockstep_transactions WHERE state = 'done'" >>= (@?= 0)
    gitIn folder ["remote"] >>= (@?= "")
    gitIn folder ["show", "HEAD:README.md"] >>= (@?= readme)
    -- 8. Each built on its predecessor's exact accepted commit.
    let
      branchOf v = maybe (assertFailure "no branch") (pure . T.unpack) (viewBranch v)
    aHead <- branchOf a >>= headOf folder
    bHead <- branchOf b >>= headOf folder
    viewBasis b @?= Just (T.pack aHead)
    viewBasis c @?= Just (T.pack bHead)
    count sc "lockstep_fix_bases" >>= (@?= 2)
    -- 10. The final application, checked out from the last accepted commit, works: its tests and its command line.
    cBranch <- branchOf c
    let
      checked = scTmp sc <> "/final"
    _ <- gitIn folder ["worktree", "add", "-q", checked, cBranch]
    (testsExit, testsOut, testsErr) <- run checked "python3" ["-m", "unittest", "test_syllables", "test_scan", "test_cli"]
    assertBool ("the final tests failed: " <> testsOut <> testsErr) (testsExit == ExitSuccess)
    (cliExit, cliOut, cliErr) <- run checked "python3" ["-m", "meter", "poem.txt"]
    (cliExit, cliOut) @?= (ExitSuccess, "line 1: 3 syllables\nline 2: 5 syllables\n")
    assertBool ("the command line wrote errors: " <> cliErr) (L.null cliErr)
    -- The trace, for the return packet.
    traceTo sc folder [("counter", a), ("scanner", b), ("cli", c)] (testsOut <> testsErr) cliOut

-- | Writes the execution trace next to the test case folder, when there is one.
traceTo :: Scenario -> FilePath -> [(T.Text, TransactionView)] -> String -> String -> IO ()
traceTo sc folder fixes testsOut cliOut = do
  dir <- lookupEnv "LOCKSTEP_TEST_CASE_DIR"
  case dir of
    Nothing -> pure ()
    Just d -> do
      admissions <- queryInts (scAdmin sc) (scDb sc) "SELECT count(*)::integer AS v FROM lockstep_bug_admissions WHERE actor = 'scheduler'"
      logs <- traverse (\(_, v) -> maybe (pure "") (\b -> gitIn folder ["log", "--format=%H %s", T.unpack b]) (viewBranch v)) fixes
      let
        fixLines (key, v) logText =
          [ "unit " <> key <> ": fix " <> viewId v <> ", state " <> viewState v
          , "  basis " <> fromMaybe "-" (viewBasis v) <> ", branch " <> fromMaybe "-" (viewBranch v)
          , "  records: " <> T.intercalate ", " (recordKinds v)
          , "  runs: " <> T.intercalate ", " [invocationStage i <> "/" <> invocationWhat i <> "=" <> fromMaybe "unfinished" (invocationOutcome i) | i <- viewInvocations v]
          , "  branch log:"
          ]
            <> fmap ("    " <>) (T.lines (T.pack logText))
        content =
          T.unlines $
            [ "Gate D three-unit trace (model-free; scripted roles; real Git, PostgreSQL, processes)"
            , "scheduler hand-overs: " <> T.pack (show admissions)
            ]
              <> L.concat (L.zipWith fixLines fixes logs)
              <> ["final tests (python3 -m unittest):", T.pack testsOut, "final command line (python3 -m meter poem.txt):", T.pack cliOut]
      TIO.writeFile (d <> "/../gate-d-trace.txt") content
