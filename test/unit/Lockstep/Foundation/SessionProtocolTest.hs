{-# LANGUAGE OverloadedStrings #-}

{- | The session request kind for the hand-over to the application (contract
C-P3.4 A3). The HMAC vector was computed with @openssl dgst -sha256 -mac HMAC@.
-}
module Lockstep.Foundation.SessionProtocolTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))

import Lockstep.Foundation.ControlProtocol (ChannelKey, ProtocolError (..), decodeRequest, hmacHex, parseChannelKey, parseOp, parseRequestId)
import Lockstep.Foundation.InstallProtocol (decodeInstallRequest, parseInstallOp)
import Lockstep.Foundation.LifecycleProtocol (decodeLifecycleRequest, parseLifecycleOp)
import Lockstep.Foundation.SessionProtocol
  ( SessionOp (..)
  , SessionRequest (..)
  , decodeSessionRequest
  , encodeSessionRequest
  , parseSessionOp
  , sessionOpName
  )

keyHex :: BS.ByteString
keyHex =
  "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

withKey :: (ChannelKey -> Assertion) -> Assertion
withKey action =
  maybe (assertFailure "parseChannelKey refused the test key") action (parseChannelKey keyHex)

body :: BS.ByteString
body =
  "lockstep-session-request 1\nid 0123456789abcdef0123456789abcdef\nissued 1761400000\nop open-application\nexpect service-running\n"

file :: BS.ByteString
file =
  body <> "mac 74bde5f4151417aed27eb621041d0c96aa9a996d26b6265f651e076f9424b7f1\n"

signed :: ChannelKey -> BS.ByteString -> BS.ByteString
signed key b =
  b <> "mac " <> BS8.pack (T.unpack (hmacHex key b)) <> "\n"

replaceLine :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
replaceLine prefix newLine bytes =
  BS8.unlines [if prefix `BS.isPrefixOf` l then newLine else l | l <- BS8.lines bytes]

tests :: TestTree
tests =
  testGroup
    "SessionProtocol (C-P3.4 A3)"
    [ testCase "the allowlist is exactly open-application" $
        fmap sessionOpName [minBound .. maxBound :: SessionOp] @?= ["open-application"]
    , testCase "names are exact and the other kinds refuse it" $ do
        parseSessionOp "open-application" @?= Just OpenApplication
        parseSessionOp "open-application " @?= Nothing
        parseSessionOp "sign-in" @?= Nothing
        parseOp "open-application" @?= Nothing
        parseLifecycleOp "open-application" @?= Nothing
        parseInstallOp "open-application" @?= Nothing
    , testCase "HMAC vector (computed with openssl)" $
        withKey $ \key ->
          hmacHex key body @?= "74bde5f4151417aed27eb621041d0c96aa9a996d26b6265f651e076f9424b7f1"
    , testCase "encoding is exactly the documented file, and it decodes back" $
        withKey $ \key ->
          case parseRequestId "0123456789abcdef0123456789abcdef" of
            Nothing -> assertFailure "id"
            Just rid -> do
              let
                r = SessionRequest rid 1761400000 OpenApplication
              encodeSessionRequest key r @?= file
              decodeSessionRequest key file @?= Right r
    , testCase "a wrong expectation, unknown operation, bad MAC and other version are refused" $
        withKey $ \key -> do
          decodeSessionRequest key (signed key (replaceLine "expect " "expect any" body)) @?= Left BadExpect
          decodeSessionRequest key (signed key (replaceLine "op " "op sign-in-as admin" body)) @?= Left UnknownOp
          decodeSessionRequest key (replaceLine "issued " "issued 1" file) @?= Left BadMac
          decodeSessionRequest key (signed key (replaceLine "lockstep-session-request" "lockstep-session-request 2" body)) @?= Left BadVersion
    , testCase "kinds do not mix" $
        withKey $ \key -> do
          decodeRequest key file @?= Left Malformed
          decodeLifecycleRequest key file @?= Left Malformed
          decodeInstallRequest key file @?= Left Malformed
    , testCase "malformed and oversized files are refused" $
        withKey $ \key -> do
          decodeSessionRequest key (signed key (body <> "port 1\n")) @?= Left Malformed
          decodeSessionRequest key body @?= Left Malformed
          decodeSessionRequest key (file <> BS.replicate 1100 0x20) @?= Left TooLarge
    ]
