-- | POSITIVE CONTROL for the boundary fixture: Web importing Foundation is
-- allowed, so this must compile with the same command.
module Lockstep.Web.BoundaryControl
  ( settings
  ) where

import Network.Wai.Handler.Warp qualified as Warp

import Lockstep.Foundation.Config (defaultServeConfig)
import Lockstep.Web.Server (serverSettings)

settings :: Warp.Settings
settings =
  serverSettings defaultServeConfig
