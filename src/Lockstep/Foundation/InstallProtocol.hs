{- | The install request kind (contract C-P3.3 U1): prepare a candidate, apply
the inspected candidate, or restore after a failed upgrade. The expectation
names the exact candidate (16 hex characters of its binary's SHA-256) or the
exact failed upgrade (its 32-hex id) the page showed; no path or argument ever
comes from the browser.
-}
module Lockstep.Foundation.InstallProtocol
  ( InstallOp (..)
  , installOpName
  , parseInstallOp
  , InstallExpect (..)
  , installExpectText
  , parseInstallExpect
  , validFor
  , InstallRequest (..)
  , encodeInstallRequest
  , decodeInstallRequest
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
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

data InstallOp
  = PrepareCandidate
  | ApplyCandidate
  | RestorePrevious
  deriving (Eq, Show, Enum, Bounded)

installOpName :: InstallOp -> T.Text
installOpName op =
  T.pack $
    case op of
      PrepareCandidate -> "prepare-candidate"
      ApplyCandidate -> "apply-candidate"
      RestorePrevious -> "restore-previous"

parseInstallOp :: T.Text -> Maybe InstallOp
parseInstallOp text =
  L.find ((== text) . installOpName) [minBound .. maxBound]

data InstallExpect
  = CandidateNone
  | -- | the first 16 lower-case hex characters of the staged binary's SHA-256
    CandidateDigest T.Text
  | -- | the 32-hex id of the failed upgrade
    RecoveryOf T.Text
  deriving (Eq, Show)

installExpectText :: InstallExpect -> T.Text
installExpectText expect =
  case expect of
    CandidateNone -> T.pack "candidate-none"
    CandidateDigest d -> T.pack "candidate-" <> d
    RecoveryOf i -> T.pack "recovery-" <> i

lowerHexOf :: Int -> T.Text -> Bool
lowerHexOf n t =
  T.length t == n && T.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) t

parseInstallExpect :: T.Text -> Maybe InstallExpect
parseInstallExpect text
  | text == T.pack "candidate-none" = Just CandidateNone
  | Just d <- T.stripPrefix (T.pack "candidate-") text, lowerHexOf 16 d = Just (CandidateDigest d)
  | Just i <- T.stripPrefix (T.pack "recovery-") text, lowerHexOf 32 i = Just (RecoveryOf i)
  | otherwise = Nothing

validFor :: InstallOp -> InstallExpect -> Bool
validFor op expect =
  case (op, expect) of
    (PrepareCandidate, CandidateNone) -> True
    (PrepareCandidate, CandidateDigest _) -> True
    (ApplyCandidate, CandidateDigest _) -> True
    (RestorePrevious, RecoveryOf _) -> True
    _ -> False

data InstallRequest
  = InstallRequest
  { installId :: RequestId
  , installIssued :: Integer
  , installOp :: InstallOp
  , installExpect :: InstallExpect
  }
  deriving (Eq, Show)

header :: BS.ByteString
header =
  BS8.pack "lockstep-install-request "

line :: String -> T.Text -> BS.ByteString
line key value =
  BS8.pack key <> BS8.pack " " <> TE.encodeUtf8 value <> BS8.pack "\n"

encodeInstallRequest :: ChannelKey -> InstallRequest -> BS.ByteString
encodeInstallRequest key request =
  signBody key $
    BS.concat
      [ header <> BS8.pack "1\n"
      , line "id" (requestIdText (installId request))
      , line "issued" (T.pack (show (installIssued request)))
      , line "op" (installOpName (installOp request))
      , line "expect" (installExpectText (installExpect request))
      ]

decodeInstallRequest :: ChannelKey -> BS.ByteString -> Either ProtocolError InstallRequest
decodeInstallRequest key bytes = do
  (version, rest) <- decodeSignedKind header key bytes
  case rest of
    [idLine, issuedLine, opLine, expectLine] -> do
      when (version /= BS8.pack "1") (Left BadVersion)
      rid <- lineValue "id" idLine >>= maybe (Left Malformed) Right . parseRequestId
      issued <- lineValue "issued" issuedLine >>= decimal
      op <- lineValue "op" opLine >>= maybe (Left UnknownOp) Right . parseInstallOp
      expect <- lineValue "expect" expectLine >>= maybe (Left BadExpect) Right . parseInstallExpect
      if validFor op expect
        then Right (InstallRequest rid issued op expect)
        else Left BadExpect
    _ -> Left Malformed
