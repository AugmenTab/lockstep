{-# LANGUAGE OverloadedStrings #-}

{- | The control pane over real HTTP (contract C-P3.1 §3): the real binary,
@lockstep control serve@, with a temporary state directory and no database
configuration at all. The test plays the launcher (it writes @pane.id@,
@channel.key@ and sign-in files) and, where a result is needed, the helper.
-}
module Lockstep.ControlPaneTest
  ( tests
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Directory (createDirectory, doesFileExist, listDirectory, removeFile)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol
  ( ControlOp (OpStatus)
  , ControlRequest (..)
  , ControlResult (..)
  , Expect (ExpectAny)
  , Outcome (OutcomeOk)
  , decodeRequest
  , encodeResult
  , parseChannelKey
  , requestIdText
  , signInDigestHex
  )
import Lockstep.Foundation.OperatorToken (encodeToken, generateToken)
import Lockstep.Support.Control (currentSeconds, issueSignIn, paneEnvironment, withPaneOn)
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Process (freePort)

data Pane
  = Pane
  { panePort :: Int
  , paneDir :: FilePath
  , paneIdent :: BS.ByteString
  }

keyHex :: BS.ByteString
keyHex =
  "8f1e2d3c4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff0"

expectedCsp :: BS.ByteString
expectedCsp =
  "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

paneIdText :: BS.ByteString
paneIdText =
  "a1b2c3d4e5f60718293a4b5c6d7e8f90"

-- | A state directory as the launcher leaves it (C-P3.1 L2, L4, L7).
prepareState :: FilePath -> Bool -> IO ()
prepareState dir withKey = do
  setFileMode dir 0o700
  BS.writeFile (dir <> "/pane.id") (paneIdText <> "\n")
  when withKey $ do
    BS.writeFile (dir <> "/channel.key") (keyHex <> "\n")
    setFileMode (dir <> "/channel.key") 0o600
  traverse_ (\d -> createDirectory (dir <> "/" <> d) >> setFileMode (dir <> "/" <> d) 0o700) ["signin", "requests", "results"]

withPaneIn :: FilePath -> [(String, String)] -> (Pane -> IO a) -> IO a
withPaneIn dir extraEnv action =
  withPaneOn dir extraEnv (\port -> action (Pane port dir paneIdText))

withPane :: Bool -> (Pane -> IO a) -> IO a
withPane withKey action =
  withSystemTempDirectory "lockstep-control" $ \base -> do
    let
      dir = base <> "/state"
    createDirectory dir
    prepareState dir withKey
    withPaneIn dir [] action

origin :: Pane -> BS.ByteString
origin pane =
  "http://127.0.0.1:" <> BS8.pack (show (panePort pane))

sameOrigin :: Pane -> [HTTPTypes.Header]
sameOrigin pane =
  [("Origin", origin pane)]

-- | Issues a sign-in token the way the launcher does; returns its text.
issueToken :: Pane -> Integer -> IO T.Text
issueToken pane =
  issueSignIn (paneDir pane)

exchange :: Pane -> [HTTPTypes.Header] -> T.Text -> IO HttpResponse
exchange pane headers token =
  httpRequest (panePort pane) "POST" "/api/session" headers (TE.encodeUtf8 token)

signIn :: Pane -> IO BS.ByteString
signIn pane = do
  token <- issueToken pane 300
  resp <- exchange pane (sameOrigin pane) token
  responseStatus resp @?= 200
  case BS.breakSubstring "\"session\":\"" (responseBody resp) of
    (_, rest)
      | not (BS.null rest) ->
          let
            value = BS.takeWhile (/= 0x22) (BS.drop 11 rest)
          in
            if BS.length value == 43 then pure value else assertFailure ("session is not 43 characters: " <> show value)
    _ -> assertFailure ("no session in " <> show (responseBody resp))

withSession :: Pane -> BS.ByteString -> [HTTPTypes.Header]
withSession pane session =
  ("X-Lockstep-Session", session) : sameOrigin pane

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

assertSecurityHeaders :: String -> HttpResponse -> Assertion
assertSecurityHeaders label resp = do
  let
    has name value = assertBool (label <> ": " <> show name <> " is " <> show (responseHeader name resp)) (responseHeader name resp == Just value)
  has "Content-Security-Policy" expectedCsp
  has "Cache-Control" "no-store"
  has "X-Content-Type-Options" "nosniff"
  has "Referrer-Policy" "no-referrer"
  has "X-Frame-Options" "DENY"
  has "Cross-Origin-Opener-Policy" "same-origin"
  has "Cross-Origin-Resource-Policy" "same-origin"
  assertNoAmbientHeaders label resp

assertNoAmbientHeaders :: String -> HttpResponse -> Assertion
assertNoAmbientHeaders label resp =
  traverse_
    (\name -> assertBool (label <> ": sent " <> show name) (isNothing (responseHeader name resp)))
    [ "Set-Cookie"
    , "Access-Control-Allow-Origin"
    , "Access-Control-Allow-Headers"
    , "Access-Control-Allow-Methods"
    , "Access-Control-Allow-Credentials"
    , "Access-Control-Expose-Headers"
    ]

-- | The one request file in @requests/@, decoded with the test key.
theRequest :: Pane -> IO ControlRequest
theRequest pane = do
  names <- listDirectory (paneDir pane <> "/requests")
  case L.filter (".req" `L.isSuffixOf`) names of
    [name] -> do
      bytes <- BS.readFile (paneDir pane <> "/requests/" <> name)
      key <- maybe (assertFailure "test key") pure (parseChannelKey keyHex)
      case decodeRequest key bytes of
        Left err -> assertFailure ("the pane's request does not verify: " <> show err)
        Right r -> do
          (T.unpack (requestIdText (requestId r)) <> ".req") @?= name
          pure r
    other -> assertFailure ("expected one request file, found " <> show other)

writeResult :: Pane -> BS.ByteString -> ControlResult -> IO ()
writeResult pane key result = do
  k <- maybe (assertFailure "result key") pure (parseChannelKey key)
  BS.writeFile (paneDir pane <> "/results/" <> T.unpack (resultId result) <> ".res") (encodeResult k result)

tests :: TestTree
tests =
  testGroup
    "control pane over HTTP (C-P3.1 §3)"
    [ testCase "health: 204 with the pane identity and no ambient headers; no database configuration needed" $
        withPane True $ \pane -> do
          resp <- httpRequest (panePort pane) "GET" "/api/health" [] ""
          responseStatus resp @?= 204
          responseHeader "X-Lockstep-Control" resp @?= Just (paneIdent pane)
          assertNoAmbientHeaders "health" resp
    , testCase "the shell at / and /sign-in carries no state and the exact security headers" $
        withPane True $ \pane ->
          traverse_
            ( \path -> do
                resp <- httpRequest (panePort pane) "GET" path [] ""
                responseStatus resp @?= 200
                assertSecurityHeaders path resp
                assertBool (path <> ": not html") (fmap ("text/html" `BS.isPrefixOf`) (responseHeader "Content-Type" resp) == Just True)
                assertBool (path <> ": does not load the pane script") (contains "<script src=\"/static/control.js\"></script>" (responseBody resp))
                assertBool (path <> ": contains the pane id") (not (contains paneIdText (responseBody resp)))
                assertBool (path <> ": contains the key") (not (contains (BS.take 16 keyHex) (responseBody resp)))
                assertBool (path <> ": has an inline script") (not (contains "<script>" (responseBody resp)))
                assertBool (path <> ": has an inline handler") (not (contains "onload=" (responseBody resp) || contains "onclick=" (responseBody resp)))
            )
            ["/", "/sign-in"]
    , testCase "the page script and stylesheet are served as such" $
        withPane True $ \pane -> do
          js <- httpRequest (panePort pane) "GET" "/static/control.js" [] ""
          responseStatus js @?= 200
          fmap ("text/javascript" `BS.isPrefixOf`) (responseHeader "Content-Type" js) @?= Just True
          assertBool "control.js uses innerHTML" (not (contains "innerHTML" (responseBody js)))
          assertBool "control.js uses eval" (not (contains "eval(" (responseBody js)))
          css <- httpRequest (panePort pane) "GET" "/static/lockstep.css" [] ""
          responseStatus css @?= 200
    , testCase "unknown routes are 404 for every method; OPTIONS never answers CORS" $
        withPane True $ \pane -> do
          traverse_
            ( \(method, path) -> do
                resp <- httpRequest (panePort pane) method path (sameOrigin pane) ""
                assertBool (show method <> " " <> path <> " gave " <> show (responseStatus resp)) (responseStatus resp == 404)
                assertNoAmbientHeaders path resp
            )
            [ ("GET", "/operator")
            , ("GET", "/api/status")
            , ("GET", "/static/../channel.key")
            , ("GET", "/channel.key")
            , ("GET", "/static/other.js")
            , ("POST", "/")
            , ("PUT", "/api/session")
            , ("DELETE", "/api/requests")
            , ("POST", "/api/requests/x")
            ]
          preflight <-
            httpRequest
              (panePort pane)
              "OPTIONS"
              "/api/requests"
              [("Origin", "http://127.0.0.1:1"), ("Access-Control-Request-Method", "POST"), ("Access-Control-Request-Headers", "x-lockstep-session")]
              ""
          assertBool ("preflight answered " <> show (responseStatus preflight)) (responseStatus preflight == 405 || responseStatus preflight == 404)
          assertNoAmbientHeaders "preflight" preflight
    , testCase "foreign Host is refused before anything runs (DNS rebinding); the token survives" $
        withPane True $ \pane -> do
          token <- issueToken pane 300
          traverse_
            ( \h -> do
                resp <- exchange pane [("Host", h), ("Origin", origin pane)] token
                assertBool ("Host " <> show h <> " gave " <> show (responseStatus resp)) (responseStatus resp == 403)
            )
            ["attacker.example:" <> BS8.pack (show (panePort pane)), "localhost:" <> BS8.pack (show (panePort pane)), "127.0.0.1:1", "127.0.0.1"]
          resp <- exchange pane (sameOrigin pane) token
          responseStatus resp @?= 200
    , testCase "missing, null, foreign and localhost Origins are refused; the token survives" $
        withPane True $ \pane -> do
          token <- issueToken pane 300
          traverse_
            ( \headers -> do
                resp <- exchange pane headers token
                assertBool (show headers <> " gave " <> show (responseStatus resp)) (responseStatus resp == 403)
            )
            [ []
            , [("Origin", "null")]
            , [("Origin", "http://127.0.0.1:1")]
            , [("Origin", "http://localhost:" <> BS8.pack (show (panePort pane)))]
            , [("Origin", origin pane <> "/")]
            , [("Origin", origin pane), ("Origin", origin pane)]
            ]
          ok <- exchange pane (sameOrigin pane) token
          responseStatus ok @?= 200
    , testCase "a token works once: the file is consumed and a replay is refused" $
        withPane True $ \pane -> do
          token <- issueToken pane 300
          first <- exchange pane (sameOrigin pane) token
          responseStatus first @?= 200
          assertSecurityHeaders "exchange" first
          remaining <- listDirectory (paneDir pane <> "/signin")
          remaining @?= []
          replay <- exchange pane (sameOrigin pane) token
          responseStatus replay @?= 403
          assertBool "the refusal echoes the token" (not (contains (TE.encodeUtf8 token) (responseBody replay)))
    , testCase "unknown and malformed tokens are refused without effect" $
        withPane True $ \pane -> do
          real <- issueToken pane 300
          traverse_
            ( \t -> do
                resp <- exchange pane (sameOrigin pane) t
                assertBool (show t <> " gave " <> show (responseStatus resp)) (responseStatus resp == 403)
            )
            [ T.replicate 43 "B"
            , T.take 42 real
            , real <> "A"
            , T.replicate 41 "A" <> "=="
            , "../../../../../../../../etc/passwd/AAAAAAAAAAAAAA"
            , T.replicate 42 "A" <> "/"
            , ""
            ]
          names <- listDirectory (paneDir pane <> "/signin")
          L.length names @?= 1
    , testCase "an expired token is refused and its file removed" $
        withPane True $ \pane -> do
          token <- issueToken pane (-1)
          resp <- exchange pane (sameOrigin pane) token
          responseStatus resp @?= 403
          names <- listDirectory (paneDir pane <> "/signin")
          names @?= []
    , testCase "a sign-in file that is a symlink is refused and its target untouched" $
        withPane True $ \pane -> do
          token <- encodeToken <$> generateToken
          now <- currentSeconds
          let
            target = paneDir pane <> "/../target"
          BS.writeFile target ("expires " <> BS8.pack (show (now + 300)) <> "\n")
          createSymbolicLink target (paneDir pane <> "/signin/" <> T.unpack (signInDigestHex token))
          resp <- exchange pane (sameOrigin pane) token
          responseStatus resp @?= 403
          stillThere <- doesFileExist target
          assertBool "the symlink target was removed" stillThere
    , testCase "two simultaneous exchanges of one token: exactly one session" $
        withPane True $ \pane -> do
          token <- issueToken pane 300
          a <- newEmptyMVar
          b <- newEmptyMVar
          void (forkIO (exchange pane (sameOrigin pane) token >>= putMVar a . responseStatus))
          void (forkIO (exchange pane (sameOrigin pane) token >>= putMVar b . responseStatus))
          sa <- takeMVar a
          sb <- takeMVar b
          L.sort [sa, sb] @?= [200, 403]
    , testCase "API without a session, with a wrong one, and after sign-out is 401 with no data" $
        withPane True $ \pane -> do
          session <- signIn pane
          none <- httpRequest (panePort pane) "POST" "/api/requests" (sameOrigin pane) "status"
          responseStatus none @?= 401
          wrong <- httpRequest (panePort pane) "POST" "/api/requests" (withSession pane (BS.replicate 43 0x41)) "status"
          responseStatus wrong @?= 401
          short <- httpRequest (panePort pane) "POST" "/api/requests" (withSession pane "abc") "status"
          responseStatus short @?= 401
          ok <- httpRequest (panePort pane) "POST" "/api/requests" (withSession pane session) "status"
          responseStatus ok @?= 202
          out <- httpRequest (panePort pane) "POST" "/api/sign-out" (withSession pane session) ""
          responseStatus out @?= 204
          after <- httpRequest (panePort pane) "POST" "/api/requests" (withSession pane session) "status"
          responseStatus after @?= 401
          getAfter <- httpRequest (panePort pane) "GET" "/api/requests/0123456789abcdef0123456789abcdef" [("X-Lockstep-Session", session)] ""
          responseStatus getAfter @?= 401
    , testCase "a session cannot be used from another origin, even with the header" $
        withPane True $ \pane -> do
          session <- signIn pane
          resp <- httpRequest (panePort pane) "POST" "/api/requests" [("X-Lockstep-Session", session), ("Origin", "http://127.0.0.1:1")] "status"
          responseStatus resp @?= 403
    , testCase "an allowlisted request becomes one signed request file; an unknown one is refused" $
        withPane True $ \pane -> do
          session <- signIn pane
          bad <- httpRequest (panePort pane) "POST" "/api/requests" (withSession pane session) "rm -rf /"
          responseStatus bad @?= 400
          start <- httpRequest (panePort pane) "POST" "/api/requests" (withSession pane session) "start"
          responseStatus start @?= 400
          noneYet <- listDirectory (paneDir pane <> "/requests")
          noneYet @?= []
          ok <- httpRequest (panePort pane) "POST" "/api/requests" (withSession pane session) "status"
          responseStatus ok @?= 202
          assertSecurityHeaders "requests" ok
          r <- theRequest pane
          requestOp r @?= OpStatus
          requestExpect r @?= ExpectAny
          now <- currentSeconds
          assertBool ("issued " <> show (requestIssued r) <> " is not now (" <> show now <> ")") (abs (now - requestIssued r) <= 5)
          assertBool "the response does not carry the request id" (contains (TE.encodeUtf8 (requestIdText (requestId r))) (responseBody ok))
    , testCase "a result is shown only when its MAC verifies" $
        withPane True $ \pane -> do
          session <- signIn pane
          _ <- httpRequest (panePort pane) "POST" "/api/requests" (withSession pane session) "status"
          r <- theRequest pane
          let
            rid = T.unpack (requestIdText (requestId r))
            path = "/api/requests/" <> rid
            result =
              ControlResult
                { resultId = requestIdText (requestId r)
                , resultOp = "status"
                , resultOutcome = OutcomeOk
                , resultReason = Nothing
                , resultStarted = requestIssued r
                , resultFinished = requestIssued r + 1
                , resultFields = [("install.present", "yes"), ("service.state", "running")]
                , resultDetail = "<script>alert(1)</script>"
                }
          pending <- httpRequest (panePort pane) "GET" path [("X-Lockstep-Session", session)] ""
          responseStatus pending @?= 200
          assertBool ("not pending: " <> show (responseBody pending)) (contains "\"state\":\"pending\"" (responseBody pending))
          writeResult pane "00000000000000000000000000000000000000000000000000000000000000ff" result
          forged <- httpRequest (panePort pane) "GET" path [("X-Lockstep-Session", session)] ""
          assertBool ("forged result not untrusted: " <> show (responseBody forged)) (contains "\"state\":\"untrusted\"" (responseBody forged))
          assertBool "the forged result's content was shown" (not (contains "install.present" (responseBody forged)))
          writeResult pane keyHex result
          done <- httpRequest (panePort pane) "GET" path [("X-Lockstep-Session", session)] ""
          responseStatus done @?= 200
          fmap ("application/json" `BS.isPrefixOf`) (responseHeader "Content-Type" done) @?= Just True
          assertSecurityHeaders "result" done
          let
            body = responseBody done
          assertBool ("not done: " <> show body) (contains "\"state\":\"done\"" body)
          assertBool ("no outcome: " <> show body) (contains "\"outcome\":\"ok\"" body)
          assertBool ("no field: " <> show body) (contains "\"install.present\":\"yes\"" body)
          assertBool ("markup not escaped in JSON: " <> show body) (contains "\\u003cscript\\u003e" body && not (contains "<script>" body))
          badId <- httpRequest (panePort pane) "GET" "/api/requests/..%2F..%2Fchannel.key" [("X-Lockstep-Session", session)] ""
          responseStatus badId @?= 404
    , testCase "a body over 4 KiB is refused" $
        withPane True $ \pane -> do
          resp <- httpRequest (panePort pane) "POST" "/api/session" (sameOrigin pane) (BS.replicate 5000 0x41)
          responseStatus resp @?= 413
    , testCase "without a channel key the pane still serves, and says the helper is unavailable" $
        withPane False $ \pane -> do
          session <- signIn pane
          resp <- httpRequest (panePort pane) "POST" "/api/requests" (withSession pane session) "status"
          responseStatus resp @?= 503
          names <- listDirectory (paneDir pane <> "/requests")
          names @?= []
    , testCase "the pane ignores a database configuration it is given and needs none" $
        withSystemTempDirectory "lockstep-control" $ \base -> do
          let
            dir = base <> "/state"
          createDirectory dir
          prepareState dir True
          withPaneIn dir [("LOCKSTEP_CONFIG", "/nonexistent/lockstep.json")] $ \pane -> do
            resp <- httpRequest (panePort pane) "GET" "/" [] ""
            responseStatus resp @?= 200
    , testCase "a state directory others can read or write is refused at start" $
        withSystemTempDirectory "lockstep-control" $ \base -> do
          let
            dir = base <> "/state"
          createDirectory dir
          prepareState dir True
          setFileMode dir 0o770
          port <- freePort
          env <- paneEnvironment
          result <-
            timeout 20000000 $
              Process.readCreateProcessWithExitCode
                ((Process.proc "lockstep" ["control", "serve", "--port", show port, "--state", dir]) {Process.env = Just env})
                ""
          case result of
            Nothing -> assertFailure "the pane started with a group-accessible state directory"
            Just (code, _, err) -> do
              assertBool "exit 0" (code /= ExitSuccess)
              assertBool ("no reason given: " <> err) ("state directory" `L.isInfixOf` err)
    , testCase "a request id that is not one is 404; a request the helper has taken stays pending until its result" $
        withPane True $ \pane -> do
          session <- signIn pane
          traverse_
            ( \p -> do
                resp <- httpRequest (panePort pane) "GET" p [("X-Lockstep-Session", session)] ""
                assertBool (p <> " gave " <> show (responseStatus resp)) (responseStatus resp == 404)
            )
            ["/api/requests/0123", "/api/requests/0123456789ABCDEF0123456789ABCDEF", "/api/requests/0123456789abcdef0123456789abcdef/x"]
          _ <- httpRequest (panePort pane) "POST" "/api/requests" (withSession pane session) "status"
          r <- theRequest pane
          removeFile (paneDir pane <> "/requests/" <> T.unpack (requestIdText (requestId r)) <> ".req")
          resp <- httpRequest (panePort pane) "GET" ("/api/requests/" <> T.unpack (requestIdText (requestId r))) [("X-Lockstep-Session", session)] ""
          assertBool ("unexpected " <> show (responseBody resp)) (contains "\"state\":\"pending\"" (responseBody resp))
    ]
