-- | NEGATIVE FIXTURE. A Foundation module importing Web violates
-- ARCHITECTURE §2. scripts/check requires Henforcer to reject it.
module Lockstep.Foundation.BoundaryViolation
  ( settings
  ) where

import Network.Wai.Handler.Warp qualified as Warp

import Lockstep.Foundation.Config (defaultServeConfig)
import Lockstep.Web.Server (serverSettings)

settings :: Warp.Settings
settings =
  serverSettings defaultServeConfig
