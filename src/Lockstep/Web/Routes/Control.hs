{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The control pane's route tree (contract C-P3.1 §3, C-P3.2 to C-P3.5): the
shell, its two static assets, the health check and the JSON API. Each API path
is defined once and used for its method and for the OPTIONS request a browser
may send before it (answered 405: the pane never answers CORS). The addresses
are the frozen ones.
-}
module Lockstep.Web.Routes.Control
  ( Routes
  , routes
  , ShellRoutes
  , PaneHome (..)
  , PaneSignIn (..)
  , ControlAsset (..)
  , controlAssetName
  , Asset (..)
  , Health (..)
  , ApiRoutes
  , Session (..)
  , SignOut (..)
  , Requests (..)
  , Lifecycle (..)
  , Install (..)
  , OpenApplication (..)
  , FoldersList (..)
  , FoldersAdd (..)
  , Handover (..)
  , RequestResult (..)
  , PreflightRoutes
  ) where

import Beeline.Routing ((/+), (/-), (/:), (/>))
import Beeline.Routing qualified as R
import Data.Text qualified as T
import Flipstone.Prelude
import Shrubbery qualified

import Lockstep.Foundation.ControlProtocol (RequestId, parseRequestId, requestIdText)

type Routes =
  Shrubbery.Union
    [ ShellRoutes
    , Asset
    , Health
    , ApiRoutes
    , PreflightRoutes
    ]

routes :: R.Router r => r Routes
routes =
  R.routeList $
    (R.make id /> R.Subrouter shellRoutes id)
      /: R.get (R.make Asset /- "static" /+ R.Param controlAssetParam assetName)
      /: R.get (api Health /- "health")
      /: (R.make id /> R.Subrouter apiRoutes id)
      /: (R.make id /> R.Subrouter preflightRoutes id)
      /: R.emptyRoutes

api :: R.Router r => a -> R.Builder r route a
api con =
  R.make con /- "api"

-- * The shell

type ShellRoutes =
  Shrubbery.Union
    [ PaneHome
    , PaneSignIn
    ]

shellRoutes :: R.Router r => r ShellRoutes
shellRoutes =
  R.routeList $
    R.get (R.make PaneHome)
      /: R.get (R.make PaneSignIn /- "sign-in")
      /: R.emptyRoutes

data PaneHome = PaneHome

data PaneSignIn = PaneSignIn

-- | The pane's own assets: its script and the stylesheet (nothing else of the allowlist).
data ControlAsset
  = ControlScript
  | ControlStylesheet
  deriving (Eq, Enum, Bounded)

controlAssetName :: ControlAsset -> T.Text
controlAssetName asset =
  case asset of
    ControlScript -> "control.js"
    ControlStylesheet -> "lockstep.css"

controlAssetParam :: R.ParameterDefinition ControlAsset
controlAssetParam =
  R.boundedEnumParam controlAssetName "asset"

newtype Asset = Asset {assetName :: ControlAsset}

data Health = Health

-- * The API

type ApiRoutes =
  Shrubbery.Union
    [ Session
    , SignOut
    , Requests
    , Lifecycle
    , Install
    , OpenApplication
    , FoldersList
    , FoldersAdd
    , Handover
    , RequestResult
    ]

apiRoutes :: R.Router r => r ApiRoutes
apiRoutes =
  R.routeList $
    R.post (sessionPath Session)
      /: R.post (signOutPath SignOut)
      /: R.post (requestsPath Requests)
      /: R.post (lifecyclePath Lifecycle)
      /: R.post (installPath Install)
      /: R.post (openApplicationPath OpenApplication)
      /: R.get (foldersPath FoldersList)
      /: R.post (foldersPath FoldersAdd)
      /: R.get (handoverPath Handover handoverId)
      /: R.get (requestPath RequestResult requestResultId)
      /: R.emptyRoutes

sessionPath :: R.Router r => route -> R.Builder r route route
sessionPath route =
  api route /- "session"

signOutPath :: R.Router r => route -> R.Builder r route route
signOutPath route =
  api route /- "sign-out"

requestsPath :: R.Router r => route -> R.Builder r route route
requestsPath route =
  api route /- "requests"

lifecyclePath :: R.Router r => route -> R.Builder r route route
lifecyclePath route =
  api route /- "lifecycle"

installPath :: R.Router r => route -> R.Builder r route route
installPath route =
  api route /- "install"

openApplicationPath :: R.Router r => route -> R.Builder r route route
openApplicationPath route =
  api route /- "open-application"

foldersPath :: R.Router r => route -> R.Builder r route route
foldersPath route =
  api route /- "folders"

-- | A request id: 32 lowercase hex digits (C-P3.1 §3).
requestIdParam :: R.ParameterDefinition RequestId
requestIdParam =
  R.convertParam
    (Just "request-id")
    (maybe (Left "not a request id") Right . parseRequestId)
    requestIdText
    (R.textParam "requestId")

handoverPath :: R.Router r => (RequestId -> a) -> (a -> RequestId) -> R.Builder r a a
handoverPath con acc =
  api con /- "handover" /+ R.Param requestIdParam acc

requestPath :: R.Router r => (RequestId -> a) -> (a -> RequestId) -> R.Builder r a a
requestPath con acc =
  api con /- "requests" /+ R.Param requestIdParam acc

data Session = Session

data SignOut = SignOut

data Requests = Requests

data Lifecycle = Lifecycle

data Install = Install

data OpenApplication = OpenApplication

data FoldersList = FoldersList

data FoldersAdd = FoldersAdd

newtype Handover = Handover {handoverId :: RequestId}

newtype RequestResult = RequestResult {requestResultId :: RequestId}

-- * Preflight: every API address, OPTIONS

data Preflight = Preflight

newtype PreflightItem = PreflightItem {preflightItem :: RequestId}

type PreflightRoutes =
  Shrubbery.Union
    [ Preflight
    , Preflight
    , Preflight
    , Preflight
    , Preflight
    , Preflight
    , Preflight
    , PreflightItem
    , PreflightItem
    ]

preflightRoutes :: R.Router r => r PreflightRoutes
preflightRoutes =
  R.routeList $
    R.options (sessionPath Preflight)
      /: R.options (signOutPath Preflight)
      /: R.options (requestsPath Preflight)
      /: R.options (lifecyclePath Preflight)
      /: R.options (installPath Preflight)
      /: R.options (openApplicationPath Preflight)
      /: R.options (foldersPath Preflight)
      /: R.options (handoverPath PreflightItem preflightItem)
      /: R.options (requestPath PreflightItem preflightItem)
      /: R.emptyRoutes
