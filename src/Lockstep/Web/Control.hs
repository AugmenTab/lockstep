{-# LANGUAGE OverloadedStrings #-}

{- | The control pane's HTTP surface (contract C-P3.1 §3): a content-free shell,
two static assets, a health check, and a small JSON API that takes the session
only from the @X-Lockstep-Session@ header. No cookie is read or set, and no
response carries CORS headers. Route recognition comes first (unrouted: 404),
then the exact Host/Origin guard of C-P1.3 E7, then the session.
-}
module Lockstep.Web.Control
  ( controlApplication
  , runControlPane
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (FilePath, hFlush, hPutStrLn, putStrLn, stderr, stdout)
import Text.Show (show)

import Lockstep.Application.ControlPane
  ( PaneRuntime
  , ResultView (..)
  , SubmitError (..)
  , checkSession
  , endSession
  , exchangeSignIn
  , openPane
  , paneIdentity
  , readResult
  , renderPaneError
  , submitInstall
  , submitLifecycle
  , submitRequest
  )
import Lockstep.Foundation.Config (BindHost (Loopback), Port, ServeConfig (..), portNumber)
import Lockstep.Foundation.ControlProtocol (ControlResult (..), outcomeName, parseOp, requestIdText)
import Lockstep.Foundation.InstallProtocol (InstallExpect, InstallOp, parseInstallExpect, parseInstallOp, validFor)
import Lockstep.Foundation.LifecycleProtocol (LifecycleOp, expectedFor, parseLifecycleExpect, parseLifecycleOp)
import Lockstep.Web.RequestGuard (RouteClass (..), guardRequest)
import Lockstep.Web.Server (serverSettings)
import Lockstep.Web.Static (StaticAsset (..), lookupAsset)

-- | @lockstep control serve@: checks the state directory, then serves until SIGTERM.
runControlPane :: Port -> FilePath -> IO ()
runControlPane port state = do
  opened <- openPane state
  case opened of
    Left err -> do
      hPutStrLn stderr ("lockstep: control pane: " <> renderPaneError err)
      exitWith (ExitFailure 66)
    Right runtime -> do
      let
        settings =
          Warp.setOnException (\_ _ -> pure ())
            . Warp.setBeforeMainLoop (putStrLn ("Control pane listening on 127.0.0.1:" <> show (portNumber port)) >> hFlush stdout)
            $ serverSettings (ServeConfig Loopback port)
      Warp.runSettings settings (controlApplication port runtime)

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

jsonResponse :: HTTP.Status -> T.Text -> Wai.Response
jsonResponse status body =
  respondWith status [(HTTP.hContentType, "application/json; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 body))

errorJson :: HTTP.Status -> T.Text -> Wai.Response
errorJson status code =
  jsonResponse status ("{\"error\":" <> jsonString code <> "}")

notFound :: Wai.Response
notFound =
  errorJson HTTP.status404 "not-found"

-- | A JSON string, with @<@, @>@ and @&@ escaped so no response can be read as markup.
jsonString :: T.Text -> T.Text
jsonString text =
  "\"" <> T.concatMap escape text <> "\""
 where
  escape c
    | c == '"' = "\\\""
    | c == '\\' = "\\\\"
    | c < ' ' || c > '~' || c `L.elem` ("<>&" :: String) = "\\u" <> T.justifyRight 4 '0' (T.pack (hex (Char.ord c)))
    | otherwise = T.singleton c
  hex n =
    let
      digits = "0123456789abcdef" :: String
      go 0 acc = acc
      go v acc = go (v `div` 16) (L.take 1 (L.drop (v `mod` 16) digits) <> acc)
    in
      if n == 0 then "0" else go n ""

-- | The shell every page address returns: no state, no data; the script loads the rest.
shell :: Wai.Response
shell =
  respondWith
    HTTP.status200
    [(HTTP.hContentType, "text/html; charset=utf-8")]
    ( LBS.fromStrict . BS8.pack . L.unlines $
        [ "<!doctype html>"
        , "<html lang=\"en\">"
        , "<head>"
        , "<meta charset=\"utf-8\">"
        , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        , "<title>Lockstep</title>"
        , "<link rel=\"stylesheet\" href=\"/static/lockstep.css\">"
        , "</head>"
        , "<body class=\"control\">"
        , "<main id=\"app\" class=\"control-main\" aria-live=\"polite\"><p>Opening Lockstep\226\128\166</p></main>"
        , "<noscript><p>Lockstep needs JavaScript turned on in this browser.</p></noscript>"
        , "<script src=\"/static/control.js\"></script>"
        , "</body>"
        , "</html>"
        ]
    )

data Route
  = Shell
  | Asset StaticAsset
  | Health
  | Session
  | SignOut
  | Requests
  | Lifecycle
  | Install
  | RequestResult T.Text
  | Preflight

isApi :: Route -> Bool
isApi route =
  case route of
    Shell -> False
    Asset _ -> False
    Health -> False
    _ -> True

matchRoute :: BS.ByteString -> [T.Text] -> Maybe Route
matchRoute method path =
  let
    get = method == HTTP.methodGet || method == HTTP.methodHead
    post = method == HTTP.methodPost
    options = method == HTTP.methodOptions
  in
    case path of
      [] | get -> Just Shell
      ["sign-in"] | get -> Just Shell
      ["static", name]
        | get && name `L.elem` ["control.js", "lockstep.css"] -> Asset <$> lookupAsset name
      ["api", "health"] | get -> Just Health
      ["api", "session"]
        | post -> Just Session
        | options -> Just Preflight
      ["api", "sign-out"]
        | post -> Just SignOut
        | options -> Just Preflight
      ["api", "requests"]
        | post -> Just Requests
        | options -> Just Preflight
      ["api", "lifecycle"]
        | post -> Just Lifecycle
        | options -> Just Preflight
      ["api", "install"]
        | post -> Just Install
        | options -> Just Preflight
      ["api", "requests", rid]
        | get && T.length rid == 32 && T.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) rid -> Just (RequestResult rid)
        | options -> Just Preflight
      _ -> Nothing

controlApplication :: Port -> PaneRuntime -> Wai.Application
controlApplication port runtime request respond =
  case matchRoute (Wai.requestMethod request) (Wai.pathInfo request) of
    Nothing -> respond notFound
    Just Preflight -> respond (errorJson HTTP.status405 "method-not-allowed")
    Just route ->
      case guardRequest port (if isApi route then OperatorRoute else PublicRead) request of
        Left _ -> respond (errorJson HTTP.status403 "refused")
        Right () -> handle route
 where
  sessionHeader =
    L.lookup "X-Lockstep-Session" (Wai.requestHeaders request)
  withSession action = do
    ok <- maybe (pure False) (checkSession runtime) sessionHeader
    if ok then action else respond (errorJson HTTP.status401 "signed-out")
  withBody action = do
    body <- readBodyLimited request 4096
    case body of
      Nothing -> respond (errorJson HTTP.status413 "too-large")
      Just bytes -> action bytes
  handle route =
    case route of
      Shell -> respond shell
      Asset asset -> respond (respondWith HTTP.status200 [(HTTP.hContentType, assetContentType asset)] (LBS.fromStrict (assetBody asset)))
      Health -> respond (respondWith HTTP.status204 [("X-Lockstep-Control", paneIdentity runtime)] "")
      Session -> withBody $ \bytes -> do
        session <- exchangeSignIn runtime (TE.decodeUtf8With TEE.lenientDecode bytes)
        respond $ case session of
          Just s -> jsonResponse HTTP.status200 ("{\"session\":" <> jsonString s <> "}")
          Nothing -> errorJson HTTP.status403 "sign-in-refused"
      SignOut -> withBody $ \_ -> withSession $ do
        traverse_ (endSession runtime) sessionHeader
        respond (respondWith HTTP.status204 [] "")
      Requests -> withBody $ \bytes -> withSession $
        case parseOp (TE.decodeUtf8With TEE.lenientDecode bytes) of
          Nothing -> respond (errorJson HTTP.status400 "unknown-operation")
          Just op -> do
            submitted <- submitRequest runtime op
            respond $ case submitted of
              Right rid -> jsonResponse HTTP.status202 ("{\"id\":" <> jsonString (requestIdText rid) <> "}")
              Left err -> submitError err
      Lifecycle -> withBody $ \bytes -> withSession $
        case parseLifecycleBody (TE.decodeUtf8With TEE.lenientDecode bytes) of
          Nothing -> respond (errorJson HTTP.status400 "unknown-operation")
          Just op -> do
            submitted <- submitLifecycle runtime op
            respond $ case submitted of
              Right rid -> jsonResponse HTTP.status202 ("{\"id\":" <> jsonString (requestIdText rid) <> "}")
              Left err -> submitError err
      Install -> withBody $ \bytes -> withSession $
        case parseInstallBody (TE.decodeUtf8With TEE.lenientDecode bytes) of
          Nothing -> respond (errorJson HTTP.status400 "unknown-operation")
          Just (op, expect) -> do
            submitted <- submitInstall runtime op expect
            respond $ case submitted of
              Right rid -> jsonResponse HTTP.status202 ("{\"id\":" <> jsonString (requestIdText rid) <> "}")
              Left err -> submitError err
      RequestResult rid -> withSession $ do
        view <- readResult runtime rid
        respond $ case view of
          ResultUnknown -> notFound
          ResultPending -> jsonResponse HTTP.status200 "{\"state\":\"pending\"}"
          ResultUntrusted -> jsonResponse HTTP.status200 "{\"state\":\"untrusted\"}"
          ResultDone result -> jsonResponse HTTP.status200 (resultJson result)
      Preflight -> respond (errorJson HTTP.status405 "method-not-allowed")

submitError :: SubmitError -> Wai.Response
submitError err =
  case err of
    HelperUnavailable -> errorJson HTTP.status503 "helper-unavailable"
    RequestNotWritten -> errorJson HTTP.status503 "request-not-written"
    LifecycleBusy -> errorJson HTTP.status409 "busy"

{- | @<operation> <expected state>@, exactly two words separated by one space,
where the expectation is the operation's own (C-P3.2 M2, M6).
-}
parseLifecycleBody :: T.Text -> Maybe LifecycleOp
parseLifecycleBody body =
  case T.splitOn " " body of
    [opText, expectText] -> do
      op <- parseLifecycleOp opText
      expect <- parseLifecycleExpect expectText
      if expect == expectedFor op then Just op else Nothing
    _ -> Nothing

-- | @<operation> <expectation>@ for an install request (C-P3.3 U1).
parseInstallBody :: T.Text -> Maybe (InstallOp, InstallExpect)
parseInstallBody body =
  case T.splitOn " " body of
    [opText, expectText] -> do
      op <- parseInstallOp opText
      expect <- parseInstallExpect expectText
      if validFor op expect then Just (op, expect) else Nothing
    _ -> Nothing

resultJson :: ControlResult -> T.Text
resultJson result =
  T.concat
    [ "{\"state\":\"done\""
    , ",\"id\":" <> jsonString (resultId result)
    , ",\"op\":" <> jsonString (resultOp result)
    , ",\"outcome\":" <> jsonString (outcomeName (resultOutcome result))
    , ",\"reason\":" <> maybe "null" jsonString (resultReason result)
    , ",\"started\":" <> T.pack (show (resultStarted result))
    , ",\"finished\":" <> T.pack (show (resultFinished result))
    , ",\"fields\":{" <> T.intercalate "," [jsonString k <> ":" <> jsonString v | (k, v) <- resultFields result] <> "}"
    , ",\"detail\":" <> jsonString (resultDetail result)
    , "}"
    ]

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
