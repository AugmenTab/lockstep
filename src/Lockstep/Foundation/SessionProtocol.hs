{- | The session request kind (contract C-P3.4 A3): the control pane asks the
helper for a one-time application sign-in token. The only operation is
@open-application@, which requires the service to be running.
-}
module Lockstep.Foundation.SessionProtocol
  ( SessionOp (..)
  , sessionOpName
  , parseSessionOp
  , SessionRequest (..)
  , encodeSessionRequest
  , decodeSessionRequest
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

data SessionOp
  = OpenApplication
  deriving (Eq, Show, Enum, Bounded)

sessionOpName :: SessionOp -> T.Text
sessionOpName op =
  case op of
    OpenApplication -> T.pack "open-application"

parseSessionOp :: T.Text -> Maybe SessionOp
parseSessionOp text =
  L.find ((== text) . sessionOpName) [minBound .. maxBound]

expectation :: T.Text
expectation =
  T.pack "service-running"

data SessionRequest
  = SessionRequest
  { sessionId :: RequestId
  , sessionIssued :: Integer
  , sessionOp :: SessionOp
  }
  deriving (Eq, Show)

header :: BS.ByteString
header =
  BS8.pack "lockstep-session-request "

line :: String -> T.Text -> BS.ByteString
line key value =
  BS8.pack key <> BS8.pack " " <> TE.encodeUtf8 value <> BS8.pack "\n"

encodeSessionRequest :: ChannelKey -> SessionRequest -> BS.ByteString
encodeSessionRequest key request =
  signBody key $
    BS.concat
      [ header <> BS8.pack "1\n"
      , line "id" (requestIdText (sessionId request))
      , line "issued" (T.pack (show (sessionIssued request)))
      , line "op" (sessionOpName (sessionOp request))
      , line "expect" expectation
      ]

decodeSessionRequest :: ChannelKey -> BS.ByteString -> Either ProtocolError SessionRequest
decodeSessionRequest key bytes = do
  (version, rest) <- decodeSignedKind header key bytes
  case rest of
    [idLine, issuedLine, opLine, expectLine] -> do
      when (version /= BS8.pack "1") (Left BadVersion)
      rid <- lineValue "id" idLine >>= maybe (Left Malformed) Right . parseRequestId
      issued <- lineValue "issued" issuedLine >>= decimal
      op <- lineValue "op" opLine >>= maybe (Left UnknownOp) Right . parseSessionOp
      expect <- lineValue "expect" expectLine
      if expect == expectation
        then Right (SessionRequest rid issued op)
        else Left BadExpect
    _ -> Left Malformed
