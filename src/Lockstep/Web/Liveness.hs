{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}

{- | @GET /@: a human-readable liveness page. It reports only what this process
knows for certain: it is running and where it listens. Database readiness is
not implemented yet and the page says so (P1.2 adds it).
-}
module Lockstep.Web.Liveness
  ( Liveness (Liveness)
  , getLiveness
  ) where

import Beeline.Routing qualified as R
import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Brigid.HTML.Types qualified as HTML
import Data.String.Interpolate qualified as Interpolate
import Data.Text qualified as T
import Flipstone.Prelude
import Orb qualified
import Shrubbery qualified
import Text.Show (show)

import Lockstep.Foundation.Config (ServeConfig (..), bindHostAddress, portNumber)
import Lockstep.Foundation.Types (Lockstep, getConfig)
import Lockstep.Web.Components.Page (page)
import Lockstep.Web.Handler.NoPermissionError (NoPermissionError)
import Lockstep.Web.Handler.NoUser (NoUser (NoUser))

getLiveness :: R.Router r => R.Builder r route Liveness
getLiveness =
  R.make Liveness

data Liveness = Liveness

instance Orb.PermissionAction Liveness where
  type PermissionActionResult Liveness = NoUser
  type PermissionActionError Liveness = NoPermissionError
  type PermissionActionMonad Liveness = Lockstep

  checkPermissionAction Liveness = pure $ Right NoUser

instance Orb.HasHandler Liveness where
  type HandlerResponses Liveness = LivenessResponseCodes
  type HandlerPermissionAction Liveness = Liveness
  type HandlerMonad Liveness = Lockstep

  routeHandler = livenessHandler

livenessHandler :: Orb.Handler Liveness
livenessHandler =
  Orb.Handler
    { Orb.handlerId = "App.Liveness"
    , Orb.requestBody = Orb.EmptyRequestBody
    , Orb.requestQuery = Orb.EmptyRequestQuery
    , Orb.requestHeaders = Orb.EmptyRequestHeaders
    , Orb.handlerResponseBodies = livenessResponseSchemas
    , Orb.mkPermissionAction = Orb.reqRoute
    , Orb.handleRequest = liveness
    }

type LivenessResponseCodes =
  [ Orb.Response200 E.HTML
  , Orb.Response500 Orb.InternalServerError
  ]

livenessResponseSchemas :: Orb.ResponseBodies LivenessResponseCodes
livenessResponseSchemas =
  Orb.responseBodies
    . Orb.addResponseBody200 Orb.textHtml renderLazyHTML
    . Orb.addResponseSchema500 Orb.internalServerErrorSchema
    $ Orb.noResponseBodies

liveness ::
  Orb.HandlerRequest Liveness ->
  NoUser ->
  Lockstep (Shrubbery.TaggedUnion LivenessResponseCodes)
liveness _req NoUser = do
  host <- getConfig serveHost
  port <- getConfig servePort
  Orb.return200 $
    livenessPage (T.pack (bindHostAddress host <> ":" <> show (portNumber port)))

livenessPage :: T.Text -> E.HTML
livenessPage address =
  page
    [Interpolate.i|Lockstep|]
    [ E.main
        []
        [ E.h1 [] [E.text [Interpolate.i|Lockstep is running|]]
        , E.p
            []
            [ E.text [Interpolate.i|This page reports process liveness only.|]
            ]
        , E.dl
            [A.class_ (HTML.Class [Interpolate.i|ls-facts|])]
            [ E.dt [] [E.text [Interpolate.i|Process|]]
            , E.dd [] [E.text [Interpolate.i|Alive: this page was rendered by the running service.|]]
            , E.dt [] [E.text [Interpolate.i|Listening on|]]
            , E.dd [] [E.code [] [E.text address]]
            , E.dt [] [E.text [Interpolate.i|Database readiness|]]
            , E.dd
                []
                [ E.text
                    [Interpolate.i|Not checked. This build has no database connection; readiness checks arrive with it.|]
                ]
            ]
        , E.p
            [A.class_ (HTML.Class [Interpolate.i|ls-muted|])]
            [ E.text [Interpolate.i|Machine check: |]
            , E.code [] [E.text [Interpolate.i|GET /api/health_check|]]
            , E.text [Interpolate.i| answers 204 while the process is up.|]
            ]
        ]
    ]
