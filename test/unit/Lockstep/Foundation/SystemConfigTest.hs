{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Foundation.SystemConfigTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.Config (portNumber)
import Lockstep.Foundation.SystemConfig
  ( ConfigError (..)
  , DatabaseConfig (..)
  , SystemConfig (..)
  , decodeSystemConfig
  , revealSecret
  )

tests :: TestTree
tests =
  testGroup
    "SystemConfig"
    [ testCase "a valid configuration decodes" $ do
        config <- expectConfig validConfig
        let
          db = databaseConfig config
        dbHost db @?= "lockstep-postgres"
        portNumber (dbPort db) @?= 5432
        dbName db @?= "lockstep"
        dbUser db @?= "lockstep"
        revealSecret (dbPassword db) @?= "s3cret-value"
    , testCase "a missing database block is invalid" $
        expectInvalid "{}"
    , testCase "a missing database field is invalid" $
        expectInvalid
          "{\"database\":{\"host\":\"h\",\"port\":5432,\"name\":\"n\",\"username\":\"u\"}}"
    , testCase "a leftover rollbar block is refused as an unknown key" $
        decodeSystemConfig
          "{\"database\":{\"host\":\"h\",\"port\":5432,\"name\":\"n\",\"username\":\"u\",\"password\":\"p\"},\"rollbar\":{\"token\":\"t\"}}"
          `expectLeft` ConfigUnknownKeys ["rollbar"]
    , testCase "an unknown key inside the database block is refused" $
        decodeSystemConfig
          "{\"database\":{\"host\":\"h\",\"port\":5432,\"name\":\"n\",\"username\":\"u\",\"password\":\"p\",\"sslmode\":\"off\"}}"
          `expectLeft` ConfigUnknownKeys ["sslmode"]
    , testCase "port 0 is invalid" $
        expectInvalid
          "{\"database\":{\"host\":\"h\",\"port\":0,\"name\":\"n\",\"username\":\"u\",\"password\":\"p\"}}"
    , testCase "port 70000 is invalid" $
        expectInvalid
          "{\"database\":{\"host\":\"h\",\"port\":70000,\"name\":\"n\",\"username\":\"u\",\"password\":\"p\"}}"
    , testCase "showing a decoded configuration never reveals the password" $ do
        config <- expectConfig validConfig
        assertBool
          "password visible in show output"
          (not ("s3cret-value" `L.isInfixOf` show (databaseConfig config)))
    ]

validConfig :: LBS.ByteString
validConfig =
  "{\"database\":{\"host\":\"lockstep-postgres\",\"port\":5432,\"name\":\"lockstep\",\"username\":\"lockstep\",\"password\":\"s3cret-value\"}}"

expectConfig :: LBS.ByteString -> IO SystemConfig
expectConfig bytes =
  case decodeSystemConfig bytes of
    Left err -> assertFailure ("expected a valid config, got " <> show err)
    Right config -> pure config

expectInvalid :: LBS.ByteString -> Assertion
expectInvalid bytes =
  case decodeSystemConfig bytes of
    Left (ConfigInvalid _) -> pure ()
    Left other -> assertFailure ("expected ConfigInvalid, got " <> show other)
    Right _ -> assertFailure "expected ConfigInvalid, got a config"

expectLeft :: Either ConfigError SystemConfig -> ConfigError -> Assertion
expectLeft result expected =
  case result of
    Left err -> err @?= expected
    Right _ -> assertFailure ("expected " <> show expected <> ", got a config")
