{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}

{- | @GET /api/readiness@ (ADR-0002 Q4): 200 @ready <revision>@ only when the
database is connected at the binary's schema revision, otherwise 503 with the
typed reason. Health stays liveness-only.
-}
module Lockstep.Web.Readiness
  ( ReadinessCheck (ReadinessCheck)
  , getReadiness
  ) where

import Beeline.Routing ((/-))
import Beeline.Routing qualified as R
import Data.ByteString.Lazy qualified as LBS
import Data.String.Interpolate qualified as Interpolate
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Orb qualified
import Shrubbery qualified

import Lockstep.Application.Database (Readiness (..), checkReadiness, readinessCode)
import Lockstep.Web.Common (apiRootPath)
import Lockstep.Web.Handler.NoPermissionError (NoPermissionError)
import Lockstep.Web.Handler.NoUser (NoUser (NoUser))
import Lockstep.Web.Types (Lockstep, getDatabase)

getReadiness :: R.Router r => R.Builder r route ReadinessCheck
getReadiness =
  R.make ReadinessCheck /- apiRootPath /- [Interpolate.i|readiness|]

data ReadinessCheck = ReadinessCheck

instance Orb.PermissionAction ReadinessCheck where
  type PermissionActionResult ReadinessCheck = NoUser
  type PermissionActionError ReadinessCheck = NoPermissionError
  type PermissionActionMonad ReadinessCheck = Lockstep

  checkPermissionAction ReadinessCheck = pure $ Right NoUser

instance Orb.HasHandler ReadinessCheck where
  type HandlerResponses ReadinessCheck = ReadinessResponseCodes
  type HandlerPermissionAction ReadinessCheck = ReadinessCheck
  type HandlerMonad ReadinessCheck = Lockstep

  routeHandler = readinessHandler

readinessHandler :: Orb.Handler ReadinessCheck
readinessHandler =
  Orb.Handler
    { Orb.handlerId = "API.Readiness"
    , Orb.requestBody = Orb.EmptyRequestBody
    , Orb.requestQuery = Orb.EmptyRequestQuery
    , Orb.requestHeaders = Orb.EmptyRequestHeaders
    , Orb.handlerResponseBodies = readinessResponseSchemas
    , Orb.mkPermissionAction = Orb.reqRoute
    , Orb.handleRequest = readiness
    }

type ReadinessResponseCodes =
  [ Orb.Response200 T.Text
  , Orb.Response503 T.Text
  , Orb.Response500 Orb.InternalServerError
  ]

readinessResponseSchemas :: Orb.ResponseBodies ReadinessResponseCodes
readinessResponseSchemas =
  Orb.responseBodies
    . Orb.addResponseBody200 Orb.textPlain textBody
    . Orb.addResponseBody503 Orb.textPlain textBody
    . Orb.addResponseSchema500 Orb.internalServerErrorSchema
    $ Orb.noResponseBodies

textBody :: T.Text -> LBS.ByteString
textBody =
  LBS.fromStrict . TE.encodeUtf8

readiness ::
  Orb.HandlerRequest ReadinessCheck ->
  NoUser ->
  Lockstep (Shrubbery.TaggedUnion ReadinessResponseCodes)
readiness _req NoUser = do
  db <- getDatabase
  result <- liftIO (checkReadiness db)
  case result of
    Ready _ -> Orb.return200 (readinessCode result)
    NotReady _ -> Orb.return503 (readinessCode result)
