{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.3 integration: the Profile registry, the repository default Profile
and dry-run resolution through the real binary and real PostgreSQL.
-}
module Lockstep.ProfileRegistryTest
  ( tests
  ) where

import Control.Exception (SomeException, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Support.Postgres
  ( AdminSettings (..)
  , adminExecute
  , queryInts
  , requireAdmin
  , withFreshDatabase
  , writeConfigFile
  )
import Lockstep.Support.Process (runLockstep)

tests :: TestTree
tests =
  testGroup
    "Profile registry and resolution (C-P2.3; real PostgreSQL + binary)"
    [ testCase "add, unchanged, version rules, invalid and weakening documents, list and show" $
        withScenario $ \sc -> do
          team1 <- document sc "team1.json" (teamDocument 1 "supervisor")
          (c1, out1, err1) <- lockstep sc ["profile", "add", team1]
          c1 @?= ExitSuccess
          err1 @?= ""
          digest1 <-
            case L.words out1 of
              ["profile", "team", "version", "1", "digest", d, "added"] -> pure d
              _ -> assertFailure ("unexpected add output: " <> out1)
          L.length digest1 @?= 64
          (c2, out2, _) <- lockstep sc ["profile", "add", team1]
          c2 @?= ExitSuccess
          L.words out2 @?= ["profile", "team", "version", "1", "digest", digest1, "unchanged"]
          other1 <- document sc "other1.json" (teamDocument 1 "human")
          refused sc ["profile", "add", other1] "profile-version-exists"
          team3 <- document sc "team3.json" (teamDocument 3 "human")
          refused sc ["profile", "add", team3] "profile-version-not-next"
          junk <- document sc "junk.json" "{\"id\":\"team\",\"version\":2,\"gates\":[],\"colour\":\"red\"}"
          refused sc ["profile", "add", junk] "profile-document-invalid"
          notJson <- document sc "bad.json" "not json"
          refused sc ["profile", "add", notJson] "profile-document-invalid"
          weakening <- document sc "weak.json" "{\"id\":\"lax\",\"version\":1,\"gates\":[],\"invariant_exceptions\":[\"independent-review\"]}"
          refused sc ["profile", "add", weakening] "weakens-universal-invariant"
          unsatisfiable <-
            document sc "unsat.json" "{\"id\":\"lax\",\"version\":1,\"gates\":[{\"id\":\"v\",\"stage\":\"before-execution\",\"artifacts\":[\"verification-record\"],\"verifiers\":[\"deterministic-command\"],\"approval\":\"none\"}]}"
          refused sc ["profile", "add", unsatisfiable] "gate-unsatisfiable-before-execution"
          team2 <- document sc "team2.json" (teamDocument 2 "human")
          (c3, out3, _) <- lockstep sc ["profile", "add", team2]
          c3 @?= ExitSuccess
          digest2 <-
            case L.words out3 of
              ["profile", "team", "version", "2", "digest", d, "added"] -> pure d
              _ -> assertFailure ("unexpected add output: " <> out3)
          (cl, outl, _) <- lockstep sc ["profile", "list"]
          cl @?= ExitSuccess
          L.lines outl @?= ["profile team version 1 digest " <> digest1, "profile team version 2 digest " <> digest2]
          (cs, outs, _) <- lockstep sc ["profile", "show", "team"]
          cs @?= ExitSuccess
          shownDigest outs @?= Just digest2
          assertBool ("show lacks the version: " <> outs) ("version 2" `L.elem` L.lines outs)
          renderingDigest outs @?= Just digest2
          (cs1, outs1, _) <- lockstep sc ["profile", "show", "team", "--version", "1"]
          cs1 @?= ExitSuccess
          shownDigest outs1 @?= Just digest1
          renderingDigest outs1 @?= Just digest1
          refused sc ["profile", "show", "nope"] "profile-unknown"
          refused sc ["profile", "show", "team", "--version", "9"] "profile-unknown"
          count sc "lockstep_profiles" >>= (@?= 2)
          -- 9 add attempts reached the database (list and show are reads)
          count sc "lockstep_profile_decisions" >>= (@?= 9)
          count sc "lockstep_profile_decisions WHERE outcome = 'refused'" >>= (@?= 6)
    , testCase "stored profiles and default assignments cannot be changed or deleted" $
        withScenario $ \sc -> do
          team1 <- document sc "team1.json" (teamDocument 1 "supervisor")
          added sc team1
          engineerWithRepository sc "alice"
          (c, _, err) <- lockstep sc ["repository", "set-profile", "--engineer", "alice", "team"]
          assertBool err (c == ExitSuccess)
          sqlFails sc "UPDATE lockstep_profiles SET digest = repeat('0', 64)"
          sqlFails sc "DELETE FROM lockstep_profiles"
          sqlFails sc "UPDATE lockstep_repository_profiles SET profile_id = 'other'"
          sqlFails sc "DELETE FROM lockstep_repository_profiles"
          count sc "lockstep_profiles" >>= (@?= 1)
          count sc "lockstep_repository_profiles" >>= (@?= 1)
    , testCase "repository set-profile records the default and refuses the unknown" $
        withScenario $ \sc -> do
          team1 <- document sc "team1.json" (teamDocument 1 "supervisor")
          added sc team1
          engineerWithRepository sc "alice"
          (c0, _, _) <- lockstep sc ["engineer", "add", "bob"]
          c0 @?= ExitSuccess
          (c, out, err) <- lockstep sc ["repository", "set-profile", "--engineer", "alice", "team"]
          c @?= ExitSuccess
          err @?= ""
          case L.words out of
            ["repository", uuid, "default-profile", "team"] -> L.length uuid @?= 36
            _ -> assertFailure ("unexpected set-profile output: " <> out)
          refused sc ["repository", "set-profile", "--engineer", "zed", "team"] "unknown-engineer"
          refused sc ["repository", "set-profile", "--engineer", "bob", "team"] "engineer-has-no-repository"
          refused sc ["repository", "set-profile", "--engineer", "alice", "nope"] "profile-unknown"
          count sc "lockstep_repository_profiles" >>= (@?= 1)
          -- 1 add + 1 accepted + 3 refused set-profile attempts
          count sc "lockstep_profile_decisions" >>= (@?= 5)
    , testCase "resolution: unset default, specialization, weakening, new version, invalid facts" $
        withScenario $ \sc -> do
          engineerWithRepository sc "alice"
          refused sc ["profile", "resolve", "--engineer", "alice", "--kind", "engineering"] "repository-default-profile-unset"
          team1 <- document sc "team1.json" (teamDocument 1 "supervisor")
          added sc team1
          eng <- document sc "eng.json" (specDocument "eng" 1 "human")
          added sc eng
          setProfile sc "alice" "team"
          (c1, out1, err1) <- lockstep sc ["profile", "resolve", "--engineer", "alice", "--kind", "engineering"]
          assertBool ("resolve failed: " <> out1 <> err1) (c1 == ExitSuccess)
          let
            lines1 = L.lines out1
          assertBool out1 (L.any ("source repository-default team 1 " `L.isPrefixOf`) lines1)
          assertBool out1 (L.any ("source specialization eng 1 " `L.isPrefixOf`) lines1)
          assertBool out1 ("gate impact stage=before-execution artifacts=impact-assessment kinds=* classes=* path-classes=* verifiers=human-inspection approval=human exception-path=false" `L.elem` lines1)
          assertBool out1 ("facts kind=engineering classes=- path-classes=- behaviour=behaviour-changing" `L.elem` lines1)
          renderingDigest out1 @?= shownDigest out1
          (c2, out2, _) <- lockstep sc ["profile", "resolve", "--engineer", "alice", "--kind", "investigate"]
          c2 @?= ExitSuccess
          assertBool out2 (not (L.any ("source specialization" `L.isPrefixOf`) (L.lines out2)))
          weak <- document sc "eng2.json" (specDocument "eng" 2 "none")
          added sc weak
          refused sc ["profile", "resolve", "--engineer", "alice", "--kind", "engineering"] "weakens-gate"
          team2 <- document sc "team2.json" (teamDocument 2 "supervisor")
          added sc team2
          (c3, out3, _) <- lockstep sc ["profile", "resolve", "--engineer", "alice", "--kind", "investigate"]
          c3 @?= ExitSuccess
          assertBool out3 (L.any ("source repository-default team 2 " `L.isPrefixOf`) (L.lines out3))
          refused sc ["profile", "resolve", "--engineer", "alice", "--kind", "deploy"] "invalid-facts"
          refused sc ["profile", "resolve", "--engineer", "alice", "--kind", "plan", "--path-class", "binaries"] "invalid-facts"
          refused sc ["profile", "resolve", "--engineer", "alice", "--kind", "plan", "--class", "Not A Tag"] "invalid-facts"
          refused sc ["profile", "resolve", "--engineer", "alice", "--kind", "plan", "--non-behavioural", "typo", "--path-class", "source"] "non-behavioural-refused"
          (c4, out4, _) <- lockstep sc ["profile", "resolve", "--engineer", "alice", "--kind", "plan", "--non-behavioural", "typo", "--path-class", "docs"]
          c4 @?= ExitSuccess
          assertBool out4 ("non-behavioural-basis rationale=\"typo\" approver=\"operator\"" `L.elem` L.lines out4)
          refused sc ["profile", "resolve", "--engineer", "zed", "--kind", "plan"] "unknown-engineer"
    , testCase "a tampered stored document is an integrity failure, never used" $
        withScenario $ \sc -> do
          engineerWithRepository sc "alice"
          team1 <- document sc "team1.json" (teamDocument 1 "supervisor")
          added sc team1
          setProfile sc "alice" "team"
          adminExecute
            (scAdmin sc)
            (T.unpack (scDb sc))
            "ALTER TABLE lockstep_profiles DISABLE TRIGGER USER; UPDATE lockstep_profiles SET document = replace(document, 'supervisor', 'none'); ALTER TABLE lockstep_profiles ENABLE TRIGGER USER"
          (c1, out1, err1) <- lockstep sc ["profile", "show", "team"]
          c1 @?= ExitFailure 70
          out1 @?= ""
          assertBool ("stderr: " <> err1) ("integrity" `L.isInfixOf` err1)
          (c2, out2, _) <- lockstep sc ["profile", "resolve", "--engineer", "alice", "--kind", "plan"]
          c2 @?= ExitFailure 70
          out2 @?= ""
    , testCase "profile add - reads the document from standard input" $
        withScenario $ \sc -> do
          (c, out, err) <- lockstepStdin sc ["profile", "add", "-"] (teamDocument 1 "supervisor")
          assertBool ("add - failed: " <> out <> err) (c == ExitSuccess)
          case L.words out of
            ["profile", "team", "version", "1", "digest", _, "added"] -> pure ()
            _ -> assertFailure ("unexpected output: " <> out)
    ]

{- | The default Profile: an impact gate (engineering only, with an exception
path) and a review gate; declares the "eng" specialization for engineering.
-}
teamDocument :: Int -> String -> String
teamDocument version approval =
  "{\"id\":\"team\",\"version\":"
    <> show version
    <> ",\"gates\":[{\"id\":\"impact\",\"stage\":\"before-execution\",\"artifacts\":[\"impact-assessment\"],\"kinds\":[\"engineering\"],\"verifiers\":[\"human-inspection\"],\"approval\":\""
    <> approval
    <> "\",\"exception_path\":true},{\"id\":\"review\",\"stage\":\"before-acceptance\",\"artifacts\":[\"review-record\"],\"verifiers\":[\"independent-review\"],\"approval\":\"human\"}],\"specializations\":[{\"when_kind\":\"engineering\",\"profile\":\"eng\"}]}"

-- | A specialization redefining impact for every kind with the given approval and no exception path.
specDocument :: String -> Int -> String -> String
specDocument name version approval =
  "{\"id\":\""
    <> name
    <> "\",\"version\":"
    <> show version
    <> ",\"gates\":[{\"id\":\"impact\",\"stage\":\"before-execution\",\"artifacts\":[\"impact-assessment\"],\"verifiers\":[\"human-inspection\"],\"approval\":\""
    <> approval
    <> "\"}]}"

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scDir :: FilePath
  , scEnv :: [(String, String)]
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action =
  withSystemTempDirectory "lockstep-p23" $ \tmp -> do
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
        sc = Scenario admin db (tmp <> "/w") env
      (code, _, err) <- runLockstep env ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      action sc

lockstep :: Scenario -> [String] -> IO (ExitCode, String, String)
lockstep sc =
  runLockstep (scEnv sc)

-- | Runs the binary with the given standard input (at most 20 s).
lockstepStdin :: Scenario -> [String] -> String -> IO (ExitCode, String, String)
lockstepStdin sc args input = do
  base <- getEnvironment
  let
    env = scEnv sc <> L.filter (\(k, _) -> k `L.notElem` fmap fst (scEnv sc)) base
  result <- timeout 20000000 (Process.readCreateProcessWithExitCode ((Process.proc "lockstep" args) {Process.env = Just env}) input)
  maybe (assertFailure ("lockstep " <> show args <> " did not finish within 20 s")) pure result

document :: Scenario -> String -> String -> IO FilePath
document sc name content = do
  let
    path = scDir sc <> "/" <> name
  writeFile path content
  pure path

added :: Scenario -> FilePath -> Assertion
added sc path = do
  (code, out, err) <- lockstep sc ["profile", "add", path]
  assertBool ("profile add " <> path <> ": " <> out <> err) (code == ExitSuccess && "added" `L.isSuffixOf` L.filter (/= '\n') out)

setProfile :: Scenario -> String -> String -> Assertion
setProfile sc engineer profile = do
  (code, out, err) <- lockstep sc ["repository", "set-profile", "--engineer", engineer, profile]
  assertBool ("set-profile: " <> out <> err) (code == ExitSuccess)

-- | Adds an Engineer and registers a fresh Git repository for it.
engineerWithRepository :: Scenario -> String -> Assertion
engineerWithRepository sc name = do
  (c1, _, e1) <- lockstep sc ["engineer", "add", name]
  assertBool ("engineer add: " <> e1) (c1 == ExitSuccess)
  let
    repo = scDir sc <> "/repo-" <> name
  git sc (scDir sc) ["init", "-q", "repo-" <> name]
  git sc repo ["commit", "-q", "--allow-empty", "-m", "first"]
  (c2, o2, e2) <- lockstep sc ["repository", "register", "--engineer", name, repo]
  assertBool ("register: " <> o2 <> e2) (c2 == ExitSuccess)

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
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git " <> show args <> ": " <> show other)

-- | A refusal with the given code on stdout and stderr; exit 65.
refused :: Scenario -> [String] -> String -> Assertion
refused sc args code = do
  (exit, out, err) <- lockstep sc args
  exit @?= ExitFailure 65
  case L.words out of
    ["refused", printed] -> printed @?= code
    ["refused", printed, "decision", n] | L.all (`L.elem` ['0' .. '9']) n -> printed @?= code
    _ -> assertFailure (show args <> ": unexpected stdout: " <> out <> " stderr: " <> err)
  assertBool (show args <> ": stderr lacks the code: " <> err) (("refused (" <> code <> ")") `L.isInfixOf` err)

-- | The digest on the last line, @digest <hex>@.
shownDigest :: String -> Maybe String
shownDigest out =
  case L.reverse (L.lines out) of
    line : _ | ["digest", d] <- L.words line -> Just d
    _ -> Nothing

-- | The SHA-256 of everything before the digest line.
renderingDigest :: String -> Maybe String
renderingDigest out =
  case L.reverse (L.lines out) of
    _ : rendering ->
      let
        text = T.pack (L.unlines (L.reverse rendering))
      in
        case sha256Hasher of
          Hasher f -> Just (T.unpack (contentDigestText (f text)))
    [] -> Nothing

count :: Scenario -> String -> IO Int
count sc table = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> table)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> table)

sqlFails :: Scenario -> String -> Assertion
sqlFails sc statement = do
  result <- try (adminExecute (scAdmin sc) (T.unpack (scDb sc)) statement) :: IO (Either SomeException ())
  case result of
    Left _ -> pure ()
    Right () -> assertFailure ("the statement succeeded: " <> statement)
