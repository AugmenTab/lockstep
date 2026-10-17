{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}

{- | @GET /api/health_check@: process liveness only. It answers 204 while the
process can serve HTTP and says nothing about the database (readiness is P1.2).
Derived from Launchpad.Routes.API.HealthCheck (11886bf).
-}
module Lockstep.Web.Health
  ( HealthCheck (HealthCheck)
  , getHealthCheck
  ) where

import Beeline.Routing ((/-))
import Beeline.Routing qualified as R
import Data.String.Interpolate qualified as Interpolate
import Flipstone.Prelude
import Orb qualified
import Shrubbery qualified

import Lockstep.Web.Common (apiRootPath)
import Lockstep.Web.Handler.NoPermissionError (NoPermissionError)
import Lockstep.Web.Handler.NoUser (NoUser (NoUser))
import Lockstep.Web.Types (Lockstep)

getHealthCheck :: R.Router r => R.Builder r route HealthCheck
getHealthCheck =
  R.make HealthCheck /- apiRootPath /- [Interpolate.i|health_check|]

data HealthCheck = HealthCheck

instance Orb.PermissionAction HealthCheck where
  type PermissionActionResult HealthCheck = NoUser
  type PermissionActionError HealthCheck = NoPermissionError
  type PermissionActionMonad HealthCheck = Lockstep

  checkPermissionAction HealthCheck = pure $ Right NoUser

instance Orb.HasHandler HealthCheck where
  type HandlerResponses HealthCheck = GetResponseCodes
  type HandlerPermissionAction HealthCheck = HealthCheck
  type HandlerMonad HealthCheck = Lockstep

  routeHandler = healthCheckHandler

healthCheckHandler :: Orb.Handler HealthCheck
healthCheckHandler =
  Orb.Handler
    { Orb.handlerId = "API.HealthCheck"
    , Orb.requestBody = Orb.EmptyRequestBody
    , Orb.requestQuery = Orb.EmptyRequestQuery
    , Orb.requestHeaders = Orb.EmptyRequestHeaders
    , Orb.handlerResponseBodies = getResponseSchemas
    , Orb.mkPermissionAction = Orb.reqRoute
    , Orb.handleRequest = healthCheck
    }

type GetResponseCodes =
  [ Orb.Response204
  , Orb.Response500 Orb.InternalServerError
  ]

getResponseSchemas :: Orb.ResponseBodies GetResponseCodes
getResponseSchemas =
  Orb.responseBodies
    . Orb.addResponse204
    . Orb.addResponseSchema500 Orb.internalServerErrorSchema
    $ Orb.noResponseBodies

healthCheck ::
  Orb.HandlerRequest HealthCheck ->
  NoUser ->
  Lockstep (Shrubbery.TaggedUnion GetResponseCodes)
healthCheck _req NoUser =
  Orb.return204 Orb.NoContent
