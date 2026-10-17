{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Application.ReadinessTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Database
  ( NotReadyReason (..)
  , Readiness (..)
  , classifyConnectionFailure
  , readinessCode
  )
import Lockstep.Persistence.Migration (MigrationId, MigrationRefusal (..), mkMigrationId)

tests :: TestTree
tests =
  testGroup
    "Readiness"
    [ testGroup
        "libpq failure classification"
        [ testCase "connection refused is unreachable" $
            classifyConnectionFailure
              "connection to server at \"127.0.0.1\", port 5999 failed: Connection refused\n\tIs the server running on that host and accepting TCP/IP connections?"
              @?= DatabaseUnreachable
        , testCase "an unknown host is unreachable" $
            classifyConnectionFailure
              "could not translate host name \"nope\" to address: Name or service not known"
              @?= DatabaseUnreachable
        , testCase "a connect timeout is unreachable" $
            classifyConnectionFailure
              "connection to server at \"10.255.255.1\", port 5432 failed: timeout expired"
              @?= DatabaseUnreachable
        , testCase "a password failure is an authentication failure" $
            classifyConnectionFailure
              "connection to server at \"db\" (172.18.0.2), port 5432 failed: FATAL:  password authentication failed for user \"lockstep\""
              @?= AuthenticationFailed
        , testCase "a missing database is reported as missing" $
            classifyConnectionFailure
              "connection to server at \"db\" (172.18.0.2), port 5432 failed: FATAL:  database \"nope\" does not exist"
              @?= DatabaseMissing
        , testCase "anything else is a database error" $
            classifyConnectionFailure
              "connection to server at \"db\", port 5432 failed: FATAL:  sorry, too many clients already"
              @?= DatabaseError
        ]
    , testGroup
        "readiness codes"
        [ testCase "ready carries the revision" $ do
            one <- expectId 1
            readinessCode (Ready one) @?= "ready 1"
        , testCase "every not-ready reason has its own code" $ do
            two <- expectId 2
            four <- expectId 4
            fmap
              (readinessCode . NotReady)
              [ DatabaseNotConfigured
              , DatabaseUnreachable
              , AuthenticationFailed
              , DatabaseMissing
              , SchemaBehind 2
              , SchemaInvalid (ChecksumMismatch two)
              , SchemaInvalid (UnknownAppliedMigration four)
              , SchemaInvalid (MissingAppliedMigration two)
              , SchemaInvalid InvalidMigrationList
              , DatabaseError
              ]
              @?= [ "not_ready database_not_configured"
                  , "not_ready database_unreachable"
                  , "not_ready authentication_failed"
                  , "not_ready database_missing"
                  , "not_ready schema_behind 2"
                  , "not_ready schema_invalid checksum_mismatch 2"
                  , "not_ready schema_invalid unknown_applied_migration 4"
                  , "not_ready schema_invalid missing_applied_migration 2"
                  , "not_ready schema_invalid invalid_migration_list"
                  , "not_ready database_error"
                  ]
        , testCase "no not-ready code can be read as ready" $
            assertBool
              "a not-ready code starts with \"ready\""
              ( not
                  ( any
                      (T.isPrefixOf "ready" . readinessCode . NotReady)
                      [DatabaseNotConfigured, DatabaseUnreachable, AuthenticationFailed, DatabaseMissing, SchemaBehind 1, SchemaInvalid InvalidMigrationList, DatabaseError]
                  )
              )
        ]
    ]

expectId :: Int -> IO MigrationId
expectId n =
  maybe (assertFailure ("mkMigrationId rejected " <> show n)) pure (mkMigrationId n)
