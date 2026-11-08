{- | A fresh PostgreSQL database per test, from LOCKSTEP_TEST_PG_*, as for the
integration suite; missing settings fail the test.
-}
module Lockstep.Compliance.Support
  ( withFreshDatabase
  , withMigrated
  , withMigratedRuntime
  , textQuery
  , executeSql
  ) where

import Control.Exception (bracket)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Unique (hashUnique, newUnique)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import System.Environment (lookupEnv)
import Test.Tasty.HUnit (assertFailure)
import Text.Read (readMaybe)
import Text.Show (show)

import Lockstep.Application.Database (DatabaseRuntime, closeDatabase, openDatabase, runMigrations)
import Lockstep.Foundation.Config (mkPort)
import Lockstep.Foundation.SystemConfig (DatabaseConfig (..), mkSecret)
import Lockstep.Persistence.Connection (poolOptions)
import Lockstep.Persistence.Migrations (migrations)

-- | An empty database, dropped afterwards.
withFreshDatabase :: (DatabaseConfig -> IO ()) -> IO ()
withFreshDatabase action = do
  host <- requireEnv "LOCKSTEP_TEST_PG_HOST"
  portText <- requireEnv "LOCKSTEP_TEST_PG_PORT"
  user <- requireEnv "LOCKSTEP_TEST_PG_USER"
  password <- requireEnv "LOCKSTEP_TEST_PG_PASSWORD"
  port <- maybe (assertFailure ("precondition invalid: LOCKSTEP_TEST_PG_PORT=" <> portText)) pure (readMaybe portText >>= mkPort)
  n <- fmap hashUnique newUnique
  now <- getPOSIXTime
  let
    name = "lockstep_c_" <> show (truncate (now * 1000000) :: Integer) <> "_" <> show n
    config database = DatabaseConfig (T.pack host) port (T.pack database) (T.pack user) (mkSecret (T.pack password))
    admin = executeIn (config "postgres")
  bracket
    (admin ("CREATE DATABASE " <> name))
    (\_ -> admin ("DROP DATABASE IF EXISTS " <> name <> " WITH (FORCE)"))
    (\_ -> action (config name))

-- | A fresh database with the production migrations, with its runtime and an Orville runner.
withMigratedRuntime :: (DatabaseRuntime -> (forall a. O.Orville a -> IO a) -> IO ()) -> IO ()
withMigratedRuntime action =
  withFreshDatabase $ \config ->
    bracket (openDatabase config) closeDatabase $ \runtime -> do
      migrated <- runMigrations migrations runtime
      either (const (assertFailure "the production migrations did not apply")) (const (pure ())) migrated
      pool <- O.createConnectionPool (poolOptions config)
      action runtime (O.runOrville pool)

-- | A fresh database with the production migrations; the action runs Orville statements in it.
withMigrated :: ((forall a. O.Orville a -> IO a) -> IO ()) -> IO ()
withMigrated action =
  withMigratedRuntime (\_ run -> action run)

-- | A query whose single column @v@ is text.
textQuery :: O.MonadOrville m => String -> m [T.Text]
textQuery sql =
  O.executeAndDecode
    O.SelectQuery
    (RawSql.fromString sql)
    (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "v")))

-- | One statement, for test set-up the application never does.
executeSql :: O.MonadOrville m => String -> m ()
executeSql =
  O.executeVoid O.OtherQuery . RawSql.fromString

-- | Runs one statement; a refusal propagates with PostgreSQL's message.
executeIn :: DatabaseConfig -> String -> IO ()
executeIn config sql = do
  pool <- O.createConnectionPool (poolOptions config)
  O.runOrville pool (O.executeVoid O.OtherQuery (RawSql.fromString sql))

requireEnv :: String -> IO String
requireEnv name = do
  value <- lookupEnv name
  maybe (assertFailure ("precondition missing: " <> name <> " is not set (NOT_RUN)")) pure value
