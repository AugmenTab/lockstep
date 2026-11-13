{- | The JSON bodies of the header-session pages (contracts C-P3.1 §3, C-P3.4):
one json-fleece schema per body, encoded by "Fleece.Aeson", then made
markup-safe.

Markup safety (C-P3.1): @<@, @>@, @&@ and every character outside printable
ASCII are written as @\\uXXXX@ escapes, characters above U+FFFF as a UTF-16
surrogate pair, so no response can be read as markup and every response is
ASCII. In encoded JSON these characters can only occur inside strings, so the
pass changes no value. (The hand-written escaper this replaces wrote characters
above U+FFFF as five hex digits, which is not JSON.)

Field names, their order, and null and omission are those of the bodies built
by hand before. The one difference: a result's @fields@ object is a map, so
its keys are written in key order (the control pane reads them by name).
-}
module Lockstep.Web.Json
  ( encodeBody
  , markupSafe
  , ErrorBody (..)
  , errorSchema
  , SessionBody (..)
  , sessionSchema
  , IdBody (..)
  , idSchema
  , UrlBody (..)
  , urlSchema
  , StateBody (..)
  , stateSchema
  , FolderListBody (..)
  , FolderEntry (..)
  , folderListSchema
  , ResultBody (..)
  , resultSchema
  ) where

import Data.Bits (shiftR, (.&.))
import Data.ByteString.Lazy qualified as LBS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fleece.Aeson qualified as FA
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude
import Numeric (showHex)

-- | The body as markup-safe JSON text.
encodeBody :: FC.Schema FA.Encoder a -> a -> T.Text
encodeBody schema =
  markupSafe . TE.decodeUtf8Lenient . LBS.toStrict . FA.encode schema

-- | Escapes @<@, @>@, @&@ and non-ASCII characters of encoded JSON (see the module header).
markupSafe :: T.Text -> T.Text
markupSafe =
  T.concatMap escape
 where
  escape c
    | c == '<' || c == '>' || c == '&' || c > '~' = unicodeEscape (Char.ord c)
    | otherwise = T.singleton c
  unicodeEscape code
    | code > 0xFFFF =
        let
          offset = code - 0x10000
        in
          unit (0xD800 + shiftR offset 10) <> unit (0xDC00 + (offset .&. 0x3FF))
    | otherwise = unit code
  unit n =
    let
      digits = showHex n ""
    in
      T.pack ("\\u" <> L.replicate (4 - L.length digits) '0' <> digits)

-- | @{"error": code}@: every refusal.
newtype ErrorBody
  = ErrorBody
  { errorCode :: T.Text
  }

errorSchema :: FC.Fleece t => FC.Schema t ErrorBody
errorSchema =
  FC.object $
    FC.constructor ErrorBody
      #+ FC.required "error" errorCode FC.text

-- | @{"session": token}@: a sign-in's session.
newtype SessionBody
  = SessionBody
  { sessionToken :: T.Text
  }

sessionSchema :: FC.Fleece t => FC.Schema t SessionBody
sessionSchema =
  FC.object $
    FC.constructor SessionBody
      #+ FC.required "session" sessionToken FC.text

-- | @{"id": request id}@: an accepted request.
newtype IdBody
  = IdBody
  { idValue :: T.Text
  }

idSchema :: FC.Fleece t => FC.Schema t IdBody
idSchema =
  FC.object $
    FC.constructor IdBody
      #+ FC.required "id" idValue FC.text

-- | @{"url": address}@: a handover.
newtype UrlBody
  = UrlBody
  { urlValue :: T.Text
  }

urlSchema :: FC.Fleece t => FC.Schema t UrlBody
urlSchema =
  FC.object $
    FC.constructor UrlBody
      #+ FC.required "url" urlValue FC.text

-- | @{"state": state}@: a request not finished (@pending@) or not trusted (@untrusted@).
newtype StateBody
  = StateBody
  { stateValue :: T.Text
  }

stateSchema :: FC.Fleece t => FC.Schema t StateBody
stateSchema =
  FC.object $
    FC.constructor StateBody
      #+ FC.required "state" stateValue FC.text

-- | The folder list: its digest and its entries in order.
data FolderListBody
  = FolderListBody
  { folderBodyDigest :: T.Text
  , folderBodyEntries :: [FolderEntry]
  }

data FolderEntry
  = FolderEntry
  { folderMode :: T.Text
  , folderPath :: T.Text
  }

folderListSchema :: FC.Fleece t => FC.Schema t FolderListBody
folderListSchema =
  FC.object $
    FC.constructor FolderListBody
      #+ FC.required "digest" folderBodyDigest FC.text
      #+ FC.required "folders" folderBodyEntries (FC.list folderEntrySchema)

folderEntrySchema :: FC.Fleece t => FC.Schema t FolderEntry
folderEntrySchema =
  FC.object $
    FC.constructor FolderEntry
      #+ FC.required "mode" folderMode FC.text
      #+ FC.required "path" folderPath FC.text

-- | A finished request's result (@state@ is @done@); an absent reason is @null@.
data ResultBody
  = ResultBody
  { resultBodyState :: T.Text
  , resultBodyId :: T.Text
  , resultBodyOp :: T.Text
  , resultBodyOutcome :: T.Text
  , resultBodyReason :: Maybe T.Text
  , resultBodyStarted :: Integer
  , resultBodyFinished :: Integer
  , resultBodyFields :: Map.Map T.Text T.Text
  , resultBodyDetail :: T.Text
  }

resultSchema :: FC.Fleece t => FC.Schema t ResultBody
resultSchema =
  FC.object $
    FC.constructor ResultBody
      #+ FC.required "state" resultBodyState FC.text
      #+ FC.required "id" resultBodyId FC.text
      #+ FC.required "op" resultBodyOp FC.text
      #+ FC.required "outcome" resultBodyOutcome FC.text
      #+ FC.required "reason" resultBodyReason nullableText
      #+ FC.required "started" resultBodyStarted FC.integer
      #+ FC.required "finished" resultBodyFinished FC.integer
      #+ FC.required "fields" resultBodyFields (FC.map FC.text)
      #+ FC.required "detail" resultBodyDetail FC.text

-- | Text or @null@ (written as @null@, never omitted).
nullableText :: FC.Fleece t => FC.Schema t (Maybe T.Text)
nullableText =
  FC.validate (maybe (Left FC.Null) Right) (Right . either (const Nothing) Just) (FC.nullable FC.text)
