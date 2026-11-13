{-# LANGUAGE OverloadedStrings #-}
-- Brigid checks a @noscript@ element's children (a transparent content model)
-- at the type level; under @body@ that takes more than GHC's default 200
-- reduction steps. This raises the bound for this module only; the check runs
-- in full.
{-# OPTIONS_GHC -freduction-depth=400 #-}

{- | The control pane's content-free shell (contract C-P3.1 §3): no state and
no data, only the stylesheet, a container the page script fills, a notice for
browsers without JavaScript, and @control.js@ from the static allowlist. No
inline script.

(The application's shell stays hand-written in "Lockstep.Web.App": its frozen
test pins a single-quoted attribute Brigid cannot write.)
-}
module Lockstep.Web.Components.Shell
  ( controlShell
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Elements.Safe qualified as Safe
import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Brigid.HTML.Types qualified as HTML
import Data.ByteString.Lazy qualified as LBS
import Flipstone.Prelude
import Ogma qualified

import Lockstep.Web.Fragment (elementId)
import Lockstep.Web.Static qualified as Static

-- | The shell as a document (Brigid writes the doctype).
controlShell :: LBS.ByteString
controlShell =
  renderLazyHTML $
    E.html
      [A.lang (Just (Ogma.simpleBCP_47 Ogma.English))]
      [ E.head
          []
          [ Safe.meta Safe.Charset
          , E.meta [A.name HTML.Viewport, A.content "width=device-width, initial-scale=1"]
          , E.title [] [E.text "Lockstep"]
          , E.link [A.rel HTML.Rel_Stylesheet, A.href Static.stylesheet]
          ]
      , E.body
          [A.class_ (HTML.Class "control")]
          [container, noScriptNotice, E.script [A.src (Static.assetURL "control.js")] Nothing]
      ]

-- | Where the page script writes; until then it says the page is opening.
container :: E.ChildHTML E.Body E.Html
container =
  E.main
    [A.id (elementId 'a' "pp"), A.class_ (HTML.Class "control-main"), A.customAttribute "aria-live" "polite"]
    [E.p [] [E.text "Opening Lockstep\8230"]]

noScriptNotice :: E.ChildHTML E.Body E.Html
noScriptNotice =
  E.noscript [] [notice]
 where
  notice :: E.ChildHTML E.NoScript E.Body
  notice =
    E.p [] [E.text "Lockstep needs JavaScript turned on in this browser."]
