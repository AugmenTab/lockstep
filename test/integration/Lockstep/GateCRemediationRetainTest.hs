{-# LANGUAGE OverloadedStrings #-}

{- | The C-C.R1 fourth addendum against real PostgreSQL and Git (§3e: Review 6):
a folder published at a user-visible path is never removed by a connection
attempt that does not end connected, whatever replaced it or registered it
meanwhile; and the identity checked before a registration is the identity of
the observation actually registered, the @origin@ fallback included. The
test-only hook runs where the other request acts.
-}
module Lockstep.GateCRemediationRetainTest
  ( tests
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, throwIO, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory, doesDirectoryExist, renameDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, readFile, writeFile)
import System.IO.Error (userError)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, runMigrations)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), connectProject, connectProjectAround, createProject, findProject, noProjectFaults, offeredFolders)
import Lockstep.Application.Repositories (RegisterRequest (..), RepositoryRecord (..), addEngineer, registerRepository)
import Lockstep.Foundation.SystemConfig (DatabaseConfig)
import Lockstep.Kernel.Project (FolderChoice (..), SetupState (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scConfig :: DatabaseConfig
  , scRuntime :: DatabaseRuntime
  , scRoot :: FilePath
  , scDir :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-cr1-retain" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/w")
        action (Scenario admin db config runtime (tmp <> "/projects") (tmp <> "/w"))

rootFolders :: Scenario -> ProjectFolders
rootFolders sc =
  ProjectFolders (Just (scRoot sc)) []

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("creation key " <> T.unpack text))) pure (mkIdempotencyKey ("test-retain-creation-" <> text))

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

made :: Scenario -> T.Text -> T.Text -> IO ProjectView
made sc k name = do
  ik <- key k
  ready (createProject (scRuntime sc) (rootFolders sc) (NewProject ik name "" DecideLater)) >>= either (\c -> assertFailure ("project refused: " <> T.unpack c)) pure

recorded :: Scenario -> ProjectView -> IO (Maybe (SetupState, Maybe T.Text, Maybe T.Text))
recorded sc view =
  fmap (\v -> (projectSetup v, projectFolder v, projectRefusal v)) <$> ready (findProject (scRuntime sc) (projectId view))

repositories :: Scenario -> IO [Int]
repositories sc =
  queryInts (scAdmin sc) (scDb sc) "SELECT count(*)::integer AS v FROM lockstep_repositories"

execute :: Scenario -> String -> IO ()
execute sc =
  adminExecute (scAdmin sc) (T.unpack (scDb sc))

gitOut :: FilePath -> [String] -> IO String
gitOut dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Lockstep Test", "-c", "user.email=test@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  result <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case result of
    Just (ExitSuccess, out, _) -> pure out
    other -> assertFailure ("git " <> show args <> ": " <> show other)

git :: FilePath -> [String] -> IO ()
git dir args =
  void (gitOut dir args)

-- | Someone else's repository at @dir/name@: one file, one commit, and the given remotes.
theirRepo :: FilePath -> String -> [(String, String)] -> IO FilePath
theirRepo dir name remotes = do
  git dir ["init", "-q", name]
  let
    path = dir <> "/" <> name
  writeFile (path <> "/notes.txt") "theirs"
  git path ["add", "notes.txt"]
  git path ["commit", "-q", "-m", "their work"]
  traverse_ (\(r, url) -> git path ["remote", "add", r, url]) remotes
  pure path

-- | The replacement is there as it was made: its file, its commit and its remotes.
intact :: FilePath -> [String] -> IO ()
intact path remotes = do
  readFile (path <> "/notes.txt") >>= (@?= "theirs")
  gitOut path ["log", "--format=%s"] >>= (@?= "their work\n")
  gitOut path ["remote"] >>= (@?= L.unlines (L.sort remotes))

type Outcome = Either NotReadyReason (Either T.Text ProjectView)

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

notConnected :: Outcome -> IO ()
notConnected outcome =
  assertBool ("the attempt connected: " <> show (fmap (fmap projectFolder) outcome)) (fmap (fmap projectSetup) outcome /= Right (Right Connected))

tests :: TestTree
tests =
  testGroup
    "Gate C remediation fourth addendum (C-C.R1 §3e; real PostgreSQL)"
    [ testCase "Review 6 #1: a made folder replaced by someone else's repository while the attempt waits is kept intact" $
        withScenario $ \sc -> do
          a <- made sc "a" "Garden"
          let
            replace path = do
              renameDirectory path (scDir sc <> "/moved-away")
              _ <- theirRepo (scRoot sc) "garden" []
              pure ()
          ra <- connectProjectAround replace noProjectFaults (scRuntime sc) (rootFolders sc) (projectId a) 1 NewFolder
          notConnected ra
          recorded sc a >>= (@?= Just (SetupFailed, Nothing, Just "folder-not-offered"))
          repositories sc >>= (@?= [0])
          intact (scRoot sc <> "/garden") []
    , testCase "Review 6 #1: a failed attempt keeps the folder it published; it is not connected, and it can be chosen as an existing folder" $
        withScenario $ \sc -> do
          a <- made sc "a" "Garden"
          execute sc "CREATE FUNCTION retain_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected failure'; END $$"
          execute sc "CREATE TRIGGER retain_fail BEFORE UPDATE ON lockstep_projects FOR EACH ROW EXECUTE FUNCTION retain_fail()"
          ra <- connectProject (scRuntime sc) (rootFolders sc) (projectId a) 1 NewFolder
          assertBool ("not a failure: " <> show (fmap (fmap projectId) ra)) (either (const True) (const False) ra)
          let
            folder = scRoot sc <> "/garden"
          recorded sc a >>= (@?= Just (Organized, Nothing, Nothing))
          repositories sc >>= (@?= [0])
          doesDirectoryExist (folder <> "/.git") >>= assertBool "the published folder was removed"
          execute sc "DROP TRIGGER retain_fail ON lockstep_projects"
          offeredFolders (scRuntime sc) (rootFolders sc) >>= (@?= [folder])
          again <- connectProject (scRuntime sc) (rootFolders sc) (projectId a) 1 (ExistingFolder (T.pack folder))
          fmap (fmap (\v -> (projectSetup v, projectFolder v))) again @?= Right (Right (Connected, Just (T.pack folder)))
    , testCase "Review 6 #1: an attempt interrupted after publishing keeps the folder" $
        withScenario $ \sc -> do
          a <- made sc "a" "Garden"
          result <- try (connectProjectAround (\_ -> throwIO (userError "injected: interrupted after publication")) noProjectFaults (scRuntime sc) (rootFolders sc) (projectId a) 1 NewFolder) :: IO (Either SomeException Outcome)
          assertBool ("the interrupted attempt connected: " <> show (fmap (fmap (fmap projectId)) result)) (either (const True) (either (const True) (const False)) result)
          recorded sc a >>= (@?= Just (Organized, Nothing, Nothing))
          doesDirectoryExist (scRoot sc <> "/garden/.git") >>= assertBool "the published folder was removed"
    , testCase "Review 6 #2: a two-remote folder replaced while waiting is not connected from its stale origin observation" $
        withScenario $ \sc -> do
          b <- made sc "b" "Site"
          let
            remotes owner = [("origin", "git@github.com:" <> owner <> "/Site.git"), ("upstream", "git@github.com:Upstream-" <> owner <> "/Site.git")]
          site <- theirRepo (scRoot sc) "site" (remotes "Owner")
          let
            replace path = do
              renameDirectory path (scDir sc <> "/old-site")
              _ <- theirRepo (scRoot sc) "site" (remotes "Someone")
              pure ()
          rb <- connectProjectAround replace noProjectFaults (scRuntime sc) (rootFolders sc) (projectId b) 1 (ExistingFolder (T.pack site))
          notConnected rb
          recorded sc b >>= (@?= Just (SetupFailed, Nothing, Just "folder-not-offered"))
          repositories sc >>= (@?= [0])
          intact site ["origin", "upstream"]
    , testCase "Review 6 #3: a command-line registration of the made folder, uncommitted while the attempt fails, keeps the folder and its registration" $
        withScenario $ \sc -> withRuntime (scConfig sc) $ \cli -> do
          a <- made sc "a" "Garden"
          _ <- ready (addEngineer cli "cli-engineer") >>= either (const (assertFailure "the command-line Engineer was refused")) pure
          -- The registration holds its lock, its row not yet committed, for 3 s; the attempt fails at its Engineer meanwhile.
          execute sc "CREATE FUNCTION retain_slow() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(3); RETURN NEW; END $$"
          execute sc "CREATE TRIGGER retain_slow AFTER INSERT ON lockstep_repositories FOR EACH ROW EXECUTE FUNCTION retain_slow()"
          execute sc "CREATE FUNCTION retain_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected failure'; END $$"
          execute sc "CREATE TRIGGER retain_fail BEFORE INSERT ON lockstep_engineers FOR EACH ROW EXECUTE FUNCTION retain_fail()"
          registration <- newEmptyMVar
          let
            register path = do
              box <- background (registerRepository cli (RegisterRequest "cli-engineer" path Nothing))
              putMVar registration box
              threadDelay 1000000
          ra <- connectProjectAround register noProjectFaults (scRuntime sc) (rootFolders sc) (projectId a) 1 NewFolder
          notConnected ra
          box <- takeMVar registration
          registered <- await "the command-line registration" box
          case registered of
            Right (Right record) -> repositoryRecordOwner record @?= "cli-engineer"
            Right (Left _) -> assertFailure "the command-line registration was refused"
            Left reason -> assertFailure ("the command-line registration failed: " <> show reason)
          let
            folder = scRoot sc <> "/garden"
          doesDirectoryExist (folder <> "/.git") >>= assertBool "the registered folder was removed"
          repositories sc >>= (@?= [1])
          recorded sc a >>= (@?= Just (Organized, Nothing, Nothing))
    ]
