{- | The runner channel between the Lockstep service and the host helper,
protocol v1 (contract C-P4.2 R3; DG-17 D-17.1(a)). A request names an
operation from a fixed list, a run directory (32 hex characters) and the
SHA-256 of that run's argument vector; the helper decides everything else.
Results use the control channel's signed result form (C-P3.1 §4) with the
runner key.
-}
module Lockstep.Foundation.RunnerProtocol
  ( RunProfile (..)
  , RunnerOp (..)
  , runnerOpName
  , RunnerRequest (..)
  , encodeRunnerRequest
  , RunnerResult (..)
  , decodeRunnerResult
  , resultField
  , isRunName
  ) where

import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Foundation.ControlProtocol
  ( ChannelKey
  , ProtocolError (..)
  , RequestId
  , decimal
  , decodeSignedKind
  , lineValue
  , requestIdText
  , signBody
  )

-- | What a run may do to its tree (the helper's fixed table).
data RunProfile
  = ProfileReadOnly
  | ProfileWrite
  | ProfileVerify
  deriving (Eq, Show)

data RunnerOp
  = RunOp RunProfile
  | CancelOp
  deriving (Eq, Show)

runnerOpName :: RunnerOp -> T.Text
runnerOpName op =
  T.pack $
    case op of
      RunOp ProfileReadOnly -> "run-readonly"
      RunOp ProfileWrite -> "run-write"
      RunOp ProfileVerify -> "run-verify"
      CancelOp -> "cancel-run"

data RunnerRequest
  = RunnerRequest
  { runnerRequestId :: RequestId
  , runnerIssued :: Integer
  , runnerOp :: RunnerOp
  , runnerRun :: T.Text
  -- ^ the run directory's name, 32 lower-case hex characters
  , runnerArgvDigest :: Maybe T.Text
  -- ^ SHA-256 of the argument vector file; none for a cancellation
  }
  deriving (Eq, Show)

isRunName :: T.Text -> Bool
isRunName name =
  T.length name == 32 && T.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) name

encodeRunnerRequest :: ChannelKey -> RunnerRequest -> BS.ByteString
encodeRunnerRequest key request =
  signBody key $
    BS.concat
      [ BS8.pack "lockstep-runner-request 1\n"
      , line "id" (requestIdText (runnerRequestId request))
      , line "issued" (T.pack (show (runnerIssued request)))
      , line "op" (runnerOpName (runnerOp request))
      , line "expect" (T.pack "run-" <> runnerRun request)
      , line "argv" (fromMaybe (T.pack "none") (runnerArgvDigest request))
      ]

line :: String -> T.Text -> BS.ByteString
line key value =
  BS8.pack key <> BS8.pack " " <> TE.encodeUtf8 value <> BS8.pack "\n"

-- | A signed result: the outcome, the reason (@-@ when none) and the @field@ lines.
data RunnerResult
  = RunnerResult
  { runnerResultId :: T.Text
  , runnerResultOp :: T.Text
  , runnerOutcome :: T.Text
  , runnerReason :: T.Text
  , runnerStarted :: Integer
  , runnerFinished :: Integer
  , runnerFields :: [(T.Text, T.Text)]
  }
  deriving (Eq, Show)

decodeRunnerResult :: ChannelKey -> BS.ByteString -> Either ProtocolError RunnerResult
decodeRunnerResult key bytes = do
  (version, ls) <- decodeSignedKind (BS8.pack "lockstep-control-result ") key bytes
  when (version /= BS8.pack "1") (Left BadVersion)
  case ls of
    idLine : opLine : outcomeLine : reasonLine : startedLine : finishedLine : rest
      | Just (fieldLines, detailLine) <- L.unsnoc rest -> do
          rid <- lineValue "id" idLine
          op <- lineValue "op" opLine
          outcome <- lineValue "outcome" outcomeLine
          reason <- lineValue "reason" reasonLine
          started <- lineValue "started" startedLine >>= decimal
          finished <- lineValue "finished" finishedLine >>= decimal
          unless (BS8.pack "detail" `BS.isPrefixOf` detailLine) (Left Malformed)
          fields <- traverse fieldOf fieldLines
          Right (RunnerResult rid op outcome reason started finished fields)
    _ -> Left Malformed
 where
  fieldOf l = do
    value <- lineValue "field" l
    case T.breakOn (T.pack " ") value of
      (name, rest) | not (T.null name) && not (T.null rest) -> Right (name, T.drop 1 rest)
      _ -> Left Malformed

resultField :: T.Text -> RunnerResult -> Maybe T.Text
resultField name result =
  L.lookup name (runnerFields result)
