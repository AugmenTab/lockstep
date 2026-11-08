{-# LANGUAGE QuasiQuotes #-}

{- | The HTML document shell. Replaces Launchpad's Html/Head components
(their CSS framework coupling is removed; ARCHITECTURE §3).
-}
module Lockstep.Web.Components.Page
  ( page
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Elements.Safe qualified as Safe
import Brigid.HTML.Types qualified as HTML
import Data.String.Interpolate qualified as Interpolate
import Data.Text qualified as T
import Flipstone.Prelude
import Ogma qualified

import Lockstep.Web.Static qualified as Static

page :: T.Text -> [E.ChildHTML E.Body E.Html] -> E.HTML
page title content =
  E.html
    [A.lang (Just (Ogma.simpleBCP_47 Ogma.English))]
    [ E.head
        []
        [ Safe.meta Safe.Charset
        , E.meta
            [ A.name HTML.Viewport
            , A.content [Interpolate.i|width=device-width, initial-scale=1|]
            ]
        , E.title [] [E.text title]
        , E.link [A.rel HTML.Rel_Stylesheet, A.href Static.stylesheet]
        ]
    , E.body [] content
    ]
