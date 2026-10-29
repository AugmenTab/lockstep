{-# LANGUAGE OverloadedStrings #-}

{- | The second remediation (contract C-P4.R2), from the review of C-P4.R1 and
P4.17: a bounded stop stays bounded when the helper has gone; two engines on
one database never run one role twice; a workspace whose run's outcome is
unknown is kept; a tree with paths that differ only in letter case is never
written; a filter driver name that is not exact UTF-8 is refused; a protected
test path beyond the host's limits is rejected with the candidate. Real
PostgreSQL, Git and processes; the real host helper with a @docker@ stand-in.
-}
module Lockstep.EngineRecoveryTwoTest
  ( tests
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Flipstone.Prelude
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, doesFileExist, listDirectory, removeFile, setModificationTime)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory, withTempDirectory)
import System.Posix.Files (setFileMode)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, testCaseInfo, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Engine (Engine (..), RecordView (..), StepReport (..), TransactionView (..), advance, startTransaction)
import Lockstep.Application.EngineWorker (startEngineWorker, stopEngineWorkerWithin)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.GitSupervisor (Basis (..), observeBasis, writeSnapshot)
import Lockstep.Effects.HelperRunner (openRunnerChannel)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, Runner (..), RunnerFailure (..), directRunner, helperRunner, scriptedAdapter)
import Lockstep.Foundation.RunnerProtocol (RunProfile (..))
import Lockstep.Foundation.SystemConfig (DatabaseConfig)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P4.R2 the second remediation: bounded stop, one run per role, workspaces in use kept, folded trees, exact filter names, host path limits"
    [ testCase "R2-W with the helper gone mid-run, a bounded stop still returns in time and the run stays unknown" boundedWithoutHelper
    , testCase "R2-I two engines on one database advancing one transaction run its role once" twoEngines
    , testCase "R2-K a stage whose run ended with an unknown outcome keeps its workspace" unknownKept
    , testCaseInfo "R2-C on a disk that folds letter case, a tree with paths that differ only in letter case is never written" foldedTree
    , testCase "R2-G a filter driver name that is not exact UTF-8 is refused, and its filter never runs" bytesFilter
    , testCase "R2-P a test path segment beyond the host's limit is rejected with the candidate" longSegment
    ]

-- Fixtures ---------------------------------------------------------------------------------------

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scConfig :: DatabaseConfig
  , scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p4r2" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/work")
        action (Scenario admin db config runtime tmp)

accepted :: Show e => IO (Either e a) -> IO a
accepted action =
  action >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-recovery-two-" <> text))

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
    Just (ExitSuccess, out, _) -> pure out
    other -> assertFailure ("git " <> show args <> ": " <> show other)

-- | A project with the buggy calc.py, Lockstep allowed, the bug handed over and its transaction started.
startedBug :: Scenario -> T.Text -> IO TransactionView
startedBug sc name = do
  let
    folders = ProjectFolders (Just (scTmp sc <> "/projects")) []
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) folders (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
  _ <- gitIn folder ["add", "calc.py"]
  _ <- gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (scRuntime sc) folders ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4" Normal [])))
  readied <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (scRuntime sc) folders ak (taskId readied) (taskTicketRevision readied)))
  accepted (ready (startTransaction (scRuntime sc) (admissionWorkOrder admission)))

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) query
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count: " <> query)

waitFor :: Int -> IO Bool -> IO Bool
waitFor ticks check = do
  ok <- check
  if ok || ticks <= 0 then pure ok else threadDelay 100000 >> waitFor (ticks - 1) check

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

candidateAt :: T.Text -> T.Text
candidateAt path =
  result
    ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"add-adds\",\"text\":\"add returns the sum\",\"ticket_quote\":\"add(2, 2) is 4\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}]}],\"allowed_paths\":[\"calc.py\"],"
        <> "\"verification\":[[\"python3\",\"-m\",\"unittest\",\"test_calc\"]],\"tests\":[{\"path\":"
        <> jsonString path
        <> ",\"content\":\"import calc\\nassert calc.add(2, 2) == 4, 'add is wrong'\\n\""
        <> ",\"expect\":\"red\",\"argv\":[\"python3\","
        <> jsonString path
        <> "],\"signature\":\"add is wrong\"}]}"
    )

script :: T.Text -> BS.ByteString
script steps =
  TE.encodeUtf8 ("{\"steps\":[" <> steps <> "]}")

-- | The Planner answers these, in turn; no other role answers.
plannerOnly :: Runner -> [T.Text] -> Engine
plannerOnly runner answers =
  let
    adapter :: Role -> Int -> Maybe Adapter
    adapter role n =
      case role of
        Planner -> scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] answers)
        _ -> Nothing
  in
    Engine runner adapter

directEngine :: Scenario -> [T.Text] -> IO Engine
directEngine sc answers = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  pure (plannerOnly runner answers)

-- The helper ------------------------------------------------------------------------------------------

dockerStub :: String
dockerStub =
  L.unlines
    [ "#!/usr/bin/env python3"
    , "# docker stand-in (C-P4.R2): `run` runs the program on the host with the helper's mounts mapped."
    , "import os, sys"
    , "args = sys.argv[1:]"
    , "if not args:"
    , "    sys.exit(2)"
    , "if args[0] == 'image':"
    , "    print('sha256:stub')"
    , "    sys.exit(0)"
    , "if args[0] in ('ps', 'rm', 'kill'):"
    , "    sys.exit(0)"
    , "valued = {'--name', '--network', '--tmpfs', '--cap-drop', '--security-opt', '--pids-limit', '--memory', '--memory-swap', '--cpus', '--user', '--env', '--log-driver'}"
    , "mounts, workdir, i = [], '/', 1"
    , "while i < len(args):"
    , "    a = args[i]"
    , "    if a == '--mount':"
    , "        fields = dict((f.split('=', 1) + [''])[:2] for f in args[i + 1].split(','))"
    , "        mounts.append((fields.get('target', ''), fields.get('source', '')))"
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
    , "mounts.sort(key=lambda m: -len(m[0]))"
    , "def mapped(p):"
    , "    for target, source in mounts:"
    , "        if p == target or p.startswith(target + '/'):"
    , "            return source + p[len(target):]"
    , "    return p"
    , "os.chdir(mapped(workdir))"
    , "os.execvp(program[0], [mapped(a) for a in program])"
    ]

-- | The real helper with --runner; its runner directory and a way to stop it early.
withHelper :: FilePath -> (FilePath -> IO () -> IO a) -> IO a
withHelper tmp body = do
  let
    state = tmp <> "/state"
    stub = tmp <> "/stub"
  createDirectoryIfMissing True (tmp <> "/scripts")
  copyFile "scripts/control-helper" (tmp <> "/scripts/control-helper")
  setFileMode (tmp <> "/scripts/control-helper") 0o755
  traverse_ (\d -> createDirectory d >> setFileMode d 0o700) [state, state <> "/helper", state <> "/pane"]
  writeFile (state <> "/helper/channel.key") (L.replicate 64 'f')
  createDirectoryIfMissing True (stub <> "/bin")
  writeFile (stub <> "/bin/docker") dockerStub
  setFileMode (stub <> "/bin/docker") 0o755
  base <- getEnvironment
  let
    path = stub <> "/bin:" <> fromMaybe "/usr/bin:/bin" (L.lookup "PATH" base)
    env = ("PATH", path) : L.filter ((/= "PATH") . fst) base
    start =
      Process.createProcess
        (Process.proc (tmp <> "/scripts/control-helper") ["--state", state, "--instance", "p4r2", "--runner"])
          { Process.env = Just env
          , Process.std_in = Process.NoStream
          , Process.std_out = Process.NoStream
          , Process.std_err = Process.NoStream
          }
    stop (_, _, _, handle) = Process.terminateProcess handle >> void (Process.waitForProcess handle)
    -- Gone without a word: no interrupted result, no answer to anything.
    vanish (_, _, _, handle) = do
      pid <- Process.getPid handle
      traverse_ (signalProcess sigKILL) pid
      void (Process.waitForProcess handle)
  bracket start stop $ \helper -> do
    up <- waitFor 100 (doesFileExist (state <> "/runner/channel.key"))
    unless up (assertFailure "the helper did not make the runner key")
    body (state <> "/runner") (vanish helper)

-- Cases ------------------------------------------------------------------------------------------------

boundedWithoutHelper :: Assertion
boundedWithoutHelper =
  withScenario $ \sc ->
    withHelper (scTmp sc) $ \runnerDir stopHelper -> do
      channel <- openRunnerChannel runnerDir >>= either (assertFailure . T.unpack) pure
      let
        marker = scTmp sc <> "/ran"
        slow = "{\"append\":{\"path\":" <> jsonString (T.pack marker) <> ",\"content\":\"ran\\n\"}},{\"sleep\":30}," <> discovery
      view <- startedBug sc "bounded"
      _ <- accepted (ready (advance (scRuntime sc) (plannerOnly (helperRunner channel) []) (viewId view)))
      worker <- startEngineWorker (scRuntime sc) (plannerOnly (helperRunner channel) [slow]) 50 (const (pure ()))
      running <- waitFor 300 (doesFileExist marker)
      assertBool "the Planner never started in the helper's container" running
      -- The helper goes away while the role runs: nobody will answer a cancel.
      stopHelper
      t0 <- getCurrentTime
      stopped <- timeout 30000000 (stopEngineWorkerWithin 2 worker)
      t1 <- getCurrentTime
      assertBool ("the stop returned: " <> show stopped) (isJust stopped)
      assertBool ("the bounded stop took " <> show (diffUTCTime t1 t0)) (diffUTCTime t1 t0 < 6)
      count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE finished_at IS NULL" >>= (@?= 1)

twoEngines :: Assertion
twoEngines =
  withScenario $ \sc -> do
    view <- startedBug sc "two-engines"
    cancel <- newCancel
    runner <- directRunner cancel (scTmp sc <> "/work")
    let
      slowPrepare = runner {runnerPrepare = threadDelay 1000000 >> runnerPrepare runner}
      engine = plannerOnly slowPrepare [discovery, discovery]
    first <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    inputOf first @?= "basis-ready"
    doneA <- newEmptyMVar
    doneB <- newEmptyMVar
    _ <- forkIO (withRuntime (scConfig sc) (\rt -> advance rt engine (viewId view)) >>= putMVar doneA . fmap (fmap inputOf))
    _ <- forkIO (withRuntime (scConfig sc) (\rt -> advance rt engine (viewId view)) >>= putMVar doneB . fmap (fmap inputOf))
    a <- takeMVar doneA
    b <- takeMVar doneB
    L.sort [show a, show b] @?= L.sort [show (Right (Right "discovery-answered") :: Either () (Either T.Text T.Text)), show (Right (Left "stale-step") :: Either () (Either T.Text T.Text))]
    count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'planner'" >>= (@?= 1)

unknownKept :: Assertion
unknownKept =
  withScenario $ \sc -> do
    view <- startedBug sc "unknown"
    cancel <- newCancel
    runner <- directRunner cancel (scTmp sc <> "/work")
    let
      lost = runner {runnerRun = \w p l a pr -> if p == ProfileReadOnly then pure (Left (RunnerUncertain "helper-no-result")) else runnerRun runner w p l a pr}
      engine = plannerOnly lost [discovery]
    _ <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    report <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "uncertain-invocation helper-no-result")
    kept <- listDirectory (scTmp sc <> "/work")
    L.length kept @?= 1

foldedTree :: IO String
foldedTree = do
  caseDir <- lookupEnv "LOCKSTEP_TEST_CASE_DIR"
  withSystemTempDirectory "lockstep-p4r2-folded" $ \tmp -> do
    let
      repo = tmp <> "/repo"
      base = fromMaybe tmp caseDir
    createDirectoryIfMissing True base
    createDirectory repo
    _ <- gitIn repo ["init", "-q"]
    createDirectoryIfMissing True (repo <> "/Docs")
    createDirectoryIfMissing True (repo <> "/docs")
    writeFile (repo <> "/Docs/a.txt") "a\n"
    writeFile (repo <> "/docs/b.txt") "b\n"
    _ <- gitIn repo ["add", "-A"]
    _ <- gitIn repo ["commit", "-q", "-m", "two directories"]
    commit <- T.strip . T.pack <$> gitIn repo ["rev-parse", "HEAD"]
    withTempDirectory base "lockstep-p4r2-dest" $ \dest -> do
      writeFile (dest <> "/Probe") "x"
      insensitive <- doesFileExist (dest <> "/probe")
      removeFile (dest <> "/Probe")
      written <- writeSnapshot repo commit dest
      if insensitive
        then do
          fmap L.length written @?= Left "tree-path-collision"
          left <- listDirectory dest
          left @?= []
          pure "case-insensitive: refused tree-path-collision, nothing written"
        else do
          fmap L.length written @?= Right 2
          pure "case-sensitive: both directories written"

bytesFilter :: Assertion
bytesFilter =
  withSystemTempDirectory "lockstep-p4r2-filter" $ \tmp -> do
    let
      repo = tmp <> "/repo"
      marker = tmp <> "/filter-ran"
    createDirectory repo
    _ <- gitIn repo ["init", "-q"]
    writeFile (repo <> "/a.txt") "plain\n"
    _ <- gitIn repo ["add", "-A"]
    _ <- gitIn repo ["commit", "-q", "-m", "a"]
    -- A driver named "caf" and the byte 0xE9 (Latin-1, not UTF-8), named by the attributes too.
    BS.appendFile (repo <> "/.git/config") ("[filter \"caf\xE9\"]\n\tclean = touch " <> TE.encodeUtf8 (T.pack marker) <> "; cat\n")
    BS.writeFile (repo <> "/.git/info/attributes") "*.txt filter=caf\xE9\n"
    later <- addUTCTime 30 <$> getCurrentTime
    setModificationTime (repo <> "/a.txt") later
    observed <- observeBasis repo
    ran <- doesFileExist marker
    assertBool "the repository's filter was run by Lockstep" (not ran)
    fmap basisCommit observed @?= Left "repository-filter-unsupported"

longSegment :: Assertion
longSegment =
  withScenario $ \sc -> do
    view <- startedBug sc "long"
    let
      long = T.replicate 297 "t" <> ".py"
    engine <- directEngine sc [discovery, candidateAt long, candidateAt "test_calc.py"]
    reports <- traverse (const (accepted (ready (advance (scRuntime sc) engine (viewId view))))) [1 .. 4 :: Int]
    fmap inputOf (L.drop 3 reports) @?= ["candidate-rejected"]
    case L.reverse reports of
      r : _ -> assertBool "rejected as unsupported" (L.any (\b -> "\"code\":\"test-path-unsupported\"" `T.isInfixOf` b) [recordBody x | x <- viewRecords (viewAfter r), recordKind x == "candidate-rejected"])
      [] -> assertFailure "no step"
