{-# LANGUAGE OverloadedStrings #-}

{- | Opening the application from the control pane (contract C-P3.4 A3): the
real helper issues the token with the real CLI against a real database; the
real pane hands it to the browser once; the real service accepts it. The last
case is the whole journey in headless Chromium, with keyboard navigation, a
phone-sized window, a hostile page and sign-out.
-}
module Lockstep.HandoverTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Flipstone.Prelude
import Numeric (showHex)
import System.Directory (doesFileExist, listDirectory, renameFile)
import System.Posix.Files (fileMode, getFileStatus, setFileMode)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol (ControlResult (..), Outcome (..), decodeResult, parseRequestId)
import Lockstep.Foundation.SessionProtocol (SessionOp (..), SessionRequest (..), encodeSessionRequest)
import Lockstep.Support.App (AEnv (..), aPane, appLog, setService, withAppEnv, withAppHelper)
import Lockstep.Support.Control (issueSignIn, withPaneOn)
import Lockstep.Support.Http (HttpResponse (..), httpRequest)
import Lockstep.Support.Process (freePort)

newId :: IO T.Text
newId = do
  t <- getPOSIXTime
  pure (T.justifyRight 32 '0' (T.pack (showHex (floor (t * 1000000) :: Integer) "")))

submit :: AEnv -> IO T.Text
submit env = do
  rid <- newId
  t <- getPOSIXTime
  r <- maybe (assertFailure "id") pure (parseRequestId rid)
  let
    tmp = aPane env <> "/requests/." <> T.unpack rid <> ".tmp"
  BS.writeFile tmp (encodeSessionRequest (aKey env) (SessionRequest r (floor t) OpenApplication))
  setFileMode tmp 0o600
  renameFile tmp (aPane env <> "/requests/" <> T.unpack rid <> ".sreq")
  pure rid

await :: AEnv -> T.Text -> IO ControlResult
await env rid =
  let
    path = aPane env <> "/results/" <> T.unpack rid <> ".res"
    attempt :: Int -> IO ControlResult
    attempt remaining = do
      present <- doesFileExist path
      if present
        then BS.readFile path >>= either (\e -> assertFailure ("result does not verify: " <> show e)) pure . decodeResult (aKey env)
        else
          if remaining <= 0
            then appLog env >>= \out -> assertFailure ("no result within 30 s:\n" <> out)
            else threadDelay 100000 >> attempt (remaining - 1)
  in
    attempt 300

origin :: Int -> BS.ByteString
origin port =
  "http://127.0.0.1:" <> BS8.pack (show port)

paneSession :: AEnv -> Int -> IO BS.ByteString
paneSession env port = do
  token <- issueSignIn (aPane env) 300
  resp <- httpRequest port "POST" "/api/session" [("Origin", origin port)] (TE.encodeUtf8 token)
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

tests :: TestTree
tests =
  testGroup
    "hand-over from the control pane to the application (C-P3.4 A3)"
    [ testCase "the helper issues a one-time token into a private hand-over file, never into the result" $
        withAppEnv $ \env -> withAppHelper env $ do
          rid <- submit env
          r <- await env rid
          (resultOutcome r, resultReason r) @?= (OutcomeOk, Nothing)
          let
            file = aPane env <> "/handover/" <> T.unpack rid
          present <- doesFileExist file
          assertBool "no hand-over file" present
          mode <- fileMode <$> getFileStatus file
          (mode `mod` 0o1000) @?= 0o600
          content <- BS.readFile file
          let
            token = BS.take 43 (BS.drop 6 (snd (BS.breakSubstring "token " content)))
          BS.length token @?= 43
          resultBytes <- BS.readFile (aPane env <> "/results/" <> T.unpack rid <> ".res")
          assertBool "the token is in the result file" (not (contains token resultBytes))
          helperLog <- BS.readFile (aState env <> "/helper/helper.log")
          assertBool "the token is in the helper log" (not (contains token helperLog))
          exchange <- httpRequest (aServicePort env) "POST" "/app/api/session" [("Origin", origin (aServicePort env))] token
          responseStatus exchange @?= 200
    , testCase "without a running service nothing is issued" $
        withAppEnv $ \env -> withAppHelper env $ do
          setService env "absent"
          rid <- submit env
          r <- await env rid
          (resultOutcome r, resultReason r) @?= (OutcomeRefused, Just "state-changed")
          exists <- doesFileExist (aPane env <> "/handover/" <> T.unpack rid)
          assertBool "a hand-over file was written" (not exists)
    , testCase "the pane hands the address over once, to its own session" $
        withAppEnv $ \env -> withAppHelper env $ withPaneOn (aPane env) [] $ \port -> do
          session <- paneSession env port
          none <- httpRequest port "POST" "/api/open-application" [("Origin", origin port)] ""
          responseStatus none @?= 401
          elsewhere <- httpRequest port "POST" "/api/open-application" [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", session)] ""
          responseStatus elsewhere @?= 403
          started <- httpRequest port "POST" "/api/open-application" [("Origin", origin port), ("X-Lockstep-Session", session)] ""
          responseStatus started @?= 202
          let
            rid = BS8.unpack (BS.take 32 (BS.drop 7 (snd (BS.breakSubstring "\"id\":\"" (responseBody started)))))
          _ <- await env (T.pack rid)
          withoutSession <- httpRequest port "GET" ("/api/handover/" <> rid) [] ""
          responseStatus withoutSession @?= 401
          first <- httpRequest port "GET" ("/api/handover/" <> rid) [("X-Lockstep-Session", session)] ""
          responseStatus first @?= 200
          let
            expectedPrefix = "http://127.0.0.1:" <> BS8.pack (show (aServicePort env)) <> "/app/sign-in#"
          assertBool ("no address: " <> show (responseBody first)) (contains expectedPrefix (responseBody first))
          handover <- listDirectory (aPane env <> "/handover")
          handover @?= []
          again <- httpRequest port "GET" ("/api/handover/" <> rid) [("X-Lockstep-Session", session)] ""
          responseStatus again @?= 404
    , testCase "a forged hand-over file is not handed over" $
        withAppEnv $ \env -> withAppHelper env $ withPaneOn (aPane env) [] $ \port -> do
          session <- paneSession env port
          started <- httpRequest port "POST" "/api/open-application" [("Origin", origin port), ("X-Lockstep-Session", session)] ""
          let
            rid = BS8.unpack (BS.take 32 (BS.drop 7 (snd (BS.breakSubstring "\"id\":\"" (responseBody started)))))
          _ <- await env (T.pack rid)
          BS.writeFile (aPane env <> "/handover/" <> rid) "port 1\ntoken javascript:alert(1)//aaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
          resp <- httpRequest port "GET" ("/api/handover/" <> rid) [("X-Lockstep-Session", session)] ""
          responseStatus resp @?= 404
          assertBool "the forged content was served" (not (contains "javascript" (responseBody resp)))
    , testCase "the whole journey in a real browser: pane, Open Lockstep, Home, keyboard, phone width, hostile page, sign-out" $
        withAppEnv $ \env -> withAppHelper env $ withPaneOn (aPane env) [] $ \port -> do
          token <- issueSignIn (aPane env) 300
          hostile <- freePort
          let
            app = "http://127.0.0.1:" <> show (aServicePort env)
          observed <- runDriver (journey ("http://127.0.0.1:" <> show port <> "/sign-in#" <> T.unpack token) app hostile)
          let
            value key = fromMaybe "<missing>" (L.lookup key observed)
            failures =
              [ key <> ": expected " <> show expected <> ", got " <> show (value key)
              | (key, expected) <-
                  [ ("done", "ok")
                  , ("pane.found", "yes")
                  , ("home.found", "yes")
                  , ("homeurl.value", show (app <> "/app/home"))
                  , ("stored.value", "true")
                  , ("projects.found", "yes")
                  , ("projectsurl.value", show (app <> "/app/projects"))
                  , ("narrow.value", "true")
                  , ("nav.value", "7")
                  , ("hostile.found", "yes")
                  , ("signedout.found", "yes")
                  , ("storedafter.value", "false")
                  ]
              , value key /= expected
              ]
                <> ["home.text lacks ready" | not ("ready" `L.isInfixOf` value "home.text")]
                <> ["hostile page read the session" | not ("storage=null" `L.isInfixOf` value "hostile.text")]
          assertBool ("browser expectations failed:\n" <> L.unlines failures) (L.null failures)
    ]

journey :: String -> String -> Int -> String
journey paneLink app hostile =
  let
    step fields = "{" <> L.intercalate "," [str k <> ":" <> v | (k, v) <- fields] <> "}"
    open' label url = step [("op", str "open"), ("label", str label), ("url", str url)]
    wait' label text = step [("op", str "wait_text"), ("label", str label), ("text", str text), ("timeout", "60")]
    eval' label expression = step [("op", str "eval"), ("label", str label), ("expression", str expression)]
    key' k = step [("op", str "key"), ("key", str k)]
    hostilePage =
      "<!doctype html><html><body><script>document.body.textContent='storage='+localStorage.getItem('lockstep.app.session')+' DONE';</script></body></html>"
  in
    "["
      <> L.intercalate
        ","
        [ open' "landing" paneLink
        , wait' "pane" "Running"
        , step [("op", str "click"), ("label", str "open"), ("selector", str "#open-application")]
        , wait' "home" "What needs your attention"
        , eval' "homeurl" "location.href"
        , eval' "stored" "localStorage.getItem('lockstep.app.session') !== null"
        , eval' "nav" "document.querySelectorAll('nav a').length"
        , eval' "focusprep" "(function(){document.querySelector('nav a').focus();return true;})()"
        , key' "Tab"
        , key' "Enter"
        , wait' "projects" "later update"
        , eval' "projectsurl" "location.href"
        , step [("op", str "viewport"), ("width", "390"), ("height", "800")]
        , step [("op", str "sleep"), ("seconds", "1")]
        , eval' "narrow" "document.documentElement.scrollWidth <= window.innerWidth"
        , step [("op", str "serve"), ("port", show hostile), ("html", str hostilePage)]
        , open' "hostilepage" ("http://127.0.0.1:" <> show hostile <> "/")
        , wait' "hostile" "DONE"
        , open' "back" (app <> "/app/home")
        , wait' "backhome" "What needs your attention"
        , step [("op", str "click"), ("label", str "signout"), ("selector", str "#sign-out")]
        , wait' "signedout" "You are signed out"
        , eval' "storedafter" "localStorage.getItem('lockstep.app.session') !== null"
        ]
      <> "]"

runDriver :: String -> IO [(String, String)]
runDriver input = do
  result <-
    timeout 300000000 $
      Process.readCreateProcessWithExitCode (Process.proc "python3" ["test/browser/app_driver.py"]) input
  case result of
    Nothing -> assertFailure "the browser driver did not finish within 300 s"
    Just (_, out, err) -> do
      let
        pairs =
          [ (k, L.drop 1 v)
          | line <- L.lines out
          , let
              (k, v) = L.break (== '\t') line
          ]
      case L.lookup "error" pairs of
        Just message -> assertFailure ("browser driver error: " <> message <> "\n" <> err)
        Nothing -> pure pairs

str :: String -> String
str s =
  "\"" <> L.concatMap escape s <> "\""
 where
  escape c =
    case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      _ -> [c]
