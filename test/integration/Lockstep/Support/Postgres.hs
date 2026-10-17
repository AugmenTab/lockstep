{-# LANGUAGE OverloadedStrings #-}

{- | Real PostgreSQL helpers for the integration suite. scripts/check starts a
disposable PostgreSQL container and passes its superuser settings in
LOCKSTEP_TEST_PG_*. Missing settings fail the test: never a silent skip.
-}
module Lockstep.Support.Postgres
  ( AdminSettings (..)
  , requireAdmin
  , withFreshDatabase
  , adminExecute
  , queryInts
  , queryBool
  , databaseConfigFor
  , withRuntime
  , writeConfigFile
  ) where

import Control.Exception (bracket)
import Data.Bits ((.|.))
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.List qualified as L
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Unique (hashUnique, newUnique)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import System.Environment (lookupEnv)
import System.IO (FilePath)
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode)
import Test.Tasty.HUnit (assertFailure)
import Text.Read (readMaybe)
import Text.Show (show)

import Lockstep.Application.Database (DatabaseRuntime, closeDatabase, openDatabase)
import Lockstep.Foundation.Config (mkPort)
import Lockstep.Foundation.SystemConfig (DatabaseConfig (..), mkSecret)

data AdminSettings
  = AdminSettings
  { adminHost :: String
  , adminPort :: Int
  , adminUser :: String
  , adminPassword :: String
  }

requireAdmin :: IO AdminSettings
requireAdmin = do
  host <- requireEnv "LOCKSTEP_TEST_PG_HOST"
  portText <- requireEnv "LOCKSTEP_TEST_PG_PORT"
  user <- requireEnv "LOCKSTEP_TEST_PG_USER"
  password <- requireEnv "LOCKSTEP_TEST_PG_PASSWORD"
  port <-
    maybe
      (assertFailure ("precondition invalid: LOCKSTEP_TEST_PG_PORT=" <> portText))
      pure
      (readMaybe portText)
  pure (AdminSettings host port user password)

requireEnv :: String -> IO String
requireEnv name = do
  value <- lookupEnv name
  case value of
    Nothing -> assertFailure ("precondition missing: " <> name <> " is not set (NOT_RUN)")
    Just v -> pure v

-- | Creates an empty database, runs the action with its name, drops it.
withFreshDatabase :: AdminSettings -> (T.Text -> IO a) -> IO a
withFreshDatabase admin action = do
  n <- fmap hashUnique newUnique
  now <- getPOSIXTime
  let
    stamp = show (truncate (now * 1000000) :: Integer)
    name = "lockstep_t_" <> stamp <> "_" <> show n
  bracket
    (adminExecute admin "postgres" ("CREATE DATABASE " <> name))
    (\_ -> adminExecute admin "postgres" ("DROP DATABASE IF EXISTS " <> name <> " WITH (FORCE)"))
    (\_ -> action (T.pack name))

connectionOptions :: AdminSettings -> String -> O.ConnectionOptions
connectionOptions admin database =
  O.ConnectionOptions
    { O.connectionString =
        L.unwords
          [ "host=" <> adminHost admin
          , "port=" <> show (adminPort admin)
          , "user=" <> adminUser admin
          , "password=" <> adminPassword admin
          , "dbname=" <> database
          , "connect_timeout=5"
          ]
    , O.connectionNoticeReporting = O.DisableNoticeReporting
    , O.connectionPoolStripes = O.StripeCount 1
    , O.connectionPoolLingerTime = 1
    , O.connectionPoolMaxConnections = O.MaxConnectionsPerStripe 1
    }

withAdminPool :: AdminSettings -> String -> (O.ConnectionPool -> IO a) -> IO a
withAdminPool admin database action = do
  pool <- O.createConnectionPool (connectionOptions admin database)
  action pool

adminExecute :: AdminSettings -> String -> String -> IO ()
adminExecute admin database sql =
  withAdminPool admin database $ \pool ->
    O.runOrville pool (O.executeVoid O.OtherQuery (RawSql.fromString sql))

-- | Runs a query whose single column is named @v@ and holds an integer.
queryInts :: AdminSettings -> T.Text -> String -> IO [Int]
queryInts admin database sql =
  withAdminPool admin (T.unpack database) $ \pool -> do
    rows <-
      O.runOrville pool $
        O.executeAndDecode
          O.SelectQuery
          (RawSql.fromString sql)
          (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.integerField "v")))
    pure (fmap (fromIntegral :: Int32 -> Int) rows)

-- | Runs a query whose single row and column @v@ holds a boolean.
queryBool :: AdminSettings -> T.Text -> String -> IO Bool
queryBool admin database sql =
  withAdminPool admin (T.unpack database) $ \pool -> do
    rows <-
      O.runOrville pool $
        O.executeAndDecode
          O.SelectQuery
          (RawSql.fromString sql)
          (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.booleanField "v")))
    case rows of
      [value] -> pure value
      _ -> assertFailure ("expected one row from: " <> sql)

-- | The Lockstep database configuration for a test database, as the admin user.
databaseConfigFor :: AdminSettings -> T.Text -> IO DatabaseConfig
databaseConfigFor admin database = do
  port <-
    maybe
      (assertFailure "precondition invalid: admin port out of range")
      pure
      (mkPort (toInteger (adminPort admin)))
  pure
    DatabaseConfig
      { dbHost = T.pack (adminHost admin)
      , dbPort = port
      , dbName = database
      , dbUser = T.pack (adminUser admin)
      , dbPassword = mkSecret (T.pack (adminPassword admin))
      }

withRuntime :: DatabaseConfig -> (DatabaseRuntime -> IO a) -> IO a
withRuntime config =
  bracket (openDatabase config) closeDatabase

-- | Writes a LOCKSTEP_CONFIG file (mode 0600) for a test database.
writeConfigFile :: FilePath -> AdminSettings -> T.Text -> String -> IO FilePath
writeConfigFile dir admin database password = do
  let
    path = dir <> "/lockstep.json"
    json =
      "{\"database\":{\"host\":\""
        <> adminHost admin
        <> "\",\"port\":"
        <> show (adminPort admin)
        <> ",\"name\":\""
        <> T.unpack database
        <> "\",\"username\":\""
        <> adminUser admin
        <> "\",\"password\":\""
        <> password
        <> "\"}}"
  LBS8.writeFile path (LBS8.pack json)
  setFileMode path (ownerReadMode .|. ownerWriteMode)
  pure path
