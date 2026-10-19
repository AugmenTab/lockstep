{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.1 integration: real Git fixtures, real PostgreSQL and the real
binary. Every Git fixture lives in a fresh temporary directory; HOME and the
Git configuration are under the test's control, so the operator's own
configuration cannot change the result.
-}
module Lockstep.RepositoryOwnershipTest
  ( tests
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory, withTempDirectory)
import System.Posix.Files (createSymbolicLink)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, testCaseInfo, (@?=))
import Text.Show (show)

import Lockstep.Application.Database (runMigrations)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres
  ( AdminSettings (..)
  , databaseConfigFor
  , queryBool
  , queryInts
  , requireAdmin
  , withFreshDatabase
  , withRuntime
  , writeConfigFile
  )
import Lockstep.Support.Process (runLockstep)

tests :: TestTree
tests =
  testGroup
    "repository identity and ownership (C-P2.1; real Git + PostgreSQL + binary)"
    [ testCase "engineers: add, duplicate name, invalid name; one decision per attempt" $
        withScenario $ \sc -> do
          (c1, out1, err1) <- lockstep sc ["engineer", "add", "alice"]
          c1 @?= ExitSuccess
          err1 @?= ""
          case L.words out1 of
            ["engineer", uuid, "alice"] -> L.length uuid @?= 36
            _ -> assertFailure ("unexpected output: " <> out1)
          refusedCli sc ["engineer", "add", "alice"] "engineer-name-taken"
          refusedCli sc ["engineer", "add", "Alice"] "engineer-name-invalid"
          count sc "lockstep_engineers" >>= (@?= 1)
          decisions sc >>= (@?= 3)
    , testCase "aliases, linked worktrees, subdirectories and unsupported shapes fail closed" $
        withScenario $ \sc -> do
          engineers sc ["alice", "bob"]
          orig <- origRepo sc
          (uuid, authoritative, commonDir) <- registered sc ["--engineer", "alice", orig]
          authoritative @?= "origin=github.com/owner/repo"
          assertBool ("common dir: " <> commonDir) ("/orig/.git" `L.isSuffixOf` commonDir)
          (cl, outl, _) <- lockstep sc ["repository", "list"]
          cl @?= ExitSuccess
          L.lines outl @?= ["repository " <> uuid <> " owner alice authoritative origin=github.com/owner/repo common-dir " <> commonDir]
          refused sc ["--engineer", "alice", orig] "repository-already-owned"
          refused sc ["--engineer", "bob", orig] "repository-already-owned"
          createSymbolicLink orig (scDir sc <> "/link")
          refused sc ["--engineer", "bob", scDir sc <> "/link"] "repository-already-owned"
          refused sc ["--engineer", "bob", orig <> "/"] "repository-already-owned"
          createDirectory (orig <> "/sub")
          refused sc ["--engineer", "bob", orig <> "/sub/.."] "repository-already-owned"
          git sc orig ["worktree", "add", "-q", "../wt", "-b", "feature"]
          refused sc ["--engineer", "bob", scDir sc <> "/wt"] "linked-worktree"
          refused sc ["--engineer", "bob", orig <> "/sub"] "not-top-level"
          refused sc ["--engineer", "bob", orig <> "/.git"] "not-top-level"
          git sc (scDir sc) ["init", "-q", "--bare", "bare.git"]
          refused sc ["--engineer", "bob", scDir sc <> "/bare.git"] "bare-repository"
          git sc (scDir sc) ["clone", "-q", "--depth", "1", "file://" <> orig, "shallow"]
          refused sc ["--engineer", "bob", scDir sc <> "/shallow"] "shallow-repository"
          parent <- newRepo sc "parent"
          git sc parent ["-c", "protocol.file.allow=always", "submodule", "add", "-q", orig, "sub"]
          refused sc ["--engineer", "bob", parent <> "/sub"] "submodule"
          createDirectory (scDir sc <> "/plain")
          refused sc ["--engineer", "bob", scDir sc <> "/plain"] "not-a-git-repository"
          refused sc ["--engineer", "bob", scDir sc <> "/missing"] "path-not-found"
          writeFile (scDir sc <> "/file") "x"
          refused sc ["--engineer", "bob", scDir sc <> "/file"] "not-a-directory"
          other <- newRepo sc "other"
          refused sc ["--engineer", "alice", other] "engineer-already-owns-repository"
          refused sc ["--engineer", "zed", other] "unknown-engineer"
          count sc "lockstep_repositories" >>= (@?= 1)
          -- 2 engineer adds + 1 accepted + 16 refused registrations
          decisions sc >>= (@?= 19)
          consistentDecisions sc
    , testCase "duplicate clones are refused; forks, shared ancestry and templates stay eligible" $
        withScenario $ \sc -> do
          engineers sc ["alice", "bob", "carol", "dave", "erin"]
          orig <- origRepo sc
          _ <- registered sc ["--engineer", "alice", orig]
          clone1 <- cloneOf sc orig "clone1"
          refused sc ["--engineer", "bob", clone1] "remote-is-owned-repository"
          clone2 <- cloneOf sc orig "clone2"
          git sc clone2 ["remote", "set-url", "origin", "https://github.com/owner/repo"]
          refused sc ["--engineer", "bob", clone2] "authoritative-remote-owned"
          writeFile (scHome sc <> "/.gitconfig") "[url \"https://github.com/\"]\n\tinsteadOf = gh:\n"
          clone3 <- cloneOf sc orig "clone3"
          git sc clone3 ["remote", "set-url", "origin", "gh:Owner/Repo"]
          refused sc ["--engineer", "bob", clone3] "authoritative-remote-owned"
          fork <- cloneOf sc orig "fork"
          git sc fork ["remote", "set-url", "origin", "git@github.com:bob/repo-fork.git"]
          git sc fork ["remote", "add", "upstream", "git@github.com:Owner/Repo.git"]
          refused sc ["--engineer", "bob", fork] "authoritative-remote-ambiguous"
          (_, forkRemote, _) <- registered sc ["--engineer", "bob", "--authoritative-remote", "origin", fork]
          forkRemote @?= "origin=github.com/bob/repo-fork"
          shared <- cloneOf sc orig "shared"
          git sc shared ["remote", "remove", "origin"]
          (_, sharedRemote, _) <- registered sc ["--engineer", "carol", shared]
          sharedRemote @?= "none"
          template <- cloneOf sc orig "app"
          git sc template ["remote", "rename", "origin", "template"]
          git sc template ["remote", "set-url", "template", "git@github.com:Owner/Repo.git"]
          git sc template ["remote", "add", "origin", "git@github.com:dave/app.git"]
          (_, templateRemote, _) <- registered sc ["--engineer", "dave", "--authoritative-remote=origin", template]
          templateRemote @?= "origin=github.com/dave/app"
          inconsistent <- cloneOf sc orig "inconsistent"
          git sc inconsistent ["remote", "set-url", "origin", "git@github.com:erin/x.git"]
          git sc inconsistent ["remote", "set-url", "--push", "origin", "git@github.com:erin/y.git"]
          refused sc ["--engineer", "erin", inconsistent] "authoritative-remote-inconsistent"
          refused sc ["--engineer", "erin", "--authoritative-remote", "nope", inconsistent] "authoritative-remote-unknown"
          helper <- newRepo sc "helper"
          git sc helper ["remote", "add", "origin", "ext::sh -c x"]
          refused sc ["--engineer", "erin", helper] "remote-url-unsupported"
          dangling <- newRepo sc "dangling"
          git sc dangling ["remote", "add", "origin", scDir sc <> "/no-such-repository"]
          refused sc ["--engineer", "erin", dangling] "remote-unresolvable"
          (cl, outl, _) <- lockstep sc ["repository", "list"]
          cl @?= ExitSuccess
          L.length (L.lines outl) @?= 4
          count sc "lockstep_repositories" >>= (@?= 4)
          consistentDecisions sc
    , testCaseInfo "case sensitivity: the system temporary directory and LOCKSTEP_TEST_CASE_DIR" $ do
        caseDir <- lookupEnv "LOCKSTEP_TEST_CASE_DIR"
        base <-
          maybe
            (assertFailure "precondition missing: LOCKSTEP_TEST_CASE_DIR is not set (NOT_RUN)")
            pure
            caseDir
        createDirectoryIfMissing True base
        systemTemp <- withScenario caseScenario
        caseTemp <- withScenarioIn base caseScenario
        pure ("system temporary directory: " <> systemTemp <> "; LOCKSTEP_TEST_CASE_DIR: " <> caseTemp)
    , testCase "concurrent alias registrations leave exactly one owner (5 rounds)" $
        withScenario $ \sc -> do
          engineers sc ["e0", "e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8", "e9"]
          traverse_
            ( \n -> do
                repo <- newRepo sc ("race" <> show n)
                createSymbolicLink repo (repo <> "-link")
                done <- newEmptyMVar
                _ <- forkIO (lockstep sc ["repository", "register", "--engineer", "e" <> show (2 * n), repo] >>= putMVar done)
                (c2, _, _) <- lockstep sc ["repository", "register", "--engineer", "e" <> show (2 * n + 1), repo <> "-link"]
                (c1, _, _) <- takeMVar done
                L.sort [c1, c2] @?= [ExitSuccess, ExitFailure 65]
            )
            [0 :: Int .. 4]
          count sc "lockstep_repositories" >>= (@?= 5)
          refusedCount sc "repository-already-owned" >>= (@?= 5)
          consistentDecisions sc
    , testCase "db migrate from revision 5 needs a backup decision for migration 0006" $ do
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-config" $ \dir -> do
            config <- databaseConfigFor admin db
            first <- withRuntime config (runMigrations (L.take 5 migrations))
            fmap L.length first @?= Right 5
            path <- writeConfigFile dir admin db (adminPassword admin)
            let
              env = [("LOCKSTEP_CONFIG", path)]
            (code, _, _) <- runLockstep env ["db", "migrate"]
            code @?= ExitFailure 75
            (code2, out2, _) <- runLockstep env ["db", "migrate", "--no-backup"]
            code2 @?= ExitSuccess
            assertBool ("unexpected: " <> out2) ("applied migrations: 6" `L.isInfixOf` out2)
    ]

-- | One case-behaviour scenario in a fresh scenario directory; returns what it found.
caseScenario :: Scenario -> IO String
caseScenario sc = do
  createDirectory (scDir sc <> "/probe-case")
  insensitive <- doesDirectoryExist (scDir sc <> "/PROBE-CASE")
  engineers sc ["e1", "e2", "e3"]
  orig <- newRepo sc "orig"
  _ <- registered sc ["--engineer", "e1", orig]
  if insensitive
    then do
      refused sc ["--engineer", "e2", scDir sc <> "/ORIG"] "repository-already-owned"
      count sc "lockstep_repositories" >>= (@?= 1)
      pure "case-insensitive (ORIG refused as an alias of orig)"
    else do
      refused sc ["--engineer", "e2", scDir sc <> "/ORIG"] "path-not-found"
      upper <- newRepo sc "Proj"
      lower <- newRepo sc "proj"
      (idUpper, _, _) <- registered sc ["--engineer", "e2", upper]
      (idLower, _, _) <- registered sc ["--engineer", "e3", lower]
      assertBool "Proj and proj got the same RepositoryId" (idUpper /= idLower)
      count sc "lockstep_repositories" >>= (@?= 3)
      pure "case-sensitive (Proj and proj are distinct repositories)"

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scDir :: FilePath
  , scHome :: FilePath
  , scEnv :: [(String, String)]
  }

-- | A migrated database and an empty fixture directory under the system temporary directory.
withScenario :: (Scenario -> IO a) -> IO a
withScenario action =
  withSystemTempDirectory "lockstep-p21" $ \tmp -> scenarioAt tmp action

withScenarioIn :: FilePath -> (Scenario -> IO a) -> IO a
withScenarioIn base action =
  withTempDirectory base "lockstep-p21" $ \tmp -> scenarioAt tmp action

scenarioAt :: FilePath -> (Scenario -> IO a) -> IO a
scenarioAt tmp action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db -> do
    createDirectory (tmp <> "/home")
    createDirectory (tmp <> "/config")
    createDirectory (tmp <> "/w")
    path <- writeConfigFile (tmp <> "/config") admin db (adminPassword admin)
    let
      home = tmp <> "/home"
      env =
        [ ("LOCKSTEP_CONFIG", path)
        , ("HOME", home)
        , ("XDG_CONFIG_HOME", home <> "/.config")
        , ("GIT_CONFIG_NOSYSTEM", "1")
        , ("GIT_CONFIG_COUNT", "1")
        , ("GIT_CONFIG_KEY_0", "safe.directory")
        , ("GIT_CONFIG_VALUE_0", "*")
        ]
      sc = Scenario admin db (tmp <> "/w") home env
    (code, _, err) <- runLockstep env ["db", "migrate"]
    assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
    action sc

lockstep :: Scenario -> [String] -> IO (ExitCode, String, String)
lockstep sc =
  runLockstep (scEnv sc)

engineers :: Scenario -> [String] -> Assertion
engineers sc =
  traverse_
    ( \name -> do
        (code, _, err) <- lockstep sc ["engineer", "add", name]
        assertBool ("engineer add " <> name <> ": " <> err) (code == ExitSuccess)
    )

-- | Runs git in a directory with the scenario's environment; any failure fails the test.
git :: Scenario -> FilePath -> [String] -> Assertion
git sc dir args = do
  let
    identity = ["-c", "user.name=Lockstep Test", "-c", "user.email=test@example.invalid", "-c", "init.defaultBranch=main"]
  base <- getEnvironment
  let
    env = scEnv sc <> L.filter (\(k, _) -> k `L.notElem` fmap fst (scEnv sc)) base
  result <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case result of
    Nothing -> assertFailure ("git " <> show args <> " did not finish within 30 s")
    Just (ExitSuccess, _, _) -> pure ()
    Just (code, out, err) -> assertFailure ("git " <> show args <> " failed: " <> show code <> " " <> out <> err)

-- | A new repository with two commits.
newRepo :: Scenario -> String -> IO FilePath
newRepo sc name = do
  let
    path = scDir sc <> "/" <> name
  git sc (scDir sc) ["init", "-q", name]
  git sc path ["commit", "-q", "--allow-empty", "-m", "first"]
  git sc path ["commit", "-q", "--allow-empty", "-m", "second"]
  pure path

-- | The owned repository: origin is git@github.com:Owner/Repo.git.
origRepo :: Scenario -> IO FilePath
origRepo sc = do
  orig <- newRepo sc "orig"
  git sc orig ["remote", "add", "origin", "git@github.com:Owner/Repo.git"]
  pure orig

-- | A full clone of a local repository; its origin is the source's path.
cloneOf :: Scenario -> FilePath -> String -> IO FilePath
cloneOf sc source name = do
  git sc (scDir sc) ["clone", "-q", source, name]
  pure (scDir sc <> "/" <> name)

{- | An accepted registration: returns the RepositoryId, the authoritative field
and the common directory from @repository <uuid> owner <e> authoritative <a> common-dir <path>@.
-}
registered :: Scenario -> [String] -> IO (String, String, String)
registered sc args = do
  (code, out, err) <- lockstep sc ("repository" : "register" : args)
  assertBool ("register " <> show args <> " was refused: " <> out <> err) (code == ExitSuccess)
  err @?= ""
  case L.lines out of
    [line]
      | "repository" : uuid : "owner" : _ : "authoritative" : authoritative : "common-dir" : _ <- L.words line
      , Just commonDir <- afterMarker " common-dir " line -> do
          L.length uuid @?= 36
          pure (uuid, authoritative, commonDir)
    _ -> assertFailure ("unexpected register output: " <> out)

afterMarker :: String -> String -> Maybe String
afterMarker marker text =
  case L.stripPrefix marker text of
    Just rest -> Just rest
    Nothing ->
      case text of
        [] -> Nothing
        _ : rest -> afterMarker marker rest

-- | A refused registration with the given code; nothing new owned.
refused :: Scenario -> [String] -> String -> Assertion
refused sc args =
  refusedCli sc ("repository" : "register" : args)

refusedCli :: Scenario -> [String] -> String -> Assertion
refusedCli sc args code = do
  before <- count sc "lockstep_repositories"
  (exit, out, err) <- lockstep sc args
  exit @?= ExitFailure 65
  case L.words out of
    ["refused", printed, "decision", n] | L.all (`L.elem` ['0' .. '9']) n -> printed @?= code
    _ -> assertFailure (show args <> ": unexpected stdout: " <> out <> " stderr: " <> err)
  assertBool (show args <> ": stderr lacks the code: " <> err) (("refused (" <> code <> ")") `L.isInfixOf` err)
  after <- count sc "lockstep_repositories"
  after @?= before

count :: Scenario -> String -> IO Int
count sc table = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> table)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> table)

decisions :: Scenario -> IO Int
decisions sc =
  count sc "lockstep_identity_decisions"

refusedCount :: Scenario -> String -> IO Int
refusedCount sc code =
  count sc ("lockstep_identity_decisions WHERE outcome = 'refused' AND refusal_code = '" <> code <> "'")

-- | Every repository has an accepted decision; every accepted registration names an existing repository.
consistentDecisions :: Scenario -> Assertion
consistentDecisions sc = do
  orphanRepos <-
    queryBool
      (scAdmin sc)
      (scDb sc)
      "SELECT EXISTS (SELECT 1 FROM lockstep_repositories r WHERE NOT EXISTS (SELECT 1 FROM lockstep_identity_decisions d WHERE d.repository_id = r.id AND d.outcome = 'accepted')) AS v"
  assertBool "a repository row has no accepted decision" (not orphanRepos)
  orphanDecisions <-
    queryBool
      (scAdmin sc)
      (scDb sc)
      "SELECT EXISTS (SELECT 1 FROM lockstep_identity_decisions d WHERE d.operation = 'repository-register' AND d.outcome = 'accepted' AND NOT EXISTS (SELECT 1 FROM lockstep_repositories r WHERE r.id = d.repository_id)) AS v"
  assertBool "an accepted registration names no repository" (not orphanDecisions)
