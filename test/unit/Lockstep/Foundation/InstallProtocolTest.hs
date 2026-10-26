{-# LANGUAGE OverloadedStrings #-}

{- | The install request kind (contract C-P3.3 U1). The HMAC vector was computed
outside this code base with @openssl dgst -sha256 -mac HMAC@.
-}
module Lockstep.Foundation.InstallProtocolTest
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

import Lockstep.Foundation.ControlProtocol (ChannelKey, ProtocolError (..), decodeRequest, hmacHex, parseChannelKey, parseOp, parseRequestId)
import Lockstep.Foundation.InstallProtocol
  ( InstallExpect (..)
  , InstallOp (..)
  , InstallRequest (..)
  , decodeInstallRequest
  , encodeInstallRequest
  , installExpectText
  , installOpName
  , parseInstallExpect
  , parseInstallOp
  , validFor
  )
import Lockstep.Foundation.LifecycleProtocol (decodeLifecycleRequest, parseLifecycleOp)

keyHex :: BS.ByteString
keyHex =
  "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

withKey :: (ChannelKey -> Assertion) -> Assertion
withKey action =
  maybe (assertFailure "parseChannelKey refused the test key") action (parseChannelKey keyHex)

body :: BS.ByteString
body =
  "lockstep-install-request 1\nid 0123456789abcdef0123456789abcdef\nissued 1761400000\nop apply-candidate\nexpect candidate-0011223344556677\n"

file :: BS.ByteString
file =
  body <> "mac abbb6487ed8ce46c152a9a4f8385e0f3d6e38047bbcf9b7fa67fbd2ba63fcfcf\n"

signed :: ChannelKey -> BS.ByteString -> BS.ByteString
signed key b =
  b <> "mac " <> BS8.pack (T.unpack (hmacHex key b)) <> "\n"

replaceLine :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
replaceLine prefix newLine bytes =
  BS8.unlines [if prefix `BS.isPrefixOf` l then newLine else l | l <- BS8.lines bytes]

tests :: TestTree
tests =
  testGroup
    "InstallProtocol (C-P3.3 U1)"
    [ testCase "the allowlist is exactly prepare, apply and restore" $
        fmap installOpName [minBound .. maxBound :: InstallOp] @?= ["prepare-candidate", "apply-candidate", "restore-previous"]
    , testCase "expectations are parsed exactly" $ do
        parseInstallExpect "candidate-none" @?= Just CandidateNone
        parseInstallExpect "candidate-0011223344556677" @?= Just (CandidateDigest "0011223344556677")
        parseInstallExpect "recovery-0123456789abcdef0123456789abcdef" @?= Just (RecoveryOf "0123456789abcdef0123456789abcdef")
        traverse_
          (\t -> parseInstallExpect t @?= Nothing)
          ["candidate-001122334455667", "candidate-00112233445566778", "candidate-00112233445566GG", "candidate-", "recovery-0123", "candidate-none ", "any", "../candidate"]
        fmap installExpectText (parseInstallExpect "candidate-0011223344556677") @?= Just "candidate-0011223344556677"
    , testCase "each operation accepts only its own kind of expectation" $ do
        validFor PrepareCandidate CandidateNone @?= True
        validFor PrepareCandidate (CandidateDigest "0011223344556677") @?= True
        validFor ApplyCandidate (CandidateDigest "0011223344556677") @?= True
        validFor ApplyCandidate CandidateNone @?= False
        validFor RestorePrevious (RecoveryOf "0123456789abcdef0123456789abcdef") @?= True
        validFor RestorePrevious (CandidateDigest "0011223344556677") @?= False
        validFor ApplyCandidate (RecoveryOf "0123456789abcdef0123456789abcdef") @?= False
    , testCase "the other kinds still refuse install names" $
        traverse_
          ( \op -> do
              parseOp (installOpName op) @?= Nothing
              parseLifecycleOp (installOpName op) @?= Nothing
          )
          [minBound .. maxBound :: InstallOp]
    , testCase "unknown names are refused" $
        traverse_ (\t -> parseInstallOp t @?= Nothing) ["install", "upgrade", "apply-candidate ", "Apply-Candidate", "status", "service-start"]
    , testCase "HMAC vector (computed with openssl)" $
        withKey $ \key ->
          hmacHex key body @?= "abbb6487ed8ce46c152a9a4f8385e0f3d6e38047bbcf9b7fa67fbd2ba63fcfcf"
    , testCase "encoding is exactly the documented file, and it decodes back" $
        withKey $ \key ->
          case parseRequestId "0123456789abcdef0123456789abcdef" of
            Nothing -> assertFailure "id"
            Just rid -> do
              let
                r = InstallRequest rid 1761400000 ApplyCandidate (CandidateDigest "0011223344556677")
              encodeInstallRequest key r @?= file
              decodeInstallRequest key file @?= Right r
    , testCase "another key is a bad MAC" $
        case parseChannelKey "ff0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" of
          Nothing -> assertFailure "key"
          Just other -> decodeInstallRequest other file @?= Left BadMac
    , testCase "a mismatched expectation, unknown operation and other version are refused, even when signed" $
        withKey $ \key -> do
          decodeInstallRequest key (signed key (replaceLine "expect " "expect candidate-none" body)) @?= Left BadExpect
          decodeInstallRequest key (signed key (replaceLine "expect " "expect /etc/passwd" body)) @?= Left BadExpect
          decodeInstallRequest key (signed key (replaceLine "op " "op install-from /tmp/x" body)) @?= Left UnknownOp
          decodeInstallRequest key (signed key (replaceLine "lockstep-install-request" "lockstep-install-request 2" body)) @?= Left BadVersion
    , testCase "kinds do not mix" $
        withKey $ \key -> do
          decodeRequest key file @?= Left Malformed
          decodeLifecycleRequest key file @?= Left Malformed
          decodeInstallRequest key (signed key (replaceLine "lockstep-install-request" "lockstep-lifecycle-request 1" body)) @?= Left Malformed
    , testCase "malformed forms are refused" $
        withKey $ \key -> do
          traverse_
            ( \(label, b) ->
                case decodeInstallRequest key (signed key b) of
                  Left Malformed -> pure ()
                  other -> assertFailure (label <> ": " <> show other)
            )
            [ ("extra line", body <> "path /tmp/x\n")
            , ("missing expect", BS8.unlines (L.take 4 (BS8.lines body)))
            , ("bad id", replaceLine "id " "id x" body)
            ]
          decodeInstallRequest key (file <> BS.replicate 1100 0x20) @?= Left TooLarge
    ]
