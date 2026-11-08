{-# LANGUAGE OverloadedStrings #-}

{- | Responses for the header-session pages (contracts C-P3.1 §3 and C-P3.4): the
same security headers, JSON bodies encoded by their json-fleece schemas and
made markup-safe ("Lockstep.Web.Json"), and a request body read up to a limit.
Used by the control pane and the application shell.
-}
module Lockstep.Web.SecureResponse
  ( contentSecurityPolicy
  , securityHeaders
  , respondWith
  , jsonResponse
  , errorJson
  , htmlResponse
  , readBodyLimited
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fleece.Aeson qualified as FA
import Fleece.Core qualified as FC
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai

import Lockstep.Web.Json (ErrorBody (..), encodeBody, errorSchema)

contentSecurityPolicy :: BS.ByteString
contentSecurityPolicy =
  "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

securityHeaders :: [HTTP.Header]
securityHeaders =
  [ ("Content-Security-Policy", contentSecurityPolicy)
  , ("Cache-Control", "no-store")
  , ("X-Content-Type-Options", "nosniff")
  , ("Referrer-Policy", "no-referrer")
  , ("X-Frame-Options", "DENY")
  , ("Cross-Origin-Opener-Policy", "same-origin")
  , ("Cross-Origin-Resource-Policy", "same-origin")
  ]

respondWith :: HTTP.Status -> [HTTP.Header] -> LBS.ByteString -> Wai.Response
respondWith status headers =
  Wai.responseLBS status (headers <> securityHeaders)

-- | A JSON response: the body encoded by its schema, markup-safe.
jsonResponse :: HTTP.Status -> FC.Schema FA.Encoder a -> a -> Wai.Response
jsonResponse status schema body =
  respondWith status [(HTTP.hContentType, "application/json; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 (encodeBody schema body)))

-- | @{"error": code}@.
errorJson :: HTTP.Status -> T.Text -> Wai.Response
errorJson status code =
  jsonResponse status errorSchema (ErrorBody code)

htmlResponse :: HTTP.Status -> LBS.ByteString -> Wai.Response
htmlResponse status =
  respondWith status [(HTTP.hContentType, "text/html; charset=utf-8")]

-- | The request body, or 'Nothing' if it is longer than the limit.
readBodyLimited :: Wai.Request -> Int -> IO (Maybe BS.ByteString)
readBodyLimited request limit =
  let
    go acc size = do
      chunk <- Wai.getRequestBodyChunk request
      if BS.null chunk
        then pure (Just (BS.concat (L.reverse acc)))
        else
          let
            size' = size + BS.length chunk
          in
            if size' > limit then pure Nothing else go (chunk : acc) size'
  in
    go [] 0
