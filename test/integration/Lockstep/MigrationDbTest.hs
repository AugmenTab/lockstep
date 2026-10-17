{-# LANGUAGE OverloadedStrings #-}

module Lockstep.MigrationDbTest
  ( tests
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (doesFileExist)
import System.IO (writeFile)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Database
  ( DatabaseRuntime
  , MigrateError (..)
  , NotReadyReason (..)
  , Readiness (..)
  , checkReadiness
  , migrateWithPolicy
  , runMigrations
  )
import Lockstep.Foundation.Cli (BackupPolicy (..))
import Lockstep.Foundation.Config (mkPort)
import Lockstep.Foundation.SystemConfig (DatabaseConfig (..), mkSecret)
import Lockstep.Persistence.Migration
  ( Migration (..)
  , MigrationId
  , MigrationRefusal (..)
  , checksumText
  , migrationChecksum
  , migrationIdInt
  , mkMigrationId
  )
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres
  ( AdminSettings
  , adminExecute
  , databaseConfigFor
  , queryBool
  , queryInts
  , requireAdmin
  , withFreshDatabase
  , withRuntime
  )

tests :: TestTree
tests =
  testGroup
    "PostgreSQL migrations and readiness"
    [ testCase "fresh install: the production list applies, then is a no-op" $
        withDb $ \_ _ config -> withRuntime config $ \rt -> do
          first <- runMigrations migrations rt
          ints first @?= Right (fmap (migrationIdInt . migrationId) migrations)
          second <- runMigrations migrations rt
          ints second @?= Right []
    , testCase "an ordered list applies in id order and the ledger records that order" $
        withDb $ \admin db config -> withRuntime config $ \rt -> do
          list <- threeMigrations
          result <- runMigrations list rt
          ints result @?= Right [1, 2, 3]
          ledger <- queryInts admin db "SELECT id AS v FROM lockstep_schema_migrations ORDER BY applied_at, id"
          ledger @?= [1, 2, 3]
    , testCase "after a partial run only the remainder applies" $
        withDb $ \_ _ config -> withRuntime config $ \rt -> do
          list <- threeMigrations
          partial <- runMigrations (L.take 2 list) rt
          ints partial @?= Right [1, 2]
          rest <- runMigrations list rt
          ints rest @?= Right [3]
    , testCase "a failing migration leaves no DDL and no ledger row; earlier ones stay" $
        withDb $ \admin db config -> withRuntime config $ \rt -> do
          one <- expectId 1
          two <- expectId 2
          three <- expectId 3
          let
            list =
              [ Migration one "create a" "CREATE TABLE a (id integer);"
              , Migration two "broken" "CREATE TABLE b (id integer); SELECT * FROM does_not_exist;"
              , Migration three "create c" "CREATE TABLE c (id integer);"
              ]
          result <- runMigrations list rt
          ints result @?= Left (MigrateFailed two [one])
          ledger <- queryInts admin db "SELECT id AS v FROM lockstep_schema_migrations ORDER BY id"
          ledger @?= [1]
          bGone <- queryBool admin db "SELECT to_regclass('public.b') IS NULL AS v"
          assertBool "table b from the failed migration exists" bGone
          cGone <- queryBool admin db "SELECT to_regclass('public.c') IS NULL AS v"
          assertBool "a migration after the failure ran" cGone
    , testCase "a changed applied migration is refused before any SQL runs" $
        withDb $ \admin db config -> withRuntime config $ \rt -> do
          list <- threeMigrations
          _ <- runMigrations (L.take 2 list) rt
          two <- expectId 2
          let
            tampered = fmap (\m -> if migrationId m == two then m {migrationSql = "CREATE TABLE b2 (id integer);"} else m) list
          result <- runMigrations tampered rt
          ints result @?= Left (MigrateRefused (ChecksumMismatch two))
          cGone <- queryBool admin db "SELECT to_regclass('public.c') IS NULL AS v"
          assertBool "migration 3 ran despite the refusal" cGone
    , testCase "a database ahead of the binary is refused" $
        withDb $ \_ _ config -> withRuntime config $ \rt -> do
          list <- threeMigrations
          _ <- runMigrations list rt
          three <- expectId 3
          result <- runMigrations (L.take 2 list) rt
          ints result @?= Left (MigrateRefused (UnknownAppliedMigration three))
    , testCase "a gap in the ledger is refused" $
        withDb $ \admin db config -> withRuntime config $ \rt -> do
          list <- threeMigrations
          _ <- runMigrations (L.take 1 list) rt
          two <- expectId 2
          case L.drop 2 list of
            [third] ->
              adminExecute admin (T.unpack db) $
                "INSERT INTO lockstep_schema_migrations (id, description, checksum) VALUES (3, 'forged', '"
                  <> T.unpack (checksumText (migrationChecksum third))
                  <> "')"
            _ -> assertFailure "fixture: expected a third migration"
          result <- runMigrations list rt
          ints result @?= Left (MigrateRefused (MissingAppliedMigration two))
    , testCase "two concurrent runners apply each migration exactly once" $
        withDb $ \admin db config -> do
          one <- expectId 1
          two <- expectId 2
          let
            list =
              [ Migration one "slow a" "SELECT pg_sleep(0.5); CREATE TABLE a (id integer);"
              , Migration two "create b" "CREATE TABLE b (id integer);"
              ]
          doneA <- newEmptyMVar
          doneB <- newEmptyMVar
          _ <- forkIO (try (withRuntime config (runMigrations list)) >>= putMVar doneA)
          _ <- forkIO (try (withRuntime config (runMigrations list)) >>= putMVar doneB)
          a <- takeMVar doneA
          b <- takeMVar doneB
          case (a, b) of
            (Right (Right appliedA), Right (Right appliedB)) ->
              L.sort (fmap migrationIdInt (appliedA <> appliedB)) @?= [1, 2]
            _ ->
              assertFailure ("a runner failed: " <> show (fmap ints (outcome a), fmap ints (outcome b)))
          ledger <- queryInts admin db "SELECT id AS v FROM lockstep_schema_migrations ORDER BY id"
          ledger @?= [1, 2]
    , testCase "readiness: schema behind before migrate, ready after" $
        withDb $ \_ _ config -> withRuntime config $ \rt -> do
          before <- checkReadiness (Just rt)
          before @?= NotReady (SchemaBehind (L.length migrations))
          _ <- runMigrations migrations rt
          after <- checkReadiness (Just rt)
          case L.reverse migrations of
            latest : _ -> after @?= Ready (migrationId latest)
            [] -> assertFailure "the production migration list is empty"
    , testCase "readiness: a wrong password is an authentication failure" $
        withDb $ \_ _ config ->
          withRuntime config {dbPassword = mkSecret "definitely-wrong"} $ \rt -> do
            readiness <- checkReadiness (Just rt)
            readiness @?= NotReady AuthenticationFailed
    , testCase "readiness: a missing database is reported as missing" $
        withDb $ \_ _ config ->
          withRuntime config {dbName = "lockstep_no_such_database"} $ \rt -> do
            readiness <- checkReadiness (Just rt)
            readiness @?= NotReady DatabaseMissing
    , testCase "readiness: a closed port is unreachable" $
        withDb $ \_ _ config -> do
          closed <- maybe (assertFailure "mkPort 1") pure (mkPort 1)
          withRuntime config {dbHost = "127.0.0.1", dbPort = closed} $ \rt -> do
            readiness <- checkReadiness (Just rt)
            readiness @?= NotReady DatabaseUnreachable
    , testGroup "backup gate" backupGateTests
    ]

backupGateTests :: [TestTree]
backupGateTests =
  [ testCase "an applied ledger with pending work and no backup is refused" $
      withTwo $ \admin db rt list -> do
        result <- migrateWithPolicy BackupRequiredIfApplied list rt
        ints result @?= Left BackupRequired
        assertLedger admin db [1]
  , testCase "a missing backup file is refused" $
      withTwo $ \admin db rt list -> do
        result <- migrateWithPolicy (BackupFile "/nonexistent/backup.dump") list rt
        ints result @?= Left (BackupMissing "/nonexistent/backup.dump")
        assertLedger admin db [1]
  , testCase "a backup older than the last applied migration is refused" $
      withSystemTempDirectory "lockstep-backup" $ \dir -> do
        let
          path = dir <> "/old.dump"
        writeFile path "stale backup bytes"
        withTwo $ \admin db rt list -> do
          exists <- doesFileExist path
          assertBool "fixture file missing" exists
          result <- migrateWithPolicy (BackupFile path) list rt
          ints result @?= Left (BackupStale path)
          assertLedger admin db [1]
  , testCase "a fresh backup file allows the migration" $
      withSystemTempDirectory "lockstep-backup" $ \dir ->
        withTwo $ \admin db rt list -> do
          let
            path = dir <> "/fresh.dump"
          writeFile path "fresh backup bytes"
          result <- migrateWithPolicy (BackupFile path) list rt
          ints result @?= Right [2]
          assertLedger admin db [1, 2]
  , testCase "an explicit --no-backup allows the migration" $
      withTwo $ \admin db rt list -> do
        result <- migrateWithPolicy NoBackup list rt
        ints result @?= Right [2]
        assertLedger admin db [1, 2]
  , testCase "an empty database needs no backup" $
      withDb $ \admin db config -> withRuntime config $ \rt -> do
        list <- fmap (L.take 2) threeMigrations
        result <- migrateWithPolicy BackupRequiredIfApplied list rt
        ints result @?= Right [1, 2]
        assertLedger admin db [1, 2]
  ]

withTwo :: (AdminSettings -> T.Text -> DatabaseRuntime -> [Migration] -> IO a) -> IO a
withTwo action =
  withDb $ \admin db config -> withRuntime config $ \rt -> do
    list <- fmap (L.take 2) threeMigrations
    _ <- runMigrations (L.take 1 list) rt
    action admin db rt list

withDb :: (AdminSettings -> T.Text -> DatabaseConfig -> IO a) -> IO a
withDb action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db -> do
    config <- databaseConfigFor admin db
    action admin db config

assertLedger :: AdminSettings -> T.Text -> [Int] -> Assertion
assertLedger admin db expected = do
  ledger <- queryInts admin db "SELECT id AS v FROM lockstep_schema_migrations ORDER BY id"
  ledger @?= expected

ints :: Either MigrateError [MigrationId] -> Either MigrateError [Int]
ints =
  fmap (fmap migrationIdInt)

outcome :: Either SomeException (Either MigrateError [MigrationId]) -> Either String (Either MigrateError [MigrationId])
outcome =
  either (Left . show) Right

expectId :: Int -> IO MigrationId
expectId n =
  maybe (assertFailure ("mkMigrationId rejected " <> show n)) pure (mkMigrationId n)

threeMigrations :: IO [Migration]
threeMigrations = do
  one <- expectId 1
  two <- expectId 2
  three <- expectId 3
  pure
    [ Migration one "create a" "CREATE TABLE a (id integer);"
    , Migration two "create b" "CREATE TABLE b (id integer);"
    , Migration three "create c" "CREATE TABLE c (id integer);"
    ]
