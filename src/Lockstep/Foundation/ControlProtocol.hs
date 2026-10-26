{- | The control channel between the pane and the host helper, protocol v1
(contract C-P3.1 §4): line-oriented request and result files authenticated with
HMAC-SHA256 under a per-helper-session key. Parsing is strict: a file is either
exactly one documented form or refused whole.
-}
module Lockstep.Foundation.ControlProtocol
  ( ChannelKey
  , parseChannelKey
  , RequestId
  , parseRequestId
  , requestIdText
  , ControlOp (..)
  , opName
  , parseOp
  , Expect (..)
  , parseExpect
  , expectValidFor
  , ControlRequest (..)
  , ControlResult (..)
  , Outcome (..)
  , outcomeName
  , ProtocolError (..)
  , encodeRequest
  , decodeRequest
  , encodeResult
  , decodeResult
  , hmacHex
  , signInDigestHex
  , maxRequestBytes
  ) where

import Control.Monad (unless)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Crypto.MAC.HMAC (HMAC, hmac)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base16), convertFromBase, convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe, isNothing)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Text.Show (Show (show))

-- | The 32-byte channel key. Never shown.
newtype ChannelKey
  = ChannelKey BS.ByteString

instance Show ChannelKey where
  show _ =
    "<channel key>"

-- | Exactly 64 lower-case hex characters, optionally followed by one newline.
parseChannelKey :: BS.ByteString -> Maybe ChannelKey
parseChannelKey bytes =
  let
    hex = fromMaybe bytes (BS.stripSuffix (BS8.pack "\n") bytes)
  in
    if BS.length hex == 64 && BS8.all isLowerHex hex
      then either (const Nothing) (Just . ChannelKey) (convertFromBase Base16 hex :: Either String BS.ByteString)
      else Nothing

isLowerHex :: Char -> Bool
isLowerHex c =
  Char.isDigit c || (c >= 'a' && c <= 'f')

-- | 32 lower-case hex characters.
newtype RequestId
  = RequestId T.Text
  deriving (Eq, Show)

parseRequestId :: T.Text -> Maybe RequestId
parseRequestId text =
  if T.length text == 32 && T.all isLowerHex text
    then Just (RequestId text)
    else Nothing

requestIdText :: RequestId -> T.Text
requestIdText (RequestId t) =
  t

-- | The allowlist, version 1 (C-P3.1 L9).
data ControlOp
  = OpStatus
  deriving (Eq, Show, Enum, Bounded)

opName :: ControlOp -> T.Text
opName op =
  case op of
    OpStatus -> T.pack "status"

parseOp :: T.Text -> Maybe ControlOp
parseOp text =
  L.find ((== text) . opName) [minBound .. maxBound]

data Expect
  = ExpectAny
  deriving (Eq, Show)

expectName :: Expect -> T.Text
expectName expect =
  case expect of
    ExpectAny -> T.pack "any"

parseExpect :: T.Text -> Maybe Expect
parseExpect text =
  if text == expectName ExpectAny then Just ExpectAny else Nothing

expectValidFor :: ControlOp -> Expect -> Bool
expectValidFor op expect =
  case (op, expect) of
    (OpStatus, ExpectAny) -> True

data ControlRequest
  = ControlRequest
  { requestId :: RequestId
  , requestIssued :: Integer
  , requestOp :: ControlOp
  , requestExpect :: Expect
  }
  deriving (Eq, Show)

data Outcome
  = OutcomeOk
  | OutcomeRefused
  | OutcomeFailed
  | OutcomeTimedOut
  | OutcomeInterrupted
  deriving (Eq, Show, Enum, Bounded)

outcomeName :: Outcome -> T.Text
outcomeName outcome =
  T.pack $
    case outcome of
      OutcomeOk -> "ok"
      OutcomeRefused -> "refused"
      OutcomeFailed -> "failed"
      OutcomeTimedOut -> "timed-out"
      OutcomeInterrupted -> "interrupted"

data ControlResult
  = ControlResult
  { resultId :: T.Text
  , resultOp :: T.Text
  , resultOutcome :: Outcome
  , resultReason :: Maybe T.Text
  , resultStarted :: Integer
  , resultFinished :: Integer
  , resultFields :: [(T.Text, T.Text)]
  , resultDetail :: T.Text
  }
  deriving (Eq, Show)

data ProtocolError
  = Malformed
  | BadVersion
  | BadMac
  | UnknownOp
  | BadExpect
  | TooLarge
  deriving (Eq, Show)

maxRequestBytes :: Int
maxRequestBytes =
  1024

maxResultBytes :: Int
maxResultBytes =
  16384

requestHeader :: BS.ByteString
requestHeader =
  BS8.pack "lockstep-control-request "

resultHeader :: BS.ByteString
resultHeader =
  BS8.pack "lockstep-control-result "

-- | Lower-case hex HMAC-SHA256 of the bytes under the key.
hmacHex :: ChannelKey -> BS.ByteString -> T.Text
hmacHex (ChannelKey key) bytes =
  let
    mac = hmac key bytes :: HMAC SHA256
  in
    TE.decodeLatin1 (convertToBase Base16 mac)

-- | The sign-in file name: lower-case hex SHA-256 of the token text (C-P3.1 L5).
signInDigestHex :: T.Text -> T.Text
signInDigestHex token =
  TE.decodeLatin1 (convertToBase Base16 (hashWith SHA256 (TE.encodeUtf8 token)))

line :: String -> T.Text -> BS.ByteString
line key value =
  BS8.pack key <> BS8.pack " " <> TE.encodeUtf8 value <> BS8.pack "\n"

signed :: ChannelKey -> BS.ByteString -> BS.ByteString
signed key body =
  body <> line "mac" (hmacHex key body)

encodeRequest :: ChannelKey -> ControlRequest -> BS.ByteString
encodeRequest key request =
  signed key $
    BS.concat
      [ requestHeader <> BS8.pack "1\n"
      , line "id" (requestIdText (requestId request))
      , line "issued" (T.pack (show (requestIssued request)))
      , line "op" (opName (requestOp request))
      , line "expect" (expectName (requestExpect request))
      ]

encodeResult :: ChannelKey -> ControlResult -> BS.ByteString
encodeResult key result =
  signed key $
    BS.concat
      ( [ resultHeader <> BS8.pack "1\n"
        , line "id" (resultId result)
        , line "op" (resultOp result)
        , line "outcome" (outcomeName (resultOutcome result))
        , line "reason" (fromMaybe (T.pack "-") (resultReason result))
        , line "started" (T.pack (show (resultStarted result)))
        , line "finished" (T.pack (show (resultFinished result)))
        ]
          <> fmap (\(n, v) -> line "field" (n <> T.pack " " <> v)) (resultFields result)
          <> [line "detail" (resultDetail result)]
      )

{- | Splits a file into its body (everything before the final @mac@ line) and
the MAC, checking size, the character set and line structure first. Every line
ends with a newline; the only line starting with @mac @ is the last.
-}
splitSigned :: Int -> BS.ByteString -> Either ProtocolError ([BS.ByteString], BS.ByteString, T.Text)
splitSigned limit bytes
  | BS.length bytes > limit = Left TooLarge
  | not (BS8.pack "\n" `BS.isSuffixOf` bytes) = Left Malformed
  | BS8.any (\c -> c /= '\n' && (c < ' ' || c > '~')) bytes = Left Malformed
  | otherwise =
      let
        ls = BS8.lines bytes
      in
        case L.reverse ls of
          macLine : restReversed
            | Just macHex <- BS.stripPrefix (BS8.pack "mac ") macLine
            , BS.length macHex == 64
            , BS8.all isLowerHex macHex
            , not (L.any (BS.isPrefixOf (BS8.pack "mac ")) restReversed) ->
                let
                  bodyLines = L.reverse restReversed
                in
                  Right (bodyLines, BS8.unlines bodyLines, TE.decodeLatin1 macHex)
          _ -> Left Malformed

verify :: ChannelKey -> BS.ByteString -> T.Text -> Either ProtocolError ()
verify key body macHex =
  if BA.constEq (TE.encodeUtf8 (hmacHex key body)) (TE.encodeUtf8 macHex)
    then Right ()
    else Left BadMac

-- | A line @key value@ with exactly one space after the key and a non-empty value.
valueOf :: String -> BS.ByteString -> Either ProtocolError T.Text
valueOf key l =
  case BS.stripPrefix (BS8.pack key <> BS8.pack " ") l of
    Just v | not (BS.null v) && not (BS8.pack " " `BS.isPrefixOf` v) -> Right (TE.decodeLatin1 v)
    _ -> Left Malformed

-- | A non-negative decimal of at most 18 digits.
number :: T.Text -> Either ProtocolError Integer
number text =
  if not (T.null text) && T.length text <= 18 && T.all Char.isDigit text
    then Right (T.foldl' (\acc c -> acc * 10 + toInteger (Char.ord c - Char.ord '0')) 0 text)
    else Left Malformed

decodeRequest :: ChannelKey -> BS.ByteString -> Either ProtocolError ControlRequest
decodeRequest key bytes = do
  (ls, body, macHex) <- splitSigned maxRequestBytes bytes
  case ls of
    [header, idLine, issuedLine, opLine, expectLine] -> do
      version <- maybe (Left Malformed) Right (BS.stripPrefix requestHeader header)
      verify key body macHex
      when (version /= BS8.pack "1") (Left BadVersion)
      rid <- valueOf "id" idLine >>= maybe (Left Malformed) Right . parseRequestId
      issued <- valueOf "issued" issuedLine >>= number
      opText <- valueOf "op" opLine
      expectText <- valueOf "expect" expectLine
      op <- maybe (Left UnknownOp) Right (parseOp opText)
      expect <- maybe (Left BadExpect) Right (parseExpect expectText)
      if expectValidFor op expect
        then Right (ControlRequest rid issued op expect)
        else Left BadExpect
    _ -> Left Malformed

-- | @[a-z][a-z.]*@, at most 64 characters.
validFieldName :: T.Text -> Bool
validFieldName name =
  case T.uncons name of
    Just (c, rest) -> T.length name <= 64 && Char.isAsciiLower c && T.all (\x -> Char.isAsciiLower x || x == '.') rest
    Nothing -> False

-- | @[A-Za-z0-9._:-]{1,80}@.
validFieldValue :: T.Text -> Bool
validFieldValue value =
  not (T.null value) && T.length value <= 80 && T.all (\c -> Char.isAsciiUpper c || Char.isAsciiLower c || Char.isDigit c || c `L.elem` "._:-") value

-- | @[a-z][a-z-]*@, at most 32 characters (an operation, outcome or reason code).
validCode :: T.Text -> Bool
validCode code =
  case T.uncons code of
    Just (c, rest) -> T.length code <= 32 && Char.isAsciiLower c && T.all (\x -> Char.isAsciiLower x || x == '-') rest
    Nothing -> False

parseOutcome :: T.Text -> Either ProtocolError Outcome
parseOutcome text =
  maybe (Left Malformed) Right (L.find ((== text) . outcomeName) [minBound .. maxBound])

decodeResult :: ChannelKey -> BS.ByteString -> Either ProtocolError ControlResult
decodeResult key bytes = do
  (ls, body, macHex) <- splitSigned maxResultBytes bytes
  case ls of
    header : idLine : opLine : outcomeLine : reasonLine : startedLine : finishedLine : rest
      | Just (fieldLines, detailLine) <- L.unsnoc rest -> do
          version <- maybe (Left Malformed) Right (BS.stripPrefix resultHeader header)
          verify key body macHex
          when (version /= BS8.pack "1") (Left BadVersion)
          rid <- valueOf "id" idLine
          when (isNothing (parseRequestId rid)) (Left Malformed)
          op <- valueOf "op" opLine
          unless (validCode op) (Left Malformed)
          outcome <- valueOf "outcome" outcomeLine >>= parseOutcome
          reasonText <- valueOf "reason" reasonLine
          reason <-
            if reasonText == T.pack "-"
              then Right Nothing
              else if validCode reasonText then Right (Just reasonText) else Left Malformed
          started <- valueOf "started" startedLine >>= number
          finished <- valueOf "finished" finishedLine >>= number
          fields <- traverse parseField fieldLines
          detail <- parseDetail detailLine
          Right (ControlResult rid op outcome reason started finished fields detail)
    _ -> Left Malformed
 where
  parseField l = do
    v <- valueOf "field" l
    case T.splitOn (T.pack " ") v of
      [name, value] | validFieldName name && validFieldValue value -> Right (name, value)
      _ -> Left Malformed
  parseDetail l =
    case BS.stripPrefix (BS8.pack "detail ") l of
      Just d | BS.length d <= 300 -> Right (TE.decodeLatin1 d)
      _ -> Left Malformed
