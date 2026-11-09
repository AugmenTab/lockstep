{- | Submitted forms as Orb's 'Orb.Form' (derived from Artificer.Form): every
field by name, its values in the order sent. An urlencoded body is read with
http-types; names and values must be UTF-8 (a body that is not is no form, where
it used to be decoded leniently). 'Orb.getForm' itself is not used: it decodes
with a partial UTF-8 decoder.
-}
module Lockstep.Web.Form
  ( Orb.Form
  , Orb.FormField (..)
  , readForm
  , queryForm
  , field
  ) where

import Brigid.Types qualified as B
import Data.ByteString qualified as BS
import Data.List.NonEmpty qualified as NEL
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.NonEmptyText qualified as NET
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Orb qualified

-- | An urlencoded body as a form; 'Nothing' if a name or value is not UTF-8.
readForm :: BS.ByteString -> Maybe Orb.Form
readForm =
  formOf . HTTP.parseSimpleQuery

-- | A request's query string as a form (a name without @=@ has the empty value).
queryForm :: Wai.Request -> Maybe Orb.Form
queryForm request =
  formOf [(name, fromMaybe BS.empty value) | (name, value) <- Wai.queryString request]

formOf :: [(BS.ByteString, BS.ByteString)] -> Maybe Orb.Form
formOf =
  fmap (fmap Orb.ParamField . Map.fromListWith (flip (<>))) . traverse decodePair
 where
  decodePair (name, value) =
    case (TE.decodeUtf8' name, TE.decodeUtf8' value) of
      (Right n, Right v) -> Just (n, v NEL.:| [])
      _ -> Nothing

field :: B.Name -> Orb.Form -> Maybe Orb.FormField
field (B.Name name) =
  Map.lookup (NET.toText name)
