{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Web.RequestGuardTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Lockstep.Foundation.Config (Port, mkPort)
import Lockstep.Web.RequestGuard (GuardRefusal (..), RouteClass (..), guardRequest)

tests :: TestTree
tests =
  testGroup
    "RequestGuard"
    [ testGroup
        "Host"
        [ testCase "the exact loopback authority is accepted" $
            check 8000 PublicRead (req "GET" [host "127.0.0.1:8000"]) (Right ())
        , testCase "localhost is refused" $
            check 8000 PublicRead (req "GET" [host "localhost:8000"]) (Left HostRefused)
        , testCase "another port is refused" $
            check 8000 PublicRead (req "GET" [host "127.0.0.1:8001"]) (Left HostRefused)
        , testCase "another host is refused (DNS rebinding)" $
            check 8000 OperatorRoute (req "GET" [host "attacker.example:8000"]) (Left HostRefused)
        , testCase "the address without a port is refused when the port is not 80" $
            check 8000 PublicRead (req "GET" [host "127.0.0.1"]) (Left HostRefused)
        , testCase "a trailing-dot form is refused" $
            check 8000 PublicRead (req "GET" [host "127.0.0.1.:8000"]) (Left HostRefused)
        , testCase "two Host headers are refused" $
            check 8000 PublicRead (req "GET" [host "127.0.0.1:8000", host "127.0.0.1:8000"]) (Left HostRefused)
        , testCase "a missing Host is tolerated on a public GET [D-1a]" $
            check 8000 PublicRead (req "GET" []) (Right ())
        , testCase "a missing Host is tolerated on a public HEAD [D-1a]" $
            check 8000 PublicRead (req "HEAD" []) (Right ())
        , testCase "a missing Host is refused on an operator route [D-1a]" $
            check 8000 OperatorRoute (req "GET" []) (Left HostRefused)
        , testCase "a missing Host is refused on a POST, even with the exact Origin [D-1a]" $
            check 8000 OperatorRoute (req "POST" [origin "http://127.0.0.1:8000"]) (Left HostRefused)
        , testCase "a missing Host is refused on a public-class POST [D-1a]" $
            check 8000 PublicRead (req "POST" [origin "http://127.0.0.1:8000"]) (Left HostRefused)
        , testCase "a wrong Host is refused before the Origin is considered" $
            check 8000 OperatorRoute (req "POST" [host "localhost:8000", origin "http://localhost:8000"]) (Left HostRefused)
        ]
    , testGroup
        "Origin on mutating requests [D-2d]"
        [ testCase "the exact Origin is accepted" $
            check 8000 OperatorRoute (post [origin "http://127.0.0.1:8000"]) (Right ())
        , testCase "a missing Origin is refused" $
            check 8000 OperatorRoute (post []) (Left OriginRefused)
        , testCase "a foreign Origin is refused" $
            check 8000 OperatorRoute (post [origin "http://attacker.example"]) (Left OriginRefused)
        , testCase "another port is refused" $
            check 8000 OperatorRoute (post [origin "http://127.0.0.1:8001"]) (Left OriginRefused)
        , testCase "localhost is refused" $
            check 8000 OperatorRoute (post [origin "http://localhost:8000"]) (Left OriginRefused)
        , testCase "https is refused" $
            check 8000 OperatorRoute (post [origin "https://127.0.0.1:8000"]) (Left OriginRefused)
        , testCase "a trailing slash is refused" $
            check 8000 OperatorRoute (post [origin "http://127.0.0.1:8000/"]) (Left OriginRefused)
        , testCase "Origin: null is refused" $
            check 8000 OperatorRoute (post [origin "null"]) (Left OriginRefused)
        , testCase "Origin: null is refused even with Sec-Fetch-Site: same-origin (no exception)" $
            check 8000 OperatorRoute (post [origin "null", fetchSite "same-origin"]) (Left OriginRefused)
        , testCase "two Origin headers are refused" $
            check 8000 OperatorRoute (post [origin "http://127.0.0.1:8000", origin "http://127.0.0.1:8000"]) (Left OriginRefused)
        , testCase "DELETE needs the Origin too" $
            check 8000 OperatorRoute (req "DELETE" [host "127.0.0.1:8000"]) (Left OriginRefused)
        , testCase "a GET needs no Origin" $
            check 8000 OperatorRoute (req "GET" [host "127.0.0.1:8000"]) (Right ())
        , testCase "a GET with a foreign Origin is not refused for it (Host decides)" $
            check 8000 OperatorRoute (req "GET" [host "127.0.0.1:8000", origin "http://attacker.example"]) (Right ())
        ]
    , testGroup
        "port 80 uses the default-port forms [D-1a]"
        [ testCase "Host 127.0.0.1 and Origin http://127.0.0.1 are accepted" $
            check 80 OperatorRoute (req "POST" [host "127.0.0.1", origin "http://127.0.0.1"]) (Right ())
        , testCase "Host 127.0.0.1:80 is refused" $
            check 80 OperatorRoute (req "GET" [host "127.0.0.1:80"]) (Left HostRefused)
        , testCase "Origin http://127.0.0.1:80 is refused" $
            check 80 OperatorRoute (req "POST" [host "127.0.0.1", origin "http://127.0.0.1:80"]) (Left OriginRefused)
        ]
    ]
 where
  post headers =
    req "POST" (host "127.0.0.1:8000" : headers)

check :: Integer -> RouteClass -> Wai.Request -> Either GuardRefusal () -> IO ()
check n routeClass request expected = do
  port <- portOf n
  guardRequest port routeClass request @?= expected

portOf :: Integer -> IO Port
portOf n =
  maybe (assertFailure "bad test port") pure (mkPort n)

req :: HTTP.Method -> [HTTP.Header] -> Wai.Request
req method headers =
  Wai.defaultRequest
    { Wai.requestMethod = method
    , Wai.requestHeaders = headers
    , Wai.requestHeaderHost = lookupFirst "Host" headers
    }

lookupFirst :: HTTP.HeaderName -> [HTTP.Header] -> Maybe BS.ByteString
lookupFirst name headers =
  case [v | (k, v) <- headers, k == name] of
    v : _ -> Just v
    [] -> Nothing

host :: BS.ByteString -> HTTP.Header
host value =
  ("Host", value)

origin :: BS.ByteString -> HTTP.Header
origin value =
  ("Origin", value)

fetchSite :: BS.ByteString -> HTTP.Header
fetchSite value =
  ("Sec-Fetch-Site", value)
