{-# LANGUAGE OverloadedStrings #-}

{- | The lifecycle request kind (contract C-P3.2 M1, M2, §3). The HMAC vector was
computed outside this code base with @openssl dgst -sha256 -mac HMAC@.
-}
module Lockstep.Foundation.LifecycleProtocolTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol
  ( ChannelKey
  , ProtocolError (..)
  , decodeRequest
  , hmacHex
  , parseChannelKey
  , parseOp
  , parseRequestId
  )
import Lockstep.Foundation.LifecycleProtocol
  ( LifecycleExpect (..)
  , LifecycleOp (..)
  , LifecycleRequest (..)
  , decodeLifecycleRequest
  , encodeLifecycleRequest
  , expectedFor
  , lifecycleExpectName
  , lifecycleOpName
  , parseLifecycleExpect
  , parseLifecycleOp
  )

keyHex :: BS.ByteString
keyHex =
  "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

withKey :: (ChannelKey -> Assertion) -> Assertion
withKey action =
  maybe (assertFailure "parseChannelKey refused the test key") action (parseChannelKey keyHex)

body :: BS.ByteString
body =
  "lockstep-lifecycle-request 1\nid 0123456789abcdef0123456789abcdef\nissued 1761400000\nop service-stop\nexpect running\n"

file :: BS.ByteString
file =
  body <> "mac 31bc02a8908b4a1dc05ff338c191770556a9aa273065b37ec126bd2bc000832d\n"

sample :: IO LifecycleRequest
sample =
  case parseRequestId "0123456789abcdef0123456789abcdef" of
    Nothing -> assertFailure "parseRequestId refused a valid id"
    Just rid -> pure (LifecycleRequest rid 1761400000 ServiceStop ExpectRunning)

signed :: ChannelKey -> BS.ByteString -> BS.ByteString
signed key b =
  b <> "mac " <> BS8.pack (T.unpack (hmacHex key b)) <> "\n"

replaceLine :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
replaceLine prefix newLine bytes =
  BS8.unlines [if prefix `BS.isPrefixOf` l then newLine else l | l <- BS8.lines bytes]

tests :: TestTree
tests =
  testGroup
    "LifecycleProtocol (C-P3.2)"
    [ testCase "the allowlist is exactly the five lifecycle operations" $
        fmap lifecycleOpName [minBound .. maxBound :: LifecycleOp]
          @?= ["service-start", "service-stop", "service-restart", "database-start", "database-stop"]
    , testCase "each operation has exactly one expected state" $ do
        fmap (lifecycleExpectName . expectedFor) [minBound .. maxBound :: LifecycleOp]
          @?= ["not-running", "running", "running", "not-running", "service-not-running"]
        parseLifecycleExpect "running" @?= Just ExpectRunning
        parseLifecycleExpect "stopped" @?= Nothing
    , testCase "names are exact" $ do
        parseLifecycleOp "service-stop" @?= Just ServiceStop
        parseLifecycleOp "stop" @?= Nothing
        parseLifecycleOp "start" @?= Nothing
        parseLifecycleOp "Service-Stop" @?= Nothing
        parseLifecycleOp "service-stop;reboot" @?= Nothing
        parseLifecycleOp "status" @?= Nothing
    , testCase "the status channel still refuses lifecycle names" $
        traverse_ (\op -> parseOp (lifecycleOpName op) @?= Nothing) [minBound .. maxBound :: LifecycleOp]
    , testCase "HMAC vector (computed with openssl)" $
        withKey $ \key ->
          hmacHex key body @?= "31bc02a8908b4a1dc05ff338c191770556a9aa273065b37ec126bd2bc000832d"
    , testCase "encoding is exactly the documented file, and it decodes back" $
        withKey $ \key -> do
          r <- sample
          encodeLifecycleRequest key r @?= file
          decodeLifecycleRequest key file @?= Right r
    , testCase "another key is a bad MAC" $
        case parseChannelKey "ff0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" of
          Nothing -> assertFailure "key"
          Just other -> decodeLifecycleRequest other file @?= Left BadMac
    , testCase "an operation with the wrong expectation is refused, even when signed" $
        withKey $ \key -> do
          decodeLifecycleRequest key (signed key (replaceLine "expect " "expect not-running" body)) @?= Left BadExpect
          decodeLifecycleRequest key (signed key (replaceLine "op " "op database-stop" body)) @?= Left BadExpect
    , testCase "unknown operations, signed, are refused" $
        withKey $ \key ->
          traverse_
            (\op -> decodeLifecycleRequest key (signed key (replaceLine "op " ("op " <> op) body)) @?= Left UnknownOp)
            ["status", "start", "service-stop now", "$(reboot)"]
    , testCase "a status request is not a lifecycle request, and the reverse" $
        withKey $ \key -> do
          let
            statusBody = "lockstep-control-request 1\nid 0123456789abcdef0123456789abcdef\nissued 1761400000\nop status\nexpect any\n"
          decodeLifecycleRequest key (signed key statusBody) @?= Left Malformed
          decodeRequest key file @?= Left Malformed
    , testCase "another version is refused as such" $
        withKey $ \key ->
          decodeLifecycleRequest key (signed key (replaceLine "lockstep-lifecycle-request" "lockstep-lifecycle-request 2" body)) @?= Left BadVersion
    , testCase "malformed forms are refused" $
        withKey $ \key -> do
          traverse_
            ( \(label, b) ->
                case decodeLifecycleRequest key (signed key b) of
                  Left Malformed -> pure ()
                  other -> assertFailure (label <> ": " <> show other)
            )
            [ ("extra line", body <> "port 9999\n")
            , ("missing expect", BS8.unlines (L.take 4 (BS8.lines body)))
            , ("double space", replaceLine "op " "op  service-stop" body)
            , ("bad id", replaceLine "id " "id ../../x" body)
            ]
          decodeLifecycleRequest key body @?= Left Malformed
          decodeLifecycleRequest key (file <> BS.replicate 1100 0x20) @?= Left TooLarge
    ]
