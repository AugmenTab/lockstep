{- | Operator sign-in and session tokens (contract C-P1.3 E2, E5, E6): 32 bytes
from the CSPRNG, written as unpadded base64url, stored only as their SHA-256
digest. The raw bytes never appear in 'Show' output.
-}
module Lockstep.Foundation.OperatorToken
  ( RawToken
  , generateToken
  , encodeToken
  , decodeToken
  , tokenDigest
  , csrfFor
  , csrfMatches
  ) where

import Crypto.Hash (SHA256 (SHA256), hashWith)
import Crypto.MAC.HMAC (HMAC, hmac)
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Text.Show (Show (show))

-- | A token's raw bytes. Equality is constant-time.
newtype RawToken
  = RawToken BS.ByteString

instance Eq RawToken where
  RawToken a == RawToken b =
    BA.constEq a b

instance Show RawToken where
  show _ =
    "<redacted>"

tokenBytes :: Int
tokenBytes =
  32

tokenTextLength :: Int
tokenTextLength =
  43

generateToken :: IO RawToken
generateToken =
  RawToken <$> getRandomBytes tokenBytes

encodeToken :: RawToken -> T.Text
encodeToken (RawToken bytes) =
  TE.decodeLatin1 (convertToBase Base64URLUnpadded bytes)

{- | Accepts exactly the 43-character canonical encoding of 32 bytes; anything
else (padding, the standard alphabet, a non-canonical final character) is
'Nothing'.
-}
decodeToken :: T.Text -> Maybe RawToken
decodeToken text =
  if T.length text == tokenTextLength && T.all isBase64Url text
    then
      let
        encoded = BS8.pack (T.unpack text)
      in
        case convertFromBase Base64URLUnpadded encoded of
          Right bytes
            | BS.length bytes == tokenBytes
            , convertToBase Base64URLUnpadded bytes == encoded ->
                Just (RawToken bytes)
          _ ->
            Nothing
    else Nothing

isBase64Url :: Char -> Bool
isBase64Url c =
  Char.isAsciiUpper c || Char.isAsciiLower c || Char.isDigit c || c == '-' || c == '_'

tokenDigest :: RawToken -> BS.ByteString
tokenDigest (RawToken bytes) =
  BA.convert (hashWith SHA256 bytes)

-- | @base64url(HMAC-SHA256(key = session token, "lockstep-csrf-v1"))@.
csrfFor :: RawToken -> T.Text
csrfFor (RawToken bytes) =
  let
    mac = hmac bytes (BS8.pack "lockstep-csrf-v1") :: HMAC SHA256
  in
    TE.decodeLatin1 (convertToBase Base64URLUnpadded mac)

csrfMatches :: RawToken -> T.Text -> Bool
csrfMatches token candidate =
  BA.constEq (TE.encodeUtf8 (csrfFor token)) (TE.encodeUtf8 candidate)
