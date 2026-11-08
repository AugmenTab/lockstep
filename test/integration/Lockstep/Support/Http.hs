{- | Raw HTTP requests to the running service with chosen headers, no
redirect following and no cookie jar, so every header the server sends and
every header the test sends is visible.
-}
module Lockstep.Support.Http
  ( HttpResponse (..)
  , httpRequest
  , responseHeader
  , responseHeaders
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Flipstone.Prelude
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types qualified as HTTPTypes
import Text.Show (Show, show)

data HttpResponse
  = HttpResponse
  { responseStatus :: Int
  , responseHeaderList :: [HTTPTypes.Header]
  , responseBody :: BS.ByteString
  }
  deriving (Show)

{- | Sends one request to @127.0.0.1:port@. A @Host@ header in the list
replaces the one http-client would send. Never throws on a status code.
-}
httpRequest :: Int -> HTTPTypes.Method -> String -> [HTTPTypes.Header] -> BS.ByteString -> IO HttpResponse
httpRequest port method path headers body = do
  manager <- HTTP.newManager HTTP.defaultManagerSettings
  base <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)
  let
    request =
      base
        { HTTP.method = method
        , HTTP.requestHeaders = headers
        , HTTP.requestBody = HTTP.RequestBodyBS body
        , HTTP.redirectCount = 0
        }
  response <- HTTP.httpLbs request manager
  pure
    HttpResponse
      { responseStatus = HTTPTypes.statusCode (HTTP.responseStatus response)
      , responseHeaderList = HTTP.responseHeaders response
      , responseBody = LBS.toStrict (HTTP.responseBody response)
      }

responseHeader :: HTTPTypes.HeaderName -> HttpResponse -> Maybe BS.ByteString
responseHeader name =
  L.lookup name . responseHeaderList

-- | Every value of a header that may repeat (Set-Cookie).
responseHeaders :: HTTPTypes.HeaderName -> HttpResponse -> [BS.ByteString]
responseHeaders name response =
  [v | (k, v) <- responseHeaderList response, k == name]
