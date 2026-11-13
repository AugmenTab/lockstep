{- | Small json-fleece helpers shared by the documents Lockstep writes
(patterned on Launchpad 11886bf @Util.Fleece@).
-}
module Lockstep.Foundation.Fleece
  ( nullableOf
  , encodeText
  , decodeText
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Typeable (Typeable)
import Fleece.Aeson qualified as FA
import Fleece.Core qualified as FC
import Flipstone.Prelude

-- | A value or @null@; 'Nothing' is written as @null@, never omitted.
nullableOf :: (FC.Fleece t, Typeable a) => FC.Schema t a -> FC.Schema t (Maybe a)
nullableOf schema =
  FC.validate (maybe (Left FC.Null) Right) (Right . either (const Nothing) Just) (FC.nullable schema)

{- | The document as text: compact, keys in the schema's order, strings
escaped as RFC 8259 requires (the same bytes "Lockstep.Foundation.Json"
writes for the same document).
-}
encodeText :: FC.Schema FA.Encoder a -> a -> T.Text
encodeText schema =
  TE.decodeUtf8Lenient . LBS.toStrict . FA.encode schema

decodeText :: FC.Schema FA.Decoder a -> T.Text -> Either String a
decodeText schema =
  FA.decode schema . LBS.fromStrict . TE.encodeUtf8
