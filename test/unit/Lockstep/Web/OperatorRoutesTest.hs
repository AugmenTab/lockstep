{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Web.OperatorRoutesTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Test qualified as WaiTest
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.Config (BindHost (Loopback), ServeConfig (..), defaultPort)
import Lockstep.Web.Application (application)

tests :: TestTree
tests =
  testGroup
    "Operator routes (no database)"
    [ testGroup
        "protected routes"
        [ testCase "GET /operator without a session answers 401 and says how to sign in" $ do
            res <- run (get "/operator")
            WaiTest.simpleStatus res @?= HTTP.status401
            assertContains "lockstep operator sign-in" (body res)
            assertOperatorHeaders "no-referrer" res
        , testCase "POST /operator/sign-out with exact Host and Origin but no session answers 401" $ do
            res <- run (post "/operator/sign-out" [exactOrigin] "csrf=x")
            WaiTest.simpleStatus res @?= HTTP.status401
            assertOperatorHeaders "no-referrer" res
        , testCase "a malformed Cookie header counts as no session (401, not 500)" $ do
            res <- run (getWith "/operator" [(HTTP.hCookie, "lockstep_session=%%%; ;=; \255\254")])
            WaiTest.simpleStatus res @?= HTTP.status401
        , testCase "a session cookie that is not a token counts as no session (401)" $ do
            res <- run (getWith "/operator" [(HTTP.hCookie, "lockstep_session=AAAA")])
            WaiTest.simpleStatus res @?= HTTP.status401
        ]
    , testGroup
        "request guard over the application"
        [ testCase "a foreign Host on GET / answers 403" $ do
            res <- run (rawGet "/" [("Host", "attacker.example:8000")])
            WaiTest.simpleStatus res @?= HTTP.status403
        , testCase "Host: localhost on GET /operator answers 403" $ do
            res <- run (rawGet "/operator" [("Host", "localhost:8000")])
            WaiTest.simpleStatus res @?= HTTP.status403
        , testCase "a missing Host on GET /operator answers 403 [D-1a]" $ do
            res <- run (rawGet "/operator" [])
            WaiTest.simpleStatus res @?= HTTP.status403
        , testCase "a missing Origin on POST /operator/sign-out answers 403" $ do
            res <- run (post "/operator/sign-out" [] "csrf=x")
            WaiTest.simpleStatus res @?= HTTP.status403
        , testCase "Origin: null on POST /operator/sign-in answers 403, even with Sec-Fetch-Site: same-origin [D-2d]" $ do
            res <- run (post "/operator/sign-in" [("Origin", "null"), ("Sec-Fetch-Site", "same-origin")] ("token=" <> validToken))
            WaiTest.simpleStatus res @?= HTTP.status403
            assertLacks validToken (body res)
        , testCase "an unrouted operator path answers 404 whatever its headers" $ do
            a <- run (rawPost "/operator" [] "")
            WaiTest.simpleStatus a @?= HTTP.status404
            b <- run (get "/operator/sign-out")
            WaiTest.simpleStatus b @?= HTTP.status404
            c <- run (rawGet "/operator/frob" [("Host", "attacker.example")])
            WaiTest.simpleStatus c @?= HTTP.status404
        ]
    , testGroup
        "sign-in confirm page"
        [ testCase "GET /operator/sign-in with a well-formed token renders a confirm form (200)" $ do
            res <- run (get ("/operator/sign-in?token=" <> validToken))
            WaiTest.simpleStatus res @?= HTTP.status200
            assertContentType "text/html" res
        , testCase "the confirm page is no-store with Referrer-Policy: origin [D-2d] and the E3 CSP" $ do
            res <- run (get ("/operator/sign-in?token=" <> validToken))
            header "Cache-Control" res @?= Just "no-store"
            header "Referrer-Policy" res @?= Just "origin"
            header "Content-Security-Policy" res
              @?= Just "default-src 'none'; style-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
        , testCase "the token appears exactly once, in a hidden input named token" $ do
            res <- run (get ("/operator/sign-in?token=" <> validToken))
            let
              page = body res
            occurrences validToken page @?= 1
            tag <- enclosingInput validToken page
            assertContains "hidden" (lower tag)
            assertContains "\"token\"" tag
        , testCase "the confirm form posts to /operator/sign-in" $ do
            res <- run (get ("/operator/sign-in?token=" <> validToken))
            assertContains "/operator/sign-in" (body res)
            assertContains "post" (lower (body res))
        , testCase "the confirm page loads nothing external and links nowhere external" $ do
            res <- run (get ("/operator/sign-in?token=" <> validToken))
            let
              page = lower (body res)
            traverse_ (`assertLacks` page) externalReferences
        , testCase "the token is in no response header" $ do
            res <- run (get ("/operator/sign-in?token=" <> validToken))
            assertBool "token in a header" (not (any (BS.isInfixOf validToken . snd) (WaiTest.simpleHeaders res)))
        , testCase "a malformed token answers 400 without echoing it" $ do
            res <- run (get "/operator/sign-in?token=not-a-token-PROBE")
            WaiTest.simpleStatus res @?= HTTP.status400
            assertLacks "PROBE" (body res)
            assertOperatorHeaders "no-referrer" res
        , testCase "a missing token answers 400" $ do
            res <- run (get "/operator/sign-in")
            WaiTest.simpleStatus res @?= HTTP.status400
        , testCase "POST /operator/sign-in without a database answers 503 without echoing the token" $ do
            res <- run (post "/operator/sign-in" [exactOrigin] ("token=" <> validToken))
            WaiTest.simpleStatus res @?= HTTP.status503
            assertLacks validToken (body res)
            assertBool "token in a header" (not (any (BS.isInfixOf validToken . snd) (WaiTest.simpleHeaders res)))
            assertOperatorHeaders "no-referrer" res
        ]
    , testGroup
        "P1.1 and P1.2 routes with a browser Host"
        [ testCase "GET / answers 200" $ do
            res <- run (get "/")
            WaiTest.simpleStatus res @?= HTTP.status200
        , testCase "GET /api/health_check answers 204" $ do
            res <- run (get "/api/health_check")
            WaiTest.simpleStatus res @?= HTTP.status204
        , testCase "GET /static/lockstep.css answers 200" $ do
            res <- run (get "/static/lockstep.css")
            WaiTest.simpleStatus res @?= HTTP.status200
        ]
    ]

-- 32 bytes 0..31, unpadded base64url: a well-formed token that no database holds.
validToken :: BS.ByteString
validToken =
  "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

exactHost :: HTTP.Header
exactHost =
  ("Host", "127.0.0.1:8000")

exactOrigin :: HTTP.Header
exactOrigin =
  ("Origin", "http://127.0.0.1:8000")

externalReferences :: [BS.ByteString]
externalReferences =
  [ "src=\"http"
  , "src='http"
  , "src=\"//"
  , "src='//"
  , "href=\"http"
  , "href='http"
  , "href=\"//"
  , "href='//"
  , "action=\"http"
  , "action='http"
  , "action=\"//"
  , "action='//"
  , "<script"
  , "<iframe"
  , "<img"
  ]

testConfig :: ServeConfig
testConfig =
  ServeConfig Loopback defaultPort

run :: WaiTest.SRequest -> IO WaiTest.SResponse
run request =
  WaiTest.runSession (WaiTest.srequest request) (application testConfig (\_ -> pure ()))

build :: HTTP.Method -> BS.ByteString -> [HTTP.Header] -> LBS.ByteString -> WaiTest.SRequest
build method path headers requestBody =
  let
    base = WaiTest.setPath Wai.defaultRequest {Wai.requestMethod = method} path
  in
    WaiTest.SRequest
      base
        { Wai.requestHeaders = headers
        , Wai.requestHeaderHost = L.lookup "Host" headers
        }
      requestBody

rawGet :: BS.ByteString -> [HTTP.Header] -> WaiTest.SRequest
rawGet path headers =
  build HTTP.methodGet path headers LBS.empty

rawPost :: BS.ByteString -> [HTTP.Header] -> LBS.ByteString -> WaiTest.SRequest
rawPost =
  build HTTP.methodPost

get :: BS.ByteString -> WaiTest.SRequest
get path =
  rawGet path [exactHost]

getWith :: BS.ByteString -> [HTTP.Header] -> WaiTest.SRequest
getWith path headers =
  rawGet path (exactHost : headers)

post :: BS.ByteString -> [HTTP.Header] -> BS.ByteString -> WaiTest.SRequest
post path headers form =
  rawPost
    path
    (exactHost : (HTTP.hContentType, "application/x-www-form-urlencoded") : headers)
    (LBS.fromStrict form)

body :: WaiTest.SResponse -> BS.ByteString
body =
  LBS.toStrict . WaiTest.simpleBody

header :: HTTP.HeaderName -> WaiTest.SResponse -> Maybe BS.ByteString
header name =
  L.lookup name . WaiTest.simpleHeaders

lower :: BS.ByteString -> BS.ByteString
lower =
  BS8.map Char.toLower

occurrences :: BS.ByteString -> BS.ByteString -> Int
occurrences needle haystack =
  let
    (_, rest) = BS.breakSubstring needle haystack
  in
    if BS.null rest
      then 0
      else 1 + occurrences needle (BS.drop (BS.length needle) rest)

-- | The text of the @<input ...>@ tag that contains the needle.
enclosingInput :: BS.ByteString -> BS.ByteString -> IO BS.ByteString
enclosingInput needle haystack =
  let
    (before, rest) = BS.breakSubstring needle haystack
    (_, openTag) = breakLast "<input" before
    closing = BS8.takeWhile (/= '>') rest
  in
    if BS.null rest || BS.null openTag || BS8.elem '>' openTag
      then assertFailure "the token is not inside an <input> tag"
      else pure (openTag <> closing)

breakLast :: BS.ByteString -> BS.ByteString -> (BS.ByteString, BS.ByteString)
breakLast needle haystack =
  let
    go offset =
      let
        (_, rest) = BS.breakSubstring needle (BS.drop offset haystack)
      in
        if BS.null rest
          then Nothing
          else
            let
              found = BS.length haystack - BS.length rest
            in
              Just (fromMaybe found (go (found + 1)))
  in
    case go 0 of
      Nothing -> (haystack, BS.empty)
      Just i -> BS.splitAt i haystack

assertOperatorHeaders :: BS.ByteString -> WaiTest.SResponse -> Assertion
assertOperatorHeaders policy res = do
  header "Cache-Control" res @?= Just "no-store"
  header "Referrer-Policy" res @?= Just policy

assertContentType :: BS.ByteString -> WaiTest.SResponse -> Assertion
assertContentType expected res =
  case header HTTP.hContentType res of
    Nothing -> assertFailure "missing Content-Type header"
    Just value -> assertBool ("Content-Type " <> show value) (expected `BS.isPrefixOf` value)

assertContains :: BS.ByteString -> BS.ByteString -> Assertion
assertContains needle haystack =
  assertBool ("expected to contain " <> BS8.unpack needle) (needle `BS.isInfixOf` haystack)

assertLacks :: BS.ByteString -> BS.ByteString -> Assertion
assertLacks needle haystack =
  assertBool ("expected not to contain " <> BS8.unpack needle) (not (needle `BS.isInfixOf` haystack))
