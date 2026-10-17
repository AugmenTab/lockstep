{-# LANGUAGE QuasiQuotes #-}

{- | Derived from Launchpad.Components.Page404 (11886bf), restyled with
Lockstep CSS and without themes.
-}
module Lockstep.Web.Components.Page404
  ( page404
  ) where

import Brigid.HTML.Elements qualified as E
import Data.String.Interpolate qualified as Interpolate

import Lockstep.Web.Components.Page (page)

page404 :: E.HTML
page404 =
  page
    [Interpolate.i|Not found — Lockstep|]
    [ E.main
        []
        [ E.h1 [] [E.text [Interpolate.i|Not found|]]
        , E.p [] [E.text [Interpolate.i|There is no page at this address.|]]
        ]
    ]
