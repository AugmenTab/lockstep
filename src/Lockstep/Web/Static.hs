{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

{- | Static assets, embedded in the binary and served from an explicit
allowlist (contract C-P1.1 D6). Launchpad served these through a
separate web server, which is removed.
-}
module Lockstep.Web.Static
  ( StaticAsset (..)
  , lookupAsset
  , staticRootPath
  , stylesheet
  ) where

import Beeline.Routing ((/-))
import Beeline.Routing qualified as R
import Brigid.Types qualified as B
import Data.ByteString qualified as BS
import Data.FileEmbed qualified as FileEmbed
import Data.List qualified as L
import Data.String.Interpolate qualified as Interpolate
import Data.Text qualified as T
import Flipstone.Prelude

data StaticAsset
  = StaticAsset
  { assetContentType :: BS.ByteString
  , assetBody :: BS.ByteString
  }

data GetStaticFile = GetStaticFile

staticRootPath :: T.Text
staticRootPath = [Interpolate.i|static|]

stylesheetName :: T.Text
stylesheetName = [Interpolate.i|lockstep.css|]

lockstepCss :: BS.ByteString
lockstepCss =
  $(FileEmbed.embedFile "static/lockstep.css")

-- | The control pane's page script (contract C-P3.1 §3).
controlJs :: BS.ByteString
controlJs =
  $(FileEmbed.embedFile "static/control.js")

assets :: [(T.Text, StaticAsset)]
assets =
  [ (stylesheetName, StaticAsset [Interpolate.i|text/css; charset=utf-8|] lockstepCss)
  , ([Interpolate.i|control.js|], StaticAsset [Interpolate.i|text/javascript; charset=utf-8|] controlJs)
  ]

-- | The asset served at @/static/<name>@, if @name@ is on the allowlist.
lookupAsset :: T.Text -> Maybe StaticAsset
lookupAsset name =
  L.lookup name assets

stylesheet :: B.RelativeURL B.Get
stylesheet =
  B.get GetStaticFile $
    R.make GetStaticFile
      /- staticRootPath
      /- stylesheetName
