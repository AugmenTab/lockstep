{-# LANGUAGE OverloadedStrings #-}

{- | Rendering helpers for the application's server-rendered fragments
(contracts C-P3.4 A1, C-P3.5 J9, C-P3.6 K6): one section element, escaped
attributes, and named character references.
-}
module Lockstep.Web.Fragment
  ( fragment
  , namedEntities
  , cls
  , attr
  , href
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude

fragment :: [E.ChildHTML E.Division E.Body] -> LBS.ByteString
fragment children =
  namedEntities (renderLazyHTML (E.div [cls "ls-section"] children :: E.ChildHTML E.Body E.Html))

{- | Brigid escapes text as numeric references (@&#60;@); the same characters are
written here as the named references (@&lt;@), which mean exactly the same.
-}
namedEntities :: LBS.ByteString -> LBS.ByteString
namedEntities =
  LBS.fromStrict . go . LBS.toStrict
 where
  go bytes =
    case BS.breakSubstring "&#" bytes of
      (before, rest)
        | BS.null rest -> before
        | otherwise -> before <> replaceOne rest
  replaceOne rest =
    case L.find (\(numeric, _) -> numeric `BS.isPrefixOf` rest) table of
      Just (numeric, named) -> named <> go (BS.drop (BS.length numeric) rest)
      Nothing -> "&#" <> go (BS.drop 2 rest)
  table =
    [ ("&#60;", "&lt;")
    , ("&#62;", "&gt;")
    , ("&#38;", "&amp;")
    , ("&#34;", "&quot;")
    ]

cls :: T.Text -> A.Attribute tag
cls =
  A.class_ . HTML.Class

{- | An attribute whose value is escaped: ampersands, angle brackets and double
quotes are escaped here (C-C.R1 R8), so typed text never appears as markup
anywhere in a page and no value depends on Brigid escaping quotes.
-}
attr :: T.Text -> T.Text -> A.Attribute tag
attr name =
  A.customAttribute name . T.replace "\"" "&quot;" . T.replace ">" "&gt;" . T.replace "<" "&lt;" . T.replace "&" "&amp;"

href :: T.Text -> A.Attribute E.Anchor
href =
  A.href . B.mkRawURL
