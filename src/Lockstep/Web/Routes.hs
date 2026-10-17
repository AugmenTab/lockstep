{-# LANGUAGE DataKinds #-}

{- | The complete route table. Derived from Launchpad.Routes (11886bf) with the
App/Signup/Admin/Account/Mobile/Swagger routes removed.
-}
module Lockstep.Web.Routes
  ( Routes
  , dispatch
  , routes
  ) where

import Beeline.Routing ((/:))
import Beeline.Routing qualified as R
import Flipstone.Prelude
import Network.Wai qualified as Wai
import Orb qualified
import Shrubbery qualified

import Lockstep.Foundation.Types (Lockstep)
import Lockstep.Web.Health (HealthCheck, getHealthCheck)
import Lockstep.Web.Liveness (Liveness, getLiveness)

type Routes =
  Shrubbery.Union
    [ HealthCheck
    , Liveness
    ]

dispatch :: Routes -> Lockstep Wai.ResponseReceived
dispatch =
  Orb.dispatch

routes :: Orb.ServerRouter r => r Routes
routes =
  R.routeList $
    Orb.get getHealthCheck
      /: Orb.get getLiveness
      /: R.emptyRoutes
