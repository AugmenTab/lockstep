{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}

{- | @GET /@: a human-readable status page. It reports what this process knows
when the page is rendered: it is running, where it listens, and the database
readiness exactly as 'checkReadiness' found it (never better).
-}
module Lockstep.Web.Liveness
  ( Liveness (Liveness)
  , getLiveness
  , livenessPage
  ) where

import Beeline.Routing qualified as R
import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Brigid.HTML.Types qualified as HTML
import Data.String.Interpolate qualified as Interpolate
import Data.Text qualified as T
import Data.Time qualified as Time
import Flipstone.Prelude
import Orb qualified
import Shrubbery qualified
import Text.Show (show)

import Lockstep.Application.Database
  ( NotReadyReason (..)
  , Readiness (..)
  , ServiceStarts (..)
  , checkReadiness
  , readServiceStarts
  , readinessCode
  , revisionNumber
  )
import Lockstep.Foundation.Config (ServeConfig (..), bindHostAddress, portNumber)
import Lockstep.Web.Components.Page (page)
import Lockstep.Web.Handler.NoPermissionError (NoPermissionError)
import Lockstep.Web.Handler.NoUser (NoUser (NoUser))
import Lockstep.Web.Types (Lockstep, getConfig, getDatabase)

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
  db <- getDatabase
  readiness <- liftIO (checkReadiness db)
  starts <-
    case (readiness, db) of
      (Ready _, Just runtime) -> liftIO (readServiceStarts runtime)
      _ -> pure Nothing
  Orb.return200 $
    livenessPage
      (T.pack (bindHostAddress host <> ":" <> show (portNumber port)))
      readiness
      starts

livenessPage :: T.Text -> Readiness -> Maybe ServiceStarts -> E.HTML
livenessPage address readiness starts =
  page
    [Interpolate.i|Lockstep|]
    [ E.main
        []
        [ E.h1 [] [E.text [Interpolate.i|Lockstep is running|]]
        , E.p
            []
            [ E.text [Interpolate.i|Process liveness and database readiness, checked when this page was rendered.|]
            ]
        , E.dl
            [A.class_ (HTML.Class [Interpolate.i|ls-facts|])]
            ( [ E.dt [] [E.text [Interpolate.i|Process|]]
              , E.dd [] [E.text [Interpolate.i|Alive: this page was rendered by the running service.|]]
              , E.dt [] [E.text [Interpolate.i|Listening on|]]
              , E.dd [] [E.code [] [E.text address]]
              , E.dt [] [E.text [Interpolate.i|Database readiness|]]
              , E.dd
                  []
                  [ E.text (readinessSentence readiness)
                  , E.text [Interpolate.i| |]
                  , E.code [] [E.text (readinessCode readiness)]
                  ]
              ]
                <> startsFacts readiness starts
            )
        , E.p
            [A.class_ (HTML.Class [Interpolate.i|ls-muted|])]
            [ E.text [Interpolate.i|Machine checks: |]
            , E.code [] [E.text [Interpolate.i|GET /api/health_check|]]
            , E.text [Interpolate.i| answers 204 while the process is up; |]
            , E.code [] [E.text [Interpolate.i|GET /api/readiness|]]
            , E.text [Interpolate.i| answers 200 only at this binary's schema revision.|]
            ]
        ]
    ]

readinessSentence :: Readiness -> T.Text
readinessSentence readiness =
  case readiness of
    Ready revision ->
      "Ready: the database is ready at schema revision " <> T.pack (show (revisionNumber revision)) <> "."
    NotReady DatabaseNotConfigured ->
      "Not checked: no database is configured (LOCKSTEP_CONFIG is not set)."
    NotReady reason ->
      "Not ready: " <> reasonSentence reason <> "."

reasonSentence :: NotReadyReason -> T.Text
reasonSentence reason =
  case reason of
    DatabaseNotConfigured -> "no database is configured"
    DatabaseUnreachable -> "the database server cannot be reached"
    AuthenticationFailed -> "the database rejected the configured credentials"
    DatabaseMissing -> "the configured database does not exist"
    SchemaBehind n -> T.pack (show n) <> " migration(s) pending; run lockstep db migrate"
    SchemaInvalid _ -> "the schema does not match this binary's migrations; nothing will be applied"
    DatabaseError -> "the database returned an unexpected error"

startsFacts :: Readiness -> Maybe ServiceStarts -> [E.ChildHTML E.DescriptionList grandparent]
startsFacts readiness starts =
  case readiness of
    NotReady _ ->
      []
    Ready _ ->
      [ E.dt [] [E.text [Interpolate.i|Service starts|]]
      , E.dd [] [E.text (startsSentence starts)]
      ]

startsSentence :: Maybe ServiceStarts -> T.Text
startsSentence starts =
  case starts of
    Nothing ->
      "Service starts recorded: 0."
    Just (ServiceStarts n latest) ->
      "Service starts recorded: "
        <> T.pack (show n)
        <> " (latest "
        <> T.pack (Time.formatTime Time.defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC" latest)
        <> ")."
