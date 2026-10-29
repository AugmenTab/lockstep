{-# LANGUAGE OverloadedStrings #-}

{- | Protected test paths through the real container runner's channel
(contract C-P4.R1 R-P1, R-P2, R-C2): the real @scripts/control-helper@ with
@--runner@ in a throwaway state directory, and a @docker@ stand-in that runs
the requested program on the host with each of the helper's mounts mapped to
its source (a mount whose source is missing fails as docker does, and a
read-only file mount is made read-only). The Kernel's rule and what the helper
accepts agree; a test path the helper could not mount is refused with the
Planner's candidate, before any freeze or Implementer; a path with every
allowed character goes all the way to acceptance through the helper.
-}
module Lockstep.EngineHelperPathTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Engine (Engine (..), RecordView (..), StepReport (..), TransactionView (..), advance, startTransaction)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.HelperRunner (HelperFailure (..), PreparedRun (..), RunnerChannel, openRunnerChannel, prepareRun, submitRun)
import Lockstep.Effects.Process (RunResult (..))
import Lockstep.Effects.Roles (Adapter, helperRunner, scriptedAdapter)
import Lockstep.Foundation.RunnerProtocol (RunProfile (..))
import Lockstep.Kernel.GitBasis (protectedPathValid)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Runner (RunOutcome (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P4.R1 protected test paths through the real helper: one rule, refused before the freeze, accepted all the way"
    [ testCase "R-P1 the Kernel's rule and the helper's channel agree on every path of the table" agreement
    , testCase "R-P2 a test path the helper cannot mount (space, comma, equals sign) is refused with the candidate, before any freeze or Implementer" unsupported
    , testCase "R-P2 a non-ASCII path is refused; a path of every allowed character is frozen, mounted read-only by the helper and accepted" roundTrip
    , testCase "R-C2 traversal stays invalid, a linked path unusable, and a path that differs from a file only in letter case is unusable" preserved
    ]

-- The helper ------------------------------------------------------------------------------------

dockerStub :: String
dockerStub =
  L.unlines
    [ "#!/usr/bin/env python3"
    , "# docker stand-in (C-P4.R1): `run` runs the program on the host, every --mount target in its"
    , "# arguments and working directory mapped to the mount's source."
    , "import os, sys"
    , "here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))"
    , "args = sys.argv[1:]"
    , "with open(os.path.join(here, 'log'), 'a') as log:"
    , "    log.write(' '.join(args) + '\\n')"
    , "if not args:"
    , "    sys.exit(2)"
    , "if args[0] == 'image':"
    , "    print('sha256:stub')"
    , "    sys.exit(0)"
    , "if args[0] in ('ps', 'rm', 'kill'):"
    , "    sys.exit(0)"
    , "if args[0] != 'run':"
    , "    sys.exit(2)"
    , "valued = {'--name', '--network', '--tmpfs', '--cap-drop', '--security-opt', '--pids-limit', '--memory', '--memory-swap', '--cpus', '--user', '--env', '--log-driver'}"
    , "mounts, workdir, i = [], '/', 1"
    , "while i < len(args):"
    , "    a = args[i]"
    , "    if a == '--mount':"
    , "        fields = dict((f.split('=', 1) + [''])[:2] for f in args[i + 1].split(','))"
    , "        mounts.append((fields.get('target', ''), fields.get('source', ''), 'readonly' in fields))"
    , "        i += 2"
    , "    elif a == '--workdir':"
    , "        workdir = args[i + 1]"
    , "        i += 2"
    , "    elif a in valued:"
    , "        i += 2"
    , "    elif a == 'sha256:stub':"
    , "        i += 1"
    , "        break"
    , "    else:"
    , "        i += 1"
    , "program = args[i:]"
    , "for target, source, ro in mounts:"
    , "    if not os.path.exists(source):"
    , "        print('docker: mount source missing: ' + source, file=sys.stderr)"
    , "        sys.exit(125)"
    , "    if ro and os.path.isfile(source):"
    , "        os.chmod(source, 0o444)"
    , "mounts.sort(key=lambda m: -len(m[0]))"
    , "def mapped(p):"
    , "    for target, source, ro in mounts:"
    , "        if p == target or p.startswith(target + '/'):"
    , "            return source + p[len(target):]"
    , "    return p"
    , "os.chdir(mapped(workdir))"
    , "os.execvp(program[0], [mapped(a) for a in program])"
    ]

-- | The real helper with --runner on a throwaway state directory, and its channel.
withHelper :: FilePath -> (FilePath -> RunnerChannel -> IO a) -> IO a
withHelper tmp body = do
  let
    state = tmp <> "/state"
    stub = tmp <> "/stub"
  createDirectoryIfMissing True (tmp <> "/scripts")
  copyFile "scripts/control-helper" (tmp <> "/scripts/control-helper")
  setFileMode (tmp <> "/scripts/control-helper") 0o755
  traverse_ (\d -> createDirectory d >> setFileMode d 0o700) [state, state <> "/helper", state <> "/pane"]
  writeFile (state <> "/helper/channel.key") (L.replicate 64 'd')
  createDirectoryIfMissing True (stub <> "/bin")
  writeFile (stub <> "/bin/docker") dockerStub
  setFileMode (stub <> "/bin/docker") 0o755
  base <- getEnvironment
  let
    path = stub <> "/bin:" <> fromMaybe "/usr/bin:/bin" (L.lookup "PATH" base)
    env = ("PATH", path) : L.filter ((/= "PATH") . fst) base
    start =
      Process.createProcess
        (Process.proc (tmp <> "/scripts/control-helper") ["--state", state, "--instance", "p4r1", "--runner"])
          { Process.env = Just env
          , Process.std_in = Process.NoStream
          , Process.std_out = Process.NoStream
          , Process.std_err = Process.NoStream
          }
    stop (_, _, _, handle) = Process.terminateProcess handle >> void (Process.waitForProcess handle)
  bracket start stop $ \_ -> do
    up <- waitForFile 100 (state <> "/runner/channel.key")
    unless up (assertFailure "the helper did not make the runner key")
    channel <- openRunnerChannel (state <> "/runner")
    case channel of
      Left code -> assertFailure ("channel: " <> T.unpack code)
      Right c -> body (stub <> "/log") c

waitForFile :: Int -> FilePath -> IO Bool
waitForFile ticks path = do
  present <- doesFileExist path
  if present || ticks <= 0
    then pure present
    else threadDelay 100000 >> waitForFile (ticks - 1) path

-- Fixtures ----------------------------------------------------------------------------------------

data Scenario
  = Scenario
  { scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  , scCount :: String -> IO Int
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p4r1-paths" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        let
          counter query = do
            rows <- queryInts admin db query
            case rows of
              [n] -> pure n
              _ -> assertFailure ("count " <> query)
        action (Scenario runtime tmp counter)

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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-paths-key-" <> text))

gitIn :: FilePath -> [String] -> IO ()
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  finished <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case finished of
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git " <> show args <> ": " <> show other)

-- | A project with the buggy calc.py and whatever else the setup adds, committed; Lockstep allowed; the bug handed over.
admittedBug :: Scenario -> T.Text -> (FilePath -> IO ()) -> IO T.Text
admittedBug sc name setup = do
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
  setup folder
  gitIn folder ["add", "-A"]
  gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4" Normal [])))
  readied <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId readied) (taskTicketRevision readied)))
  pure (admissionWorkOrder admission)

-- Role scripts --------------------------------------------------------------------------------------

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

-- | A candidate whose one RED test is at this path, run as a script from the tree.
candidateAt :: T.Text -> T.Text
candidateAt path =
  let
    command = "[\"python3\",\"-c\"," <> jsonString ("import runpy, sys\nsys.path.insert(0, '.')\nrunpy.run_path(" <> pyString path <> ", run_name='__main__')\n") <> "]"
  in
    result
      ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"add-adds\",\"text\":\"add returns the sum\",\"ticket_quote\":\"add(2, 2) is 4\","
          <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}]}],\"allowed_paths\":[\"calc.py\"],"
          <> "\"verification\":["
          <> command
          <> "],\"tests\":[{\"path\":"
          <> jsonString path
          <> ",\"content\":"
          <> jsonString ("import calc\nassert calc.add(2, 2) == 4, 'add is wrong in " <> path <> "'\n")
          <> ",\"expect\":\"red\",\"argv\":"
          <> command
          <> ",\"signature\":\"add is wrong\"}]}"
      )
 where
  pyString p = "'" <> T.replace "'" "\\'" p <> "'"

noFindings :: T.Text
noFindings =
  result "{\"kind\":\"challenge\",\"findings\":[]}"

fixes :: T.Text
fixes =
  "{\"write\":{\"path\":\"calc.py\",\"content\":" <> jsonString "def add(a, b):\n    return a + b\n" <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"add now adds\"}"

approve :: T.Text
approve =
  result "{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"the one-line change makes add add\"]}"

script :: T.Text -> BS.ByteString
script steps =
  TE.encodeUtf8 ("{\"steps\":[" <> steps <> "]}")

engineThrough :: RunnerChannel -> [T.Text] -> Engine
engineThrough channel planner =
  let
    pick answers n = scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] answers)
    adapter :: Role -> Int -> Maybe Adapter
    adapter role =
      case role of
        Planner -> pick planner
        Challenger -> pick [noFindings, noFindings]
        Implementer -> pick [fixes]
        Reviewer -> pick [approve]
  in
    Engine (helperRunner channel) adapter

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

-- | Starts the transaction and advances it n times; every report.
run :: Scenario -> Engine -> T.Text -> Int -> IO [StepReport]
run sc engine workOrder n = do
  view <- accepted (ready (startTransaction (scRuntime sc) workOrder))
  traverse (const (accepted (ready (advance (scRuntime sc) engine (viewId view))))) [1 .. n]

lastOf :: [StepReport] -> IO TransactionView
lastOf reports =
  case L.reverse reports of
    r : _ -> pure (viewAfter r)
    [] -> assertFailure "no step"

recordsOf :: T.Text -> TransactionView -> [T.Text]
recordsOf kind view =
  [recordBody r | r <- viewRecords view, recordKind r == kind]

-- Cases ----------------------------------------------------------------------------------------------

-- | Paths, and whether a file can be made at that path inside a run's tree to test the helper with.
table :: [T.Text]
table =
  [ "tests/test_calc.py"
  , "test_add+v1.2@x-y.py"
  , "a/b/c_d.py"
  , "tests/test bug.py"
  , "tests/a,b.py"
  , "tests/a=b.py"
  , "tests/t\233st.py"
  , "tests/x:y.py"
  , "tests/x;y.py"
  , "tests/x$y.py"
  , "tests/x*y.py"
  , "tests/x'y.py"
  , "../outside.py"
  , "/etc/passwd"
  , "tests/./x.py"
  , ".git/x.py"
  , "a\\b.py"
  ]

agreement :: Assertion
agreement =
  withSystemTempDirectory "lockstep-p4r1-agree" $ \tmp ->
    withHelper tmp $ \_ channel -> do
      outcomes <-
        traverse
          ( \p -> do
              prepared <- prepareRun channel
              let
                file = preparedTree prepared <> "/" <> T.unpack p
                creatable = not (".." `T.isInfixOf` p) && not ("/" `T.isPrefixOf` p)
              when creatable $ do
                createDirectoryIfMissing True (L.reverse (L.dropWhile (/= '/') (L.reverse file)))
                writeFile file "frozen\n"
              r <- submitRun channel prepared ProfileWrite ["/bin/true"] [p] 30
              let
                ran =
                  case r of
                    Right res -> resultOutcome res == Exited 0
                    Left (HelperRequestInvalid _) -> False
                    Left (HelperRefused _) -> False
                    Left _ -> False
              pure (p, ran, protectedPathValid p)
          )
          table
      let
        disagreements = [(p, ran, kernel) | (p, ran, kernel) <- outcomes, ran /= kernel]
      assertBool ("the helper ran / the Kernel accepts, where they differ: " <> show disagreements) (L.null disagreements)
      fmap (\(p, ran, _) -> (p, ran)) (L.take 3 outcomes) @?= [("tests/test_calc.py", True), ("test_add+v1.2@x-y.py", True), ("a/b/c_d.py", True)]

unsupported :: Assertion
unsupported =
  withScenario $ \sc ->
    withHelper (scTmp sc) $ \_ channel -> do
      workOrder <- admittedBug sc "unsupported" (const (pure ()))
      let
        engine = engineThrough channel [discovery, candidateAt "tests/test bug.py", candidateAt "tests/a,b.py", candidateAt "tests/a=b.py"]
      reports <- run sc engine workOrder 6
      fmap inputOf (L.drop 3 reports) @?= ["candidate-rejected", "candidate-rejected", "candidate-rejected"]
      view <- lastOf reports
      (viewState view, viewHalt view) @?= ("halted", Just "candidates-exhausted")
      L.length (L.filter ("\"code\":\"test-path-unsupported\"" `T.isInfixOf`) (recordsOf "candidate-rejected" view)) @?= 3
      recordsOf "freeze" view @?= []
      scCount sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'implementer'" >>= (@?= 0)

roundTrip :: Assertion
roundTrip =
  withScenario $ \sc ->
    withHelper (scTmp sc) $ \dockerLog channel -> do
      workOrder <- admittedBug sc "round-trip" (const (pure ()))
      let
        good = "test_add+v1.2@x-y.py"
        engine = engineThrough channel [discovery, candidateAt "tests/t\233st.py", candidateAt good]
      reports <- run sc engine workOrder 12
      fmap inputOf (L.drop 3 reports)
        @?= ["candidate-rejected", "candidate-classified", "challenge-disposed", "tests-frozen", "implemented", "verification-passed", "challenge-disposed", "review-approved", "commit-accepted"]
      view <- lastOf reports
      viewState view @?= "accepted"
      assertBool "the non-ASCII path was refused as unsupported" (L.any ("\"code\":\"test-path-unsupported\"" `T.isInfixOf`) (recordsOf "candidate-rejected" view))
      logged <- BS.readFile dockerLog
      assertBool "the helper mounted the protected test read-only" (("target=/work/tree/" <> TE.encodeUtf8 good <> ",readonly") `BS.isInfixOf` logged)
      scCount sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE runner = 'container' AND what = 'implementer' AND outcome = 'answered'" >>= (@?= 1)

preserved :: Assertion
preserved =
  withScenario $ \sc ->
    withHelper (scTmp sc) $ \_ channel -> do
      traversal <- admittedBug sc "traversal" (const (pure ()))
      r1 <- run sc (engineThrough channel [discovery, candidateAt "../outside.py"]) traversal 4
      v1 <- lastOf r1
      (viewState v1, viewHalt v1) @?= ("halted", Just "role-failed answer-invalid tests-invalid")
      linked <- admittedBug sc "linked" (\folder -> createDirectory (folder <> "/tests") >> createSymbolicLink "../calc.py" (folder <> "/tests/link_test.py"))
      r2 <- run sc (engineThrough channel [discovery, candidateAt "tests/link_test.py"]) linked 4
      v2 <- lastOf r2
      assertBool ("a linked path is unusable: " <> show (recordsOf "candidate-rejected" v2)) (L.any ("\"code\":\"test-path-unusable\"" `T.isInfixOf`) (recordsOf "candidate-rejected" v2))
      folded <- admittedBug sc "folded" (\folder -> writeFile (folder <> "/Test_calc.py") "# the person's own file\n")
      r3 <- run sc (engineThrough channel [discovery, candidateAt "test_calc.py"]) folded 4
      v3 <- lastOf r3
      fmap inputOf (L.drop 3 r3) @?= ["candidate-rejected"]
      assertBool ("a path that folds onto another is unusable: " <> show (recordsOf "candidate-rejected" v3)) (L.any ("\"code\":\"test-path-unusable\"" `T.isInfixOf`) (recordsOf "candidate-rejected" v3))
