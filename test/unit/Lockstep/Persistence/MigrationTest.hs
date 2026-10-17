{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Persistence.MigrationTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Persistence.Migration
  ( AppliedMigration (..)
  , Migration (..)
  , MigrationId
  , MigrationRefusal (..)
  , checksumText
  , migrationChecksum
  , migrationIdInt
  , mkMigrationId
  , planMigrations
  )
import Lockstep.Persistence.Migrations (migrations)

tests :: TestTree
tests =
  testGroup
    "Migration plan"
    [ testCase "an empty ledger plans every migration in order" $ do
        list <- threeMigrations
        fmap (fmap migrationId) (planMigrations list []) @?= Right (fmap migrationId list)
    , testCase "a full ledger plans nothing" $ do
        list <- threeMigrations
        fmap (fmap migrationId) (planMigrations list (fmap applied list)) @?= Right []
    , testCase "a ledger prefix plans the remainder" $ do
        list <- threeMigrations
        fmap (fmap migrationId) (planMigrations list (fmap applied (L.take 1 list)))
          @?= Right (fmap migrationId (L.drop 1 list))
    , testCase "a changed applied migration is a checksum mismatch" $ do
        list <- threeMigrations
        two <- expectId 2
        let
          tampered = fmap (\m -> if migrationId m == two then m {migrationSql = "SELECT 2;"} else m) list
        fmap (fmap migrationId) (planMigrations tampered (fmap applied list))
          @?= Left (ChecksumMismatch two)
    , testCase "an applied id the binary does not know means the database is ahead" $ do
        list <- threeMigrations
        four <- expectId 4
        let
          extra = Migration four "from the future" "SELECT 4;"
        fmap (fmap migrationId) (planMigrations list (fmap applied (list <> [extra])))
          @?= Left (UnknownAppliedMigration four)
    , testCase "a gap in the ledger is refused" $ do
        list <- threeMigrations
        two <- expectId 2
        let
          withGap = L.filter (\m -> migrationId m /= two) list
        fmap (fmap migrationId) (planMigrations list (fmap applied withGap))
          @?= Left (MissingAppliedMigration two)
    , testCase "a list with duplicate ids is invalid" $ do
        list <- threeMigrations
        fmap (fmap migrationId) (planMigrations (list <> L.take 1 list) [])
          @?= Left InvalidMigrationList
    , testCase "a list with decreasing ids is invalid" $ do
        list <- threeMigrations
        fmap (fmap migrationId) (planMigrations (L.reverse list) [])
          @?= Left InvalidMigrationList
    , testCase "the checksum is the SHA-256 of the SQL text" $ do
        one <- expectId 1
        checksumText (migrationChecksum (Migration one "probe" "SELECT 1;"))
          @?= "17db4fd369edb9244b9f91d9aeed145c3d04ad8ba6e95d06247f07a63527d11a"
    , testCase "mkMigrationId rejects 0 and negatives" $ do
        fmap migrationIdInt (mkMigrationId 0) @?= Nothing
        fmap migrationIdInt (mkMigrationId (-1)) @?= Nothing
        fmap migrationIdInt (mkMigrationId 1) @?= Just 1
    , testCase "the production migration list is valid and starts at 1" $ do
        fmap (fmap migrationId) (planMigrations migrations []) @?= Right (fmap migrationId migrations)
        fmap (migrationIdInt . migrationId) (L.take 1 migrations) @?= [1]
        assertBool
          "a production migration has an empty description"
          (not (any (T.null . migrationDescription) migrations))
    ]

applied :: Migration -> AppliedMigration
applied m =
  AppliedMigration
    { appliedId = migrationId m
    , appliedChecksum = migrationChecksum m
    }

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
