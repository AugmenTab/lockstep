{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Web.LivenessPageTest
  ( tests
  ) where

import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Char qualified as Char
import Data.Time qualified as Time
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase)
import Text.Show (show)

import Lockstep.Application.Database
  ( NotReadyReason (..)
  , Readiness (..)
  , ServiceStarts (..)
  )
import Lockstep.Persistence.Migration (MigrationId, MigrationRefusal (..), mkMigrationId)
import Lockstep.Web.Liveness (livenessPage)

tests :: TestTree
tests =
  testGroup
    "Liveness page readiness"
    [ testCase "not configured says readiness is not checked" $ do
        body <- render (NotReady DatabaseNotConfigured) Nothing
        contains "not checked" body
        lacks "database is ready" body
    , testGroup "every not-ready reason" (fmap notReadyCase notReadyReasons)
    , testCase "ready shows the revision and the persisted start count" $ do
        one <- expectId 1
        body <- render (Ready one) (Just (ServiceStarts 3 sampleTime))
        contains "database is ready" body
        contains "schema revision 1" body
        contains "service starts recorded: 3" body
        lacks "not ready" body
    ]

notReadyReasons :: [(String, NotReadyReason, BS.ByteString)]
notReadyReasons =
  [ ("unreachable", DatabaseUnreachable, "not_ready database_unreachable")
  , ("authentication", AuthenticationFailed, "not_ready authentication_failed")
  , ("missing", DatabaseMissing, "not_ready database_missing")
  , ("schema behind", SchemaBehind 2, "not_ready schema_behind 2")
  , ("schema invalid", SchemaInvalid InvalidMigrationList, "not_ready schema_invalid invalid_migration_list")
  , ("other error", DatabaseError, "not_ready database_error")
  ]

notReadyCase :: (String, NotReadyReason, BS.ByteString) -> TestTree
notReadyCase (label, reason, code) =
  testCase label $ do
    body <- render (NotReady reason) Nothing
    contains "not ready" body
    contains code body
    lacks "database is ready" body
    lacks "service starts recorded" body

sampleTime :: Time.UTCTime
sampleTime =
  Time.UTCTime (Time.fromGregorian 2026 10 17) 0

render :: Readiness -> Maybe ServiceStarts -> IO BS.ByteString
render readiness starts =
  pure
    . BS8.map Char.toLower
    . LBS.toStrict
    . renderLazyHTML
    $ livenessPage "127.0.0.1:8000" readiness starts

contains :: BS.ByteString -> BS.ByteString -> Assertion
contains needle haystack =
  assertBool ("expected the page to contain " <> BS8.unpack needle) (needle `BS.isInfixOf` haystack)

lacks :: BS.ByteString -> BS.ByteString -> Assertion
lacks needle haystack =
  assertBool ("expected the page not to contain " <> BS8.unpack needle) (not (needle `BS.isInfixOf` haystack))

expectId :: Int -> IO MigrationId
expectId n =
  maybe (assertFailure ("mkMigrationId rejected " <> show n)) pure (mkMigrationId n)
