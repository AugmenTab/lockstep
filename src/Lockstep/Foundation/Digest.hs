{- | SHA-256 and lowercase hexadecimal, through crypton and memory.

One digest type and one hex encoding for the whole application, so no stored
or hashed value depends on a 'Text.Show.Show' instance (a diagnostic format,
not a contract). 'convertToBase' 'Base16' writes lowercase hex, two characters
per byte.
-}
module Lockstep.Foundation.Digest
  ( Sha256
  , sha256
  , sha256Utf8
  , sha256Bytes
  , sha256Hex
  , hexText
  ) where

import Crypto.Hash (Digest, SHA256 (SHA256), hashWith)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude

-- | A SHA-256 digest: always 32 bytes.
newtype Sha256
  = Sha256 (Digest SHA256)
  deriving (Eq, Ord, BA.ByteArrayAccess)

sha256 :: BS.ByteString -> Sha256
sha256 =
  Sha256 . hashWith SHA256

-- | The digest of a text's UTF-8 bytes.
sha256Utf8 :: T.Text -> Sha256
sha256Utf8 =
  sha256 . TE.encodeUtf8

-- | The 32 raw bytes, as stored in a @bytea@ column.
sha256Bytes :: Sha256 -> BS.ByteString
sha256Bytes =
  BA.convert

-- | The 64-character lowercase hex form.
sha256Hex :: Sha256 -> T.Text
sha256Hex =
  hexText

-- | Lowercase hex, two characters per byte.
hexText :: BA.ByteArrayAccess ba => ba -> T.Text
hexText =
  TE.decodeLatin1 . convertToBase Base16
