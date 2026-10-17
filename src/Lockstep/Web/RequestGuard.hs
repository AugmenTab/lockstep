{-# LANGUAGE OverloadedStrings #-}

{- | Host and Origin checks for every routed request (contract C-P1.3 E7,
decisions D-1a and D-2d). Pure: the caller has already matched the route.
-}
module Lockstep.Web.RequestGuard
  ( GuardRefusal (..)
  , RouteClass (..)
  , guardRequest
  , isSafeMethod
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Text.Show (Show)

import Lockstep.Foundation.Config (Port, loopbackAuthority, loopbackOrigin)

data GuardRefusal
  = HostRefused
  | OriginRefused
  deriving (Eq, Show)

{- | 'PublicRead' routes carry no secrets: @/@, the health and readiness
checks, static assets. Every @/operator@ route is 'OperatorRoute'.
-}
data RouteClass
  = PublicRead
  | OperatorRoute
  deriving (Eq, Show)

isSafeMethod :: HTTP.Method -> Bool
isSafeMethod method =
  method == HTTP.methodGet || method == HTTP.methodHead

{- | A present @Host@ must be exactly the loopback authority; a missing one is
tolerated only on a 'PublicRead' GET/HEAD. Every other method needs exactly
one @Origin@ equal to the loopback origin, with no exception.
-}
guardRequest :: Port -> RouteClass -> Wai.Request -> Either GuardRefusal ()
guardRequest port routeClass request =
  let
    safe = isSafeMethod (Wai.requestMethod request)
    hostOk =
      case headerValues "Host" request of
        [] -> safe && routeClass == PublicRead
        [value] -> value == BS8.pack (loopbackAuthority port)
        _ -> False
    originOk =
      safe || headerValues "Origin" request == [BS8.pack (loopbackOrigin port)]
  in
    if not hostOk
      then Left HostRefused
      else
        if not originOk
          then Left OriginRefused
          else Right ()

headerValues :: HTTP.HeaderName -> Wai.Request -> [BS.ByteString]
headerValues name request =
  [value | (key, value) <- Wai.requestHeaders request, key == name]
