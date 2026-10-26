{- | The lifecycle request kind (contract C-P3.2 M1, M2, §3): a separate, signed
request to change the computer's state, distinct from the read-only status
request of C-P3.1. Every operation carries the one state the page showed; the
helper re-checks it before acting.
-}
module Lockstep.Foundation.LifecycleProtocol
  ( LifecycleOp (..)
  , lifecycleOpName
  , parseLifecycleOp
  , LifecycleExpect (..)
  , lifecycleExpectName
  , parseLifecycleExpect
  , expectedFor
  , LifecycleRequest (..)
  , encodeLifecycleRequest
  , decodeLifecycleRequest
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
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
  , parseRequestId
  , requestIdText
  , signBody
  )

-- | The allowlist, version 1 (C-P3.2 M2).
data LifecycleOp
  = ServiceStart
  | ServiceStop
  | ServiceRestart
  | DatabaseStart
  | DatabaseStop
  deriving (Eq, Show, Enum, Bounded)

lifecycleOpName :: LifecycleOp -> T.Text
lifecycleOpName op =
  T.pack $
    case op of
      ServiceStart -> "service-start"
      ServiceStop -> "service-stop"
      ServiceRestart -> "service-restart"
      DatabaseStart -> "database-start"
      DatabaseStop -> "database-stop"

parseLifecycleOp :: T.Text -> Maybe LifecycleOp
parseLifecycleOp text =
  L.find ((== text) . lifecycleOpName) [minBound .. maxBound]

data LifecycleExpect
  = ExpectNotRunning
  | ExpectRunning
  | ExpectServiceNotRunning
  deriving (Eq, Show, Enum, Bounded)

lifecycleExpectName :: LifecycleExpect -> T.Text
lifecycleExpectName expect =
  T.pack $
    case expect of
      ExpectNotRunning -> "not-running"
      ExpectRunning -> "running"
      ExpectServiceNotRunning -> "service-not-running"

parseLifecycleExpect :: T.Text -> Maybe LifecycleExpect
parseLifecycleExpect text =
  L.find ((== text) . lifecycleExpectName) [minBound .. maxBound]

-- | The one state each operation must find before it acts.
expectedFor :: LifecycleOp -> LifecycleExpect
expectedFor op =
  case op of
    ServiceStart -> ExpectNotRunning
    ServiceStop -> ExpectRunning
    ServiceRestart -> ExpectRunning
    DatabaseStart -> ExpectNotRunning
    DatabaseStop -> ExpectServiceNotRunning

data LifecycleRequest
  = LifecycleRequest
  { lifecycleId :: RequestId
  , lifecycleIssued :: Integer
  , lifecycleOp :: LifecycleOp
  , lifecycleExpect :: LifecycleExpect
  }
  deriving (Eq, Show)

header :: BS.ByteString
header =
  BS8.pack "lockstep-lifecycle-request "

line :: String -> T.Text -> BS.ByteString
line key value =
  BS8.pack key <> BS8.pack " " <> TE.encodeUtf8 value <> BS8.pack "\n"

encodeLifecycleRequest :: ChannelKey -> LifecycleRequest -> BS.ByteString
encodeLifecycleRequest key request =
  signBody key $
    BS.concat
      [ header <> BS8.pack "1\n"
      , line "id" (requestIdText (lifecycleId request))
      , line "issued" (T.pack (show (lifecycleIssued request)))
      , line "op" (lifecycleOpName (lifecycleOp request))
      , line "expect" (lifecycleExpectName (lifecycleExpect request))
      ]

decodeLifecycleRequest :: ChannelKey -> BS.ByteString -> Either ProtocolError LifecycleRequest
decodeLifecycleRequest key bytes = do
  (version, rest) <- decodeSignedKind header key bytes
  case rest of
    [idLine, issuedLine, opLine, expectLine] -> do
      when (version /= BS8.pack "1") (Left BadVersion)
      rid <- lineValue "id" idLine >>= maybe (Left Malformed) Right . parseRequestId
      issued <- lineValue "issued" issuedLine >>= decimal
      op <- lineValue "op" opLine >>= maybe (Left UnknownOp) Right . parseLifecycleOp
      expect <- lineValue "expect" expectLine >>= maybe (Left BadExpect) Right . parseLifecycleExpect
      if expect == expectedFor op
        then Right (LifecycleRequest rid issued op expect)
        else Left BadExpect
    _ -> Left Malformed
