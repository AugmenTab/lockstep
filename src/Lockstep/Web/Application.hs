{-# LANGUAGE QuasiQuotes #-}

{- | The WAI application. Derived from Launchpad.REPL.app (11886bf), with
maintenance mode and external error reporting removed (C-P1.1 D8),
static assets added, and the operator routes and request guard of C-P1.3 E7:
route recognition first (unrouted: 404, nothing runs), then Host/Origin.
-}
module Lockstep.Web.Application
  ( application
  , applicationWith
  ) where

import Beeline.Routing qualified as R
import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Control.Exception (SomeException)
import Data.ByteString.Lazy qualified as LBS
import Data.String.Interpolate qualified as Interpolate
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import System.Log.FastLogger qualified as FL
import Text.Show (show)
import UnliftIO qualified

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Foundation.Config (ServeConfig (..))
import Lockstep.Web.App (appRouteClass, handleApp, matchAppRoute)
import Lockstep.Web.Components.Page404 (page404)
import Lockstep.Web.Operator (guardRefusalResponse, handleOperator, matchOperatorRoute)
import Lockstep.Web.RequestGuard (RouteClass (..), guardRequest)
import Lockstep.Web.Routes (dispatch, routes)
import Lockstep.Web.SecureResponse (errorJson)
import Lockstep.Web.Static (StaticAsset (..), lookupAsset, staticRootPath)
import Lockstep.Web.Types (AppContext (..), Lockstep, getConfig, getDatabase, log, runLockstep)

-- | The application with no database configured (readiness: not checked).
application :: ServeConfig -> (FL.LogStr -> IO ()) -> Wai.Application
application serveConfig =
  applicationWith serveConfig Nothing

applicationWith ::
  ServeConfig ->
  Maybe DatabaseRuntime ->
  (FL.LogStr -> IO ()) ->
  Wai.Application
applicationWith serveConfig db appLogger request respond =
  let
    ctx =
      AppContext
        { config = serveConfig
        , database = db
        , request = request
        , respond = respond
        , logger = appLogger
        }
  in
    runLockstep ctx (handleRequest request respond)

handleRequest ::
  Wai.Request ->
  (Wai.Response -> IO Wai.ResponseReceived) ->
  Lockstep Wai.ResponseReceived
handleRequest request respond = do
  port <- getConfig servePort
  db <- getDatabase
  let
    guarded routeClass action =
      case guardRequest port routeClass request of
        Left refusal -> liftIO . respond $ guardRefusalResponse refusal
        Right () -> logExceptions action
  case HTTP.parseMethod (Wai.requestMethod request) of
    Left _err ->
      liftIO $ respond notFound
    Right method ->
      case (method, Wai.pathInfo request) of
        (HTTP.GET, [segment, name])
          | segment == staticRootPath ->
              case lookupAsset name of
                Nothing -> liftIO $ respond notFound
                Just asset -> guarded PublicRead (liftIO . respond $ staticResponse asset)
        -- C-P3.4 A1 (verification note): the application exists only with a database
        -- configured; without one, /app… stays 404 as C-P1.1 requires.
        _
          | Just _ <- db
          , Just route <- matchAppRoute (Wai.requestMethod request) (Wai.pathInfo request) ->
              case guardRequest port (appRouteClass route) request of
                Left _ -> liftIO . respond $ errorJson HTTP.status403 [Interpolate.i|refused|]
                Right () -> logExceptions (liftIO (handleApp db route request >>= respond))
        _ ->
          case matchOperatorRoute (Wai.requestMethod request) (Wai.pathInfo request) of
            Just route ->
              guarded OperatorRoute (liftIO (handleOperator db route request >>= respond))
            Nothing ->
              case R.recognizeRoute routes method (Wai.pathInfo request) of
                Left _err ->
                  liftIO $ respond notFound
                Right route ->
                  guarded PublicRead (dispatch route)

logExceptions :: Lockstep a -> Lockstep a
logExceptions action = do
  errOrRes <- UnliftIO.try action
  case errOrRes of
    Left err -> do
      log $ "EXCEPTION app: " <> show (err :: SomeException)
      UnliftIO.throwIO err
    Right res ->
      pure res

staticResponse :: StaticAsset -> Wai.Response
staticResponse asset =
  Wai.responseLBS
    HTTP.status200
    [(HTTP.hContentType, assetContentType asset)]
    (LBS.fromStrict (assetBody asset))

notFound :: Wai.Response
notFound =
  Wai.responseLBS
    HTTP.status404
    [(HTTP.hContentType, htmlContentType)]
    (renderLazyHTML page404)
 where
  htmlContentType = [Interpolate.i|text/html; charset=utf-8|]
