{-# LANGUAGE OverloadedStrings #-}

{- | The runner channel's request and result forms (contract C-P4.2 R3, R4).
The MACs below were computed independently with
@openssl dgst -sha256 -mac HMAC -macopt hexkey:…@ over the exact bodies.
-}
module Lockstep.Foundation.RunnerProtocolTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Effects.HelperRunner (HelperFailure (..), interpretResult)
import Lockstep.Effects.Process (RunResult (..))
import Lockstep.Foundation.ControlProtocol (ChannelKey, ProtocolError (..), parseChannelKey, parseRequestId)
import Lockstep.Foundation.RunnerProtocol
  ( RunProfile (..)
  , RunnerOp (..)
  , RunnerRequest (..)
  , RunnerResult (..)
  , decodeRunnerResult
  , encodeRunnerRequest
  , isRunName
  , runnerOpName
  )
import Lockstep.Kernel.Runner (RunOutcome (..), Stream (..))

tests :: TestTree
tests =
  testGroup
    "C-P4.2 runner channel"
    [ testCase "a run request is exactly the helper's seven lines, signed" requestBytes
    , testCase "the operation names are the helper's fixed list" opNames
    , testCase "a signed result decodes; a changed byte is refused" resultBytes
    , testCase "a result becomes the run's outcome only with matching stream digests" interpreted
    , testCase "refused and interrupted results are failures, never outcomes" failures
    , testCase "too much output names the stream that passed its limit" outputLimit
    , testCase "a run name is 32 lower-case hex characters" runNames
    ]

keyOf :: IO ChannelKey
keyOf =
  maybe (assertFailure "the test key does not parse") pure (parseChannelKey "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")

requestBody :: BS.ByteString
requestBody =
  BS8.pack $
    "lockstep-runner-request 1\n"
      <> "id 0123456789abcdef0123456789abcdef\n"
      <> "issued 1700000000\n"
      <> "op run-verify\n"
      <> "expect run-fedcba9876543210fedcba9876543210\n"
      <> "argv 2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae\n"

requestBytes :: IO ()
requestBytes = do
  key <- keyOf
  rid <- maybe (assertFailure "the test request id does not parse") pure (parseRequestId "0123456789abcdef0123456789abcdef")
  encodeRunnerRequest
    key
    RunnerRequest
      { runnerRequestId = rid
      , runnerIssued = 1700000000
      , runnerOp = RunOp ProfileVerify
      , runnerRun = "fedcba9876543210fedcba9876543210"
      , runnerArgvDigest = Just "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
      }
    @?= requestBody <> "mac 4fe0d091fc4e6a6306c03aa42698b3706d7106721bcfa91cee4847d8d84a414f\n"

opNames :: IO ()
opNames =
  fmap runnerOpName [RunOp ProfileReadOnly, RunOp ProfileWrite, RunOp ProfileVerify, CancelOp]
    @?= ["run-readonly", "run-write", "run-verify", "cancel-run"]

resultBody :: BS.ByteString
resultBody =
  BS8.pack $
    "lockstep-control-result 1\n"
      <> "id 0123456789abcdef0123456789abcdef\n"
      <> "op run-verify\n"
      <> "outcome exited\n"
      <> "reason -\n"
      <> "started 1700000000\n"
      <> "finished 1700000002\n"
      <> "field exit 3\n"
      <> "field run fedcba9876543210fedcba9876543210\n"
      <> "field image sha256:stub\n"
      <> "field stdout-bytes 4\n"
      <> "field stderr-bytes 0\n"
      <> "field stdout-sha256 b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c\n"
      <> "field stderr-sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n"
      <> "field limits 600 8388608 2097152\n"
      <> "detail \n"

signedResult :: BS.ByteString
signedResult =
  resultBody <> "mac f4266b36c58eb5e76b078200b6004178b1897d266adea75995079597a4140977\n"

decodedOf :: IO RunnerResult
decodedOf = do
  key <- keyOf
  either (\e -> assertFailure ("the signed result does not decode: " <> show e)) pure (decodeRunnerResult key signedResult)

resultBytes :: IO ()
resultBytes = do
  key <- keyOf
  fmap runnerOutcome (decodeRunnerResult key signedResult) @?= Right "exited"
  fmap runnerFields (decodeRunnerResult key signedResult)
    @?= Right
      [ ("exit", "3")
      , ("run", "fedcba9876543210fedcba9876543210")
      , ("image", "sha256:stub")
      , ("stdout-bytes", "4")
      , ("stderr-bytes", "0")
      , ("stdout-sha256", "b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c")
      , ("stderr-sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
      , ("limits", "600 8388608 2097152")
      ]
  fmap (\r -> (runnerStarted r, runnerFinished r)) (decodeRunnerResult key signedResult) @?= Right (1700000000, 1700000002)
  fmap runnerOutcome (decodeRunnerResult key (BS8.map (\c -> if c == '3' then '4' else c) signedResult)) @?= Left BadMac

interpreted :: IO ()
interpreted = do
  decoded <- decodedOf
  interpretResult decoded "foo\n" ""
    @?= Right
      RunResult
        { resultOutcome = Exited 3
        , resultStdout = "foo\n"
        , resultStderr = ""
        , resultStdoutBytes = 4
        , resultStderrBytes = 0
        , resultMillis = 2000
        , resultDescendantsKilled = False
        }
  interpretResult decoded "bar\n" "" @?= Left (HelperResultInvalid "output-digest")
  interpretResult decoded "foo\n" "x" @?= Left (HelperResultInvalid "output-digest")
  interpretResult decoded {runnerOutcome = "succeeded"} "foo\n" "" @?= Left (HelperResultInvalid "outcome")
  interpretResult decoded {runnerFields = []} "foo\n" "" @?= Left (HelperResultInvalid "exit")
  fmap resultOutcome (interpretResult decoded {runnerOutcome = "timed-out"} "foo\n" "") @?= Right TimedOut
  fmap resultOutcome (interpretResult decoded {runnerOutcome = "cancelled"} "foo\n" "") @?= Right Cancelled
  fmap resultOutcome (interpretResult decoded {runnerOutcome = "launch-failed"} "foo\n" "") @?= Right (LaunchFailed "container")

failures :: IO ()
failures = do
  decoded <- decodedOf
  interpretResult decoded {runnerOutcome = "refused", runnerReason = "busy"} "foo\n" "" @?= Left (HelperRefused "busy")
  interpretResult decoded {runnerOutcome = "interrupted"} "foo\n" "" @?= Left HelperInterrupted

outputLimit :: IO ()
outputLimit = do
  decoded <- decodedOf
  let
    with out err =
      decoded
        { runnerOutcome = "output-limit"
        , runnerFields =
            [ ("stdout-bytes", out)
            , ("stderr-bytes", err)
            , ("stdout-sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
            , ("stderr-sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
            , ("limits", "6 65536 16384")
            ]
        }
  fmap resultOutcome (interpretResult (with "65537" "0") "" "") @?= Right (OutputLimit Stdout)
  fmap resultOutcome (interpretResult (with "10" "16385") "" "") @?= Right (OutputLimit Stderr)
  fmap resultOutcome (interpretResult (with "10" "16385") {runnerFields = []} "" "") @?= Left (HelperResultInvalid "stdout-bytes")

runNames :: IO ()
runNames =
  fmap isRunName ["fedcba9876543210fedcba9876543210", "FEDCBA9876543210FEDCBA9876543210", "../..", "", T.replicate 33 "a"]
    @?= [True, False, False, False, False]
