{-# LANGUAGE OverloadedStrings #-}

{- | A migrated database with an Engineer @alice@ who owns a fresh Git
repository whose default Profile is @team@ (C-P2.5 §7). The setup runs the
real binary; the tests then call the Application layer directly through a
'DatabaseRuntime'. Every helper here is exercised by the "scenario setup"
case, which passes before the ledger exists.

Profile @team@ v1: gate @impact@ (before-execution, impact assessment, human
inspection, supervisor approval, exception path) and gate @verify@
(before-acceptance, a verification record).
-}
module Lockstep.Support.Ledger
  ( Ledger (..)
  , withLedger
  , binary
  , addEngineerWithRepository
  , addEngineer
  , queryTexts
  , count
  , sqlFails
  , sql
  ) where

import Control.Exception (SomeException, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import System.Directory (createDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure)
import Text.Show (show)

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Support.Postgres
  ( AdminSettings (..)
  , adminExecute
  , databaseConfigFor
  , queryInts
  , requireAdmin
  , withFreshDatabase
  , withRuntime
  , writeConfigFile
  )
import Lockstep.Support.Process (runLockstep)

data Ledger
  = Ledger
  { lgAdmin :: AdminSettings
  , lgDb :: T.Text
  , lgDir :: FilePath
  , lgEnv :: [(String, String)]
  , lgRuntime :: DatabaseRuntime
  }

teamDocument :: String
teamDocument =
  "{\"id\":\"team\",\"version\":1,\"gates\":["
    <> "{\"id\":\"impact\",\"stage\":\"before-execution\",\"artifacts\":[\"impact-assessment\"],\"verifiers\":[\"human-inspection\"],\"approval\":\"supervisor\",\"exception_path\":true},"
    <> "{\"id\":\"verify\",\"stage\":\"before-acceptance\",\"artifacts\":[\"verification-record\"],\"verifiers\":[\"deterministic-command\"],\"approval\":\"none\"}"
    <> "]}"

withLedger :: (Ledger -> Assertion) -> Assertion
withLedger action =
  withSystemTempDirectory "lockstep-p25" $ \tmp -> do
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
        dir = tmp <> "/w"
      binaryIn env ["db", "migrate"]
      addEngineerWithRepositoryIn env dir "alice"
      let
        document = dir <> "/team.json"
      writeFile document teamDocument
      binaryIn env ["profile", "add", document]
      binaryIn env ["repository", "set-profile", "--engineer", "alice", "team"]
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime ->
        action (Ledger admin db dir env runtime)

-- | Runs the binary; anything but exit 0 fails the test.
binary :: Ledger -> [String] -> Assertion
binary lg =
  binaryIn (lgEnv lg)

binaryIn :: [(String, String)] -> [String] -> Assertion
binaryIn env args = do
  (code, out, err) <- runLockstep env args
  assertBool ("lockstep " <> show args <> ": " <> out <> err) (code == ExitSuccess)

addEngineer :: Ledger -> String -> Assertion
addEngineer lg name =
  binary lg ["engineer", "add", name]

addEngineerWithRepository :: Ledger -> String -> Assertion
addEngineerWithRepository lg =
  addEngineerWithRepositoryIn (lgEnv lg) (lgDir lg)

addEngineerWithRepositoryIn :: [(String, String)] -> FilePath -> String -> Assertion
addEngineerWithRepositoryIn env dir name = do
  binaryIn env ["engineer", "add", name]
  let
    repo = dir <> "/repo-" <> name
  git env dir ["init", "-q", "repo-" <> name]
  git env repo ["commit", "-q", "--allow-empty", "-m", "first"]
  binaryIn env ["repository", "register", "--engineer", name, repo]

git :: [(String, String)] -> FilePath -> [String] -> Assertion
git extra dir args = do
  let
    identity = ["-c", "user.name=Lockstep Test", "-c", "user.email=test@example.invalid", "-c", "init.defaultBranch=main"]
  base <- getEnvironment
  let
    env = extra <> L.filter (\(k, _) -> k `L.notElem` fmap fst extra) base
  result <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case result of
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git " <> show args <> ": " <> show other)

-- | Runs a query whose single column is named @v@ and holds text.
queryTexts :: Ledger -> String -> IO [T.Text]
queryTexts lg statement = do
  pool <- O.createConnectionPool (connection (lgAdmin lg) (lgDb lg))
  O.runOrville pool $
    O.executeAndDecode
      O.SelectQuery
      (RawSql.fromString statement)
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "v")))

connection :: AdminSettings -> T.Text -> O.ConnectionOptions
connection admin database =
  O.ConnectionOptions
    { O.connectionString =
        L.unwords
          [ "host=" <> adminHost admin
          , "port=" <> show (adminPort admin)
          , "user=" <> adminUser admin
          , "password=" <> adminPassword admin
          , "dbname=" <> T.unpack database
          , "connect_timeout=5"
          ]
    , O.connectionNoticeReporting = O.DisableNoticeReporting
    , O.connectionPoolStripes = O.StripeCount 1
    , O.connectionPoolLingerTime = 1
    , O.connectionPoolMaxConnections = O.MaxConnectionsPerStripe 1
    }

count :: Ledger -> String -> IO Int
count lg table = do
  rows <- queryInts (lgAdmin lg) (lgDb lg) ("SELECT count(*)::integer AS v FROM " <> table)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> table)

-- | One SQL statement as the admin user.
sql :: Ledger -> String -> Assertion
sql lg =
  adminExecute (lgAdmin lg) (T.unpack (lgDb lg))

sqlFails :: Ledger -> String -> Assertion
sqlFails lg statement = do
  result <- try (sql lg statement) :: IO (Either SomeException ())
  case result of
    Left _ -> pure ()
    Right () -> assertFailure ("statement succeeded: " <> statement)
