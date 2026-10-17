{-# LANGUAGE QuasiQuotes #-}

{- | The WAI application. Derived from Launchpad.REPL.app (11886bf), with
maintenance mode and external error reporting removed (C-P1.1 D8) and
-- static assets added.
-}
module Lockstep.Web.Application
  ( application
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

import Lockstep.Foundation.Config (ServeConfig)
import Lockstep.Foundation.Types (AppContext (..), Lockstep, log, runLockstep)
import Lockstep.Web.Components.Page404 (page404)
import Lockstep.Web.Routes (dispatch, routes)
import Lockstep.Web.Static (StaticAsset (..), lookupAsset, staticRootPath)

application :: ServeConfig -> (FL.LogStr -> IO ()) -> Wai.Application
application serveConfig appLogger request respond =
  let
    ctx =
      AppContext
        { config = serveConfig
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
handleRequest request respond =
  case HTTP.parseMethod (Wai.requestMethod request) of
    Left _err ->
      liftIO $ respond notFound
    Right method ->
      case (method, Wai.pathInfo request) of
        (HTTP.GET, [segment, name])
          | segment == staticRootPath ->
              liftIO . respond $ maybe notFound staticResponse (lookupAsset name)
        _ ->
          case R.recognizeRoute routes method (Wai.pathInfo request) of
            Left _err ->
              liftIO $ respond notFound
            Right route -> do
              errOrRes <- UnliftIO.try $ dispatch route
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
