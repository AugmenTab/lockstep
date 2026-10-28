{- | A small JSON value and its exact text (contract C-P4.5 A3): the documents
Lockstep gives a role. Strings are escaped per RFC 8259; object keys keep
their order, so the same document is always the same bytes.
-}
module Lockstep.Foundation.Json
  ( Json (..)
  , renderJson
  , string
  , strings
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Numeric (showHex)
import Text.Show (Show, show)

data Json
  = JString T.Text
  | JNumber Integer
  | JBool Bool
  | JNull
  | JArray [Json]
  | JObject [(T.Text, Json)]
  deriving (Eq, Show)

string :: T.Text -> Json
string =
  JString

strings :: [T.Text] -> Json
strings =
  JArray . fmap JString

renderJson :: Json -> T.Text
renderJson value =
  case value of
    JString text -> quoted text
    JNumber n -> T.pack (show n)
    JBool b -> T.pack (if b then "true" else "false")
    JNull -> T.pack "null"
    JArray items -> T.pack "[" <> T.intercalate (T.pack ",") (fmap renderJson items) <> T.pack "]"
    JObject fields ->
      T.pack "{"
        <> T.intercalate (T.pack ",") [quoted k <> T.pack ":" <> renderJson v | (k, v) <- fields]
        <> T.pack "}"

quoted :: T.Text -> T.Text
quoted text =
  T.pack "\"" <> T.concatMap escape text <> T.pack "\""
 where
  escape c =
    case c of
      '"' -> T.pack "\\\""
      '\\' -> T.pack "\\\\"
      '\n' -> T.pack "\\n"
      '\r' -> T.pack "\\r"
      '\t' -> T.pack "\\t"
      _
        | Char.ord c < 0x20 -> T.pack ("\\u" <> L.replicate (4 - L.length (hex c)) '0' <> hex c)
        | otherwise -> T.singleton c
  hex c =
    showHex (Char.ord c) ""
