{-# LANGUAGE OverloadedStrings #-}

{- | The control-channel protocol v1 (contract C-P3.1 §4). The HMAC and digest
vectors were computed outside this code base, with @openssl dgst -sha256 -mac
HMAC@ and @shasum -a 256@ (C-P3.1 §8).
-}
module Lockstep.Foundation.ControlProtocolTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol
  ( ChannelKey
  , ControlOp (..)
  , ControlRequest (..)
  , ControlResult (..)
  , Expect (..)
  , Outcome (..)
  , ProtocolError (..)
  , decodeRequest
  , decodeResult
  , encodeRequest
  , encodeResult
  , expectValidFor
  , hmacHex
  , opName
  , parseChannelKey
  , parseExpect
  , parseOp
  , parseRequestId
  , requestIdText
  , signInDigestHex
  )

keyHex :: BS.ByteString
keyHex =
  "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

otherKeyHex :: BS.ByteString
otherKeyHex =
  "ff0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

withKey :: BS.ByteString -> (ChannelKey -> Assertion) -> Assertion
withKey hex action =
  maybe (assertFailure ("parseChannelKey refused " <> show hex)) action (parseChannelKey hex)

idText :: T.Text
idText =
  "0123456789abcdef0123456789abcdef"

sampleRequest :: IO ControlRequest
sampleRequest =
  case parseRequestId idText of
    Nothing -> assertFailure "parseRequestId refused a valid id"
    Just rid -> pure (ControlRequest rid 1761400000 OpStatus ExpectAny)

requestBody :: BS.ByteString
requestBody =
  "lockstep-control-request 1\nid 0123456789abcdef0123456789abcdef\nissued 1761400000\nop status\nexpect any\n"

requestFile :: BS.ByteString
requestFile =
  requestBody <> "mac ba80b7a4f6aa4fbeb1fac98d2658788e98d3d22651fb5d3a1fe7709a3f68d397\n"

resultBody :: BS.ByteString
resultBody =
  "lockstep-control-result 1\nid 0123456789abcdef0123456789abcdef\nop status\noutcome ok\nreason -\nstarted 1761400001\nfinished 1761400003\nfield install.present yes\nfield service.state running\ndetail \n"

resultFile :: BS.ByteString
resultFile =
  resultBody <> "mac f2b5fc863c488c5e11505b2b642fffe092daeb458d32036eda730f2e70f175c0\n"

sampleResult :: ControlResult
sampleResult =
  ControlResult
    { resultId = idText
    , resultOp = "status"
    , resultOutcome = OutcomeOk
    , resultReason = Nothing
    , resultStarted = 1761400001
    , resultFinished = 1761400003
    , resultFields = [("install.present", "yes"), ("service.state", "running")]
    , resultDetail = ""
    }

-- | Replaces the first occurrence of a line prefix's whole line.
replaceLine :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
replaceLine prefix newLine file =
  BS8.unlines [if prefix `BS.isPrefixOf` l then newLine else l | l <- BS8.lines file]

-- | Re-signs a body (everything before the mac line) with the sample key.
signed :: ChannelKey -> BS.ByteString -> BS.ByteString
signed key body =
  body <> "mac " <> BS8.pack (T.unpack (hmacHex key body)) <> "\n"

tests :: TestTree
tests =
  testGroup
    "ControlProtocol (C-P3.1 §4)"
    [ testGroup
        "keys, ids and the allowlist"
        [ testCase "a key is exactly 64 lower-case hex characters, with an optional final newline" $ do
            assertBool "valid key refused" (isJust (parseChannelKey keyHex))
            assertBool "valid key with newline refused" (isJust (parseChannelKey (keyHex <> "\n")))
            assertBool "63 characters accepted" (isNothing (parseChannelKey (BS.take 63 keyHex)))
            assertBool "65 characters accepted" (isNothing (parseChannelKey (keyHex <> "0")))
            assertBool "upper case accepted" (isNothing (parseChannelKey (BS8.map Char.toUpper keyHex)))
            assertBool "non-hex accepted" (isNothing (parseChannelKey (BS.take 63 keyHex <> "g")))
        , testCase "the key is never shown" $
            withKey keyHex $ \key ->
              assertBool "Show reveals the key" (not ("0001020304" `L.isInfixOf` show key))
        , testCase "a request id is exactly 32 lower-case hex characters" $ do
            fmap requestIdText (parseRequestId idText) @?= Just idText
            parseRequestId (T.take 31 idText) @?= Nothing
            parseRequestId (idText <> "0") @?= Nothing
            parseRequestId (T.toUpper idText) @?= Nothing
            parseRequestId "../../../../etc/passwd0000000000" @?= Nothing
            parseRequestId "0123456789abcdef0123456789abcde;" @?= Nothing
        , testCase "the allowlist is exactly status" $ do
            fmap opName [minBound .. maxBound :: ControlOp] @?= ["status"]
            parseOp "status" @?= Just OpStatus
            parseOp "Status" @?= Nothing
            parseOp "status " @?= Nothing
            parseOp "start" @?= Nothing
            parseOp "status;rm -rf /" @?= Nothing
            parseOp "" @?= Nothing
        , testCase "status accepts only expect any" $ do
            parseExpect "any" @?= Just ExpectAny
            parseExpect "running" @?= Nothing
            expectValidFor OpStatus ExpectAny @?= True
        , testCase "the sign-in file name is the SHA-256 of the token text" $
            signInDigestHex "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
              @?= "0f007385b6f9d4b7eeb2748605afe1a984a0a3bfa3f014d09e2a784ce9e5cd1a"
        ]
    , testGroup
        "requests"
        [ testCase "HMAC vector (computed with openssl)" $
            withKey keyHex $ \key ->
              hmacHex key requestBody @?= "ba80b7a4f6aa4fbeb1fac98d2658788e98d3d22651fb5d3a1fe7709a3f68d397"
        , testCase "encoding is exactly the documented file" $
            withKey keyHex $ \key -> do
              request <- sampleRequest
              encodeRequest key request @?= requestFile
        , testCase "the documented file decodes to the request" $
            withKey keyHex $ \key -> do
              request <- sampleRequest
              decodeRequest key requestFile @?= Right request
        , testCase "another key is a bad MAC" $
            withKey otherKeyHex $ \key ->
              decodeRequest key requestFile @?= Left BadMac
        , testCase "a changed field with the old MAC is a bad MAC" $
            withKey keyHex $ \key ->
              decodeRequest key (replaceLine "issued " "issued 1761400001" requestFile) @?= Left BadMac
        , testCase "a different version is refused as such" $
            withKey keyHex $ \key ->
              decodeRequest key (signed key (replaceLine "lockstep-control-request" "lockstep-control-request 2" requestBody))
                @?= Left BadVersion
        , testCase "an unknown operation, correctly signed, is refused" $
            withKey keyHex $ \key ->
              decodeRequest key (signed key (replaceLine "op " "op start" requestBody)) @?= Left UnknownOp
        , testCase "a bad expect, correctly signed, is refused" $
            withKey keyHex $ \key ->
              decodeRequest key (signed key (replaceLine "expect " "expect running" requestBody)) @?= Left BadExpect
        , testCase "malformed requests are refused, never partly read" $
            withKey keyHex $ \key ->
              traverse_
                ( \(label, body) ->
                    case decodeRequest key (signed key body) of
                      Left Malformed -> pure ()
                      other -> assertFailure (label <> ": expected Malformed, got " <> show other)
                )
                malformedRequests
        , testCase "a missing or extra mac line is malformed" $
            withKey keyHex $ \key -> do
              decodeRequest key requestBody @?= Left Malformed
              decodeRequest key (requestFile <> "mac " <> BS.replicate 64 0x30 <> "\n") @?= Left Malformed
        , testCase "more than 1024 bytes is too large" $
            withKey keyHex $ \key ->
              decodeRequest key (requestFile <> BS.replicate 1024 0x20) @?= Left TooLarge
        ]
    , testGroup
        "results"
        [ testCase "HMAC vector (computed with openssl)" $
            withKey keyHex $ \key ->
              hmacHex key resultBody @?= "f2b5fc863c488c5e11505b2b642fffe092daeb458d32036eda730f2e70f175c0"
        , testCase "encoding is exactly the documented file" $
            withKey keyHex $ \key ->
              encodeResult key sampleResult @?= resultFile
        , testCase "the documented file decodes to the result" $
            withKey keyHex $ \key ->
              decodeResult key resultFile @?= Right sampleResult
        , testCase "another key is a bad MAC" $
            withKey otherKeyHex $ \key ->
              decodeResult key resultFile @?= Left BadMac
        , testCase "every outcome and a reason round-trip" $
            withKey keyHex $ \key ->
              traverse_
                ( \o -> do
                    let
                      r = sampleResult {resultOutcome = o, resultReason = Just "bad-mac", resultFields = [], resultDetail = "x y"}
                    decodeResult key (encodeResult key r) @?= Right r
                )
                [OutcomeOk, OutcomeRefused, OutcomeFailed, OutcomeTimedOut, OutcomeInterrupted]
        , testCase "a field value outside [A-Za-z0-9._:-]{1,80} is malformed" $
            withKey keyHex $ \key ->
              traverse_
                ( \v ->
                    assertBool ("accepted field value " <> show v) $
                      isLeft (decodeResult key (signed key (replaceLine "field service.state" ("field service.state " <> v) resultBody)))
                )
                ["<script>", "a b", "", BS.replicate 81 0x61, "x\"y", "x'y"]
        , testCase "a detail with control characters or over 300 characters is malformed" $
            withKey keyHex $ \key -> do
              assertBool "accepted a tab" $
                isLeft (decodeResult key (signed key (replaceLine "detail" "detail a\tb" resultBody)))
              assertBool "accepted 301 characters" $
                isLeft (decodeResult key (signed key (replaceLine "detail" ("detail " <> BS.replicate 301 0x61) resultBody)))
        , testCase "markup in detail is kept as plain text (escaping is the renderer's job)" $
            withKey keyHex $ \key -> do
              let
                r = sampleResult {resultDetail = "<img src=x onerror=alert(1)>"}
              fmap resultDetail (decodeResult key (encodeResult key r)) @?= Right "<img src=x onerror=alert(1)>"
        ]
    ]

malformedRequests :: [(String, BS.ByteString)]
malformedRequests =
  [ ("lines out of order", "lockstep-control-request 1\nissued 1761400000\nid 0123456789abcdef0123456789abcdef\nop status\nexpect any\n")
  , ("missing expect", "lockstep-control-request 1\nid 0123456789abcdef0123456789abcdef\nissued 1761400000\nop status\n")
  , ("extra line", requestBody <> "note hello\n")
  , ("bad id", replaceLine "id " "id 0123" requestBody)
  , ("non-numeric issued", replaceLine "issued " "issued soon" requestBody)
  , ("negative issued", replaceLine "issued " "issued -5" requestBody)
  , ("double space", replaceLine "op " "op  status" requestBody)
  , ("carriage return", replaceLine "op " "op status\r" requestBody)
  , ("NUL byte", replaceLine "op " "op stat\NULus" requestBody)
  , ("empty", "")
  ]
