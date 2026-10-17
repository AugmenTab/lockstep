module Lockstep.ServiceDbTest
  ( tests
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Flipstone.Prelude
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))
import Text.Show (show)

import Lockstep.Persistence.Migration (migrationId, migrationIdInt)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres
  ( AdminSettings (..)
  , requireAdmin
  , withFreshDatabase
  , writeConfigFile
  )
import Lockstep.Support.Process (freePort, httpGet, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "lockstep process with PostgreSQL"
    [ testCase "db migrate installs a fresh database, then is a no-op; db status reports it" $
        withConfig $ \admin env -> do
          (code1, out1, err1) <- runLockstep env ["db", "migrate"]
          code1 @?= ExitSuccess
          (code2, out2, err2) <- runLockstep env ["db", "migrate"]
          code2 @?= ExitSuccess
          (code3, out3, err3) <- runLockstep env ["db", "status"]
          code3 @?= ExitSuccess
          contains ("revision " <> expectedRevision) out3
          contains "pending 0" out3
          noSecret admin [out1, err1, out2, err2, out3, err3]
    , testCase "serve reports schema_behind truthfully, then ready after migrate; starts persist across restarts" $
        withConfig $ \admin env -> withSystemTempDirectory "lockstep-log" $ \dir -> do
          port <- freePort
          ((readiness1, health1, page1), log1) <-
            withService env port (dir <> "/serve1.log") $ do
              r <- httpGet port "/api/readiness"
              h <- httpGet port "/api/health_check"
              p <- httpGet port "/"
              pure (r, h, p)
          readiness1 @?= (503, "not_ready schema_behind " <> show (L.length migrations))
          fst health1 @?= 204
          contains "not ready" (lower (snd page1))
          (migrateCode, migrateOut, migrateErr) <- runLockstep env ["db", "migrate"]
          migrateCode @?= ExitSuccess
          ((readiness2, page2), log2) <-
            withService env port (dir <> "/serve2.log") $ do
              r <- httpGet port "/api/readiness"
              p <- httpGet port "/"
              pure (r, p)
          readiness2 @?= (200, "ready " <> expectedRevision)
          contains "database is ready" (lower (snd page2))
          contains "service starts recorded: 1" (lower (snd page2))
          ((page3, _), log3) <-
            withService env port (dir <> "/serve3.log") $ do
              p <- httpGet port "/"
              pure (p, ())
          contains "service starts recorded: 2" (lower (snd page3))
          noSecret admin [log1, log2, log3, snd page1, snd page2, snd page3, migrateOut, migrateErr]
    , testCase "an invalid configuration file stops serve with exit 66" $
        withConfigFile "{\"database\": " $ \env -> do
          (code, _, err) <- runLockstep env ["serve", "--port", "1"]
          code @?= ExitFailure 66
          noProbe [err]
    , testCase "a leftover rollbar block stops serve with exit 66 and names the key"
        $ withConfigFile
          "{\"database\":{\"host\":\"h\",\"port\":5432,\"name\":\"n\",\"username\":\"u\",\"password\":\"probe-secret-7f3a\"},\"rollbar\":{}}"
        $ \env -> do
          (code, _, err) <- runLockstep env ["serve", "--port", "1"]
          code @?= ExitFailure 66
          contains "rollbar" err
          noProbe [err]
    , testCase "a configuration readable by others stops serve with exit 66" $
        withSystemTempDirectory "lockstep-config" $ \dir -> do
          let
            path = dir <> "/lockstep.json"
          writeFile path "{\"database\":{\"host\":\"h\",\"port\":5432,\"name\":\"n\",\"username\":\"u\",\"password\":\"probe-secret-7f3a\"}}"
          setFileMode path 0o644
          (code, _, err) <- runLockstep [("LOCKSTEP_CONFIG", path)] ["serve", "--port", "1"]
          code @?= ExitFailure 66
          contains "permission" (lower err)
          noProbe [err]
    , testCase "a missing configuration file stops serve with exit 66" $ do
        (code, _, _) <- runLockstep [("LOCKSTEP_CONFIG", "/nonexistent/lockstep.json")] ["serve", "--port", "1"]
        code @?= ExitFailure 66
    ]

expectedRevision :: String
expectedRevision = show (L.foldl' max 0 (fmap (migrationIdInt . migrationId) migrations))

withConfig :: (AdminSettings -> [(String, String)] -> IO a) -> IO a
withConfig action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-config" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      action admin [("LOCKSTEP_CONFIG", path)]

withConfigFile :: String -> ([(String, String)] -> IO a) -> IO a
withConfigFile contents action =
  withSystemTempDirectory "lockstep-config" $ \dir -> do
    let
      path = dir <> "/lockstep.json"
    writeFile path contents
    setFileMode path 0o600
    action [("LOCKSTEP_CONFIG", path)]

contains :: String -> String -> Assertion
contains needle haystack =
  assertBool ("expected output to contain " <> needle <> " in:\n" <> haystack) (needle `L.isInfixOf` haystack)

noSecret :: AdminSettings -> [String] -> Assertion
noSecret admin outputs =
  assertBool
    "the database password appeared in output or a page"
    (not (any (adminPassword admin `L.isInfixOf`) outputs))

noProbe :: [String] -> Assertion
noProbe outputs =
  assertBool "the configured password appeared in output" (not (any ("probe-secret-7f3a" `L.isInfixOf`) outputs))

lower :: String -> String
lower =
  fmap Char.toLower
