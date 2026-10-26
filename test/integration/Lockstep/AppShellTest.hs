{-# LANGUAGE OverloadedStrings #-}

{- | The application shell over real HTTP (contract C-P3.4 A1–A7): the real
service with a real, migrated PostgreSQL database; the one-time token comes
from the real CLI (@operator sign-in@), as the helper's hand-over gets it.
-}
module Lockstep.AppShellTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (isNothing)
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Exit (ExitCode (ExitSuccess))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Postgres (AdminSettings (..), requireAdmin, withFreshDatabase, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data Svc
  = Svc
  { svcPort :: Int
  , svcEnv :: [(String, String)]
  }

expectedCsp :: BS.ByteString
expectedCsp =
  "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

sections :: [String]
sections =
  ["home", "projects", "tasks", "decisions", "activity", "settings", "advanced"]

-- | A migrated database and a running service; the action gets its port and environment.
withApp :: (Svc -> IO a) -> IO a
withApp action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-app" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      let
        env = [("LOCKSTEP_CONFIG", path)]
      (code, _, err) <- runLockstep env ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      port <- freePort
      (result, _) <- withService env port (dir <> "/serve.log") (action (Svc port env))
      pure result

origin :: Svc -> BS.ByteString
origin svc =
  "http://127.0.0.1:" <> BS8.pack (show (svcPort svc))

-- | A one-time token from the real CLI, as the helper's hand-over obtains it (A3).
cliToken :: Svc -> IO BS.ByteString
cliToken svc = do
  (code, out, err) <- runLockstep (svcEnv svc) ["operator", "sign-in", "--port", show (svcPort svc)]
  code @?= ExitSuccess
  case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
    Just token | L.length token == 43 -> pure (BS8.pack token)
    _ -> assertFailure ("unexpected sign-in output: " <> out <> err)

exchange :: Svc -> [HTTPTypes.Header] -> BS.ByteString -> IO HttpResponse
exchange svc =
  httpRequest (svcPort svc) "POST" "/app/api/session"

signIn :: Svc -> IO BS.ByteString
signIn svc = do
  token <- cliToken svc
  resp <- exchange svc [("Origin", origin svc)] token
  responseStatus resp @?= 200
  let
    value = BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp))))
  BS.length value @?= 43
  pure value

fragment :: Svc -> String -> [HTTPTypes.Header] -> IO HttpResponse
fragment svc section headers =
  httpRequest (svcPort svc) "GET" ("/app/fragments/" <> section) headers ""

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

noCookie :: String -> HttpResponse -> Assertion
noCookie label resp =
  assertBool (label <> ": sent Set-Cookie") (isNothing (responseHeader "Set-Cookie" resp))

tests :: TestTree
tests =
  testGroup
    "application shell over HTTP (C-P3.4)"
    [ testCase "every section address returns the same content-free shell with the exact CSP" $
        withApp $ \svc ->
          traverse_
            ( \path -> do
                resp <- httpRequest (svcPort svc) "GET" path [] ""
                responseStatus resp @?= 200
                responseHeader "Content-Security-Policy" resp @?= Just expectedCsp
                responseHeader "Cache-Control" resp @?= Just "no-store"
                responseHeader "X-Frame-Options" resp @?= Just "DENY"
                noCookie path resp
                let
                  body = responseBody resp
                assertBool (path <> ": does not load app.js") (contains "<script src=\"/static/app.js\"></script>" body)
                assertBool (path <> ": does not load htmx") (contains "<script src=\"/static/htmx.min.js\"></script>" body)
                assertBool (path <> ": htmx may evaluate code") (contains "\"allowEval\":false" body)
                assertBool (path <> ": has an inline script") (not (contains "<script>" body))
                assertBool (path <> ": contains data") (not (contains "schema revision" body))
            )
            (["/app", "/app/sign-in"] <> fmap ("/app/" <>) sections)
    , testCase "the vendored htmx is the pinned file" $
        withApp $ \svc -> do
          resp <- httpRequest (svcPort svc) "GET" "/static/htmx.min.js" [] ""
          responseStatus resp @?= 200
          assertBool "not htmx 2.0.4" (contains "2.0.4" (responseBody resp))
    , testCase "anything else under /app is 404" $
        withApp $ \svc ->
          traverse_
            ( \path -> do
                resp <- httpRequest (svcPort svc) "GET" path [] ""
                assertBool (path <> " gave " <> show (responseStatus resp)) (responseStatus resp == 404)
            )
            ["/app/admin", "/app/home/x", "/app/fragments/admin", "/app/fragments/../operator", "/app/api/requests"]
    , testCase "the one-time token works once, only from this service's origin" $
        withApp $ \svc -> do
          token <- cliToken svc
          traverse_
            ( \headers -> do
                resp <- exchange svc headers token
                assertBool (show headers <> " gave " <> show (responseStatus resp)) (responseStatus resp == 403)
            )
            [[], [("Origin", "null")], [("Origin", "http://127.0.0.1:1")], [("Origin", "http://localhost:" <> BS8.pack (show (svcPort svc)))]]
          ok <- exchange svc [("Origin", origin svc)] token
          responseStatus ok @?= 200
          noCookie "exchange" ok
          replay <- exchange svc [("Origin", origin svc)] token
          responseStatus replay @?= 403
          bad <- exchange svc [("Origin", origin svc)] (BS.replicate 43 0x41)
          responseStatus bad @?= 403
    , testCase "fragments need the session header; a cookie carrying the session is ignored" $
        withApp $ \svc -> do
          session <- signIn svc
          none <- fragment svc "home" []
          responseStatus none @?= 401
          asCookie <- fragment svc "home" [("Cookie", "lockstep_session=" <> session)]
          responseStatus asCookie @?= 401
          wrong <- fragment svc "home" [("X-Lockstep-Session", BS.replicate 43 0x42)]
          responseStatus wrong @?= 401
          foreignHost <- fragment svc "home" [("X-Lockstep-Session", session), ("Host", "attacker.example:" <> BS8.pack (show (svcPort svc)))]
          responseStatus foreignHost @?= 403
          traverse_
            ( \s -> do
                resp <- fragment svc s [("X-Lockstep-Session", session)]
                assertBool (s <> " gave " <> show (responseStatus resp)) (responseStatus resp == 200)
                fmap ("text/html" `BS.isPrefixOf`) (responseHeader "Content-Type" resp) @?= Just True
                noCookie s resp
            )
            sections
    , testCase "Home shows the observed state, never invented progress" $
        withApp $ \svc -> do
          session <- signIn svc
          resp <- fragment svc "home" [("X-Lockstep-Session", session)]
          let
            body = responseBody resp
          assertBool ("no readiness: " <> show body) (contains "ready" body)
          assertBool ("no workspace name: " <> show body) (contains "Lockstep" body)
          assertBool "a percentage is shown" (not (contains "%" body))
          assertBool "an ETA is shown" (not (contains "ETA" body) && not (contains "estimated" body))
    , testCase "text from the database is escaped in fragments" $
        withApp $ \svc -> do
          (_, shown, _) <- runLockstep (svcEnv svc) ["workspace", "show"]
          let
            revision = L.concat [L.drop 10 l | l <- L.lines shown, "revision: " `L.isPrefixOf` l]
          (code, _, err) <- runLockstep (svcEnv svc) ["workspace", "rename", "--expected-revision", revision, "<script>alert(1)</script>"]
          assertBool ("rename failed: " <> err) (code == ExitSuccess)
          session <- signIn svc
          resp <- fragment svc "home" [("X-Lockstep-Session", session)]
          let
            body = responseBody resp
          assertBool "markup from the database was not escaped" (not (contains "<script>alert(1)</script>" body))
          assertBool ("the name is missing: " <> show body) (contains "&lt;script&gt;alert(1)&lt;/script&gt;" body)
    , testCase "sections not built yet say so and offer no buttons" $
        withApp $ \svc -> do
          session <- signIn svc
          traverse_
            ( \s -> do
                resp <- fragment svc s [("X-Lockstep-Session", session)]
                assertBool (s <> " has a button") (not (contains "<button" (responseBody resp)))
                assertBool (s <> " has a form") (not (contains "<form" (responseBody resp)))
                assertBool (s <> " does not say it is coming: " <> show (responseBody resp)) (contains "later update" (responseBody resp))
            )
            ["projects", "tasks", "decisions"]
    , testCase "Advanced shows the exact facts" $
        withApp $ \svc -> do
          session <- signIn svc
          resp <- fragment svc "advanced" [("X-Lockstep-Session", session)]
          assertBool ("no schema revision: " <> show (responseBody resp)) (contains "Schema revision" (responseBody resp))
          assertBool "no session expiry" (contains "Session expires" (responseBody resp))
    , testCase "sign-out ends the session" $
        withApp $ \svc -> do
          session <- signIn svc
          out <- httpRequest (svcPort svc) "POST" "/app/api/sign-out" [("Origin", origin svc), ("X-Lockstep-Session", session)] ""
          responseStatus out @?= 204
          after <- fragment svc "home" [("X-Lockstep-Session", session)]
          responseStatus after @?= 401
          elsewhere <- httpRequest (svcPort svc) "POST" "/app/api/sign-out" [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", session)] ""
          responseStatus elsewhere @?= 403
    , testCase "the Phase 1/2 pages and the status page are unchanged" $
        withApp $ \svc -> do
          root <- httpRequest (svcPort svc) "GET" "/" [] ""
          responseStatus root @?= 200
          assertBool "the status page changed" (contains "liveness" (responseBody root))
          operator <- httpRequest (svcPort svc) "GET" "/operator" [] ""
          responseStatus operator @?= 401
    , testCase "a body over 4 KiB is refused" $
        withApp $ \svc -> do
          resp <- exchange svc [("Origin", origin svc)] (BS.replicate 5000 0x41)
          responseStatus resp @?= 413
    ]
