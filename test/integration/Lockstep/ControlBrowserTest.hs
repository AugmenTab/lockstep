{-# LANGUAGE OverloadedStrings #-}

{- | The control pane in a real browser (contract C-P3.1 §5): headless Chromium,
driven by @test/browser/control_driver.py@ (the frozen @cdp.py@ plus waiting
steps), against the real pane binary and the real helper with @docker@
stubbed. The browser builds every request; results are checked from what the
browser observed, from the pane's state directory and over HTTP.
-}
module Lockstep.ControlBrowserTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (listDirectory)
import System.IO (readFile)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Control (Env (..), issueSignIn, paneDir, setStubMode, withEnv, withHelper, withPaneOn)
import Lockstep.Support.Http (HttpResponse (..), httpRequest)
import Lockstep.Support.Process (freePort)

tests :: TestTree
tests =
  testGroup
    "control pane in a real browser (headless Chromium)"
    [ testCase "fragment sign-in, status from the helper, hostile origins refused, markup shown as text, sign-out" $
        withEnv $ \env -> withHelper env [] $ withPaneOn (paneDir env) [] $ \port -> do
          token <- issueSignIn (paneDir env) 300
          hostilePort <- freePort
          let
            base = "http://127.0.0.1:" <> show port
            link = base <> "/sign-in#" <> T.unpack token
          first <- runDriver (firstHalf base link hostilePort port)
          threadDelay 2000000
          -- one status check per signed-in page load (two); the hostile page's plain POST of "status" made none
          afterFirst <- countResults env
          setStubMode env "markup"
          token2 <- issueSignIn (paneDir env) 300
          second <- runDriver (secondHalf base (base <> "/sign-in#" <> T.unpack token2) link)
          let
            value observed key = fromMaybe "<missing>" (L.lookup key observed)
            check ok message = [message | not ok]
            expect observed key expected = check (value observed key == expected) (key <> ": expected " <> show expected <> ", got " <> show (value observed key))
            has observed key needle = check (needle `L.isInfixOf` value observed key) (key <> " lacks " <> show needle <> ": " <> show (L.take 400 (value observed key)))
            lacks observed key needle = check (not (needle `L.isInfixOf` value observed key)) (key <> " contains " <> show needle)
            failures =
              L.concat
                [ expect first "done" "ok"
                , -- signed in through the fragment; the address bar no longer holds it
                  expect first "signin.found" "yes"
                , has first "signin.text" "Installed"
                , has first "signin.text" "Ready"
                , expect first "url.value" (show (base <> "/"))
                , expect first "stored.value" "true"
                , lacks first "signin.text" (T.unpack token)
                , -- the session survives a reload
                  expect first "reload.found" "yes"
                , -- a page on another port: no storage, no header, no reading
                  expect first "hostile.found" "yes"
                , has first "hostile.text" "storage=null"
                , has first "hostile.text" "header=blocked"
                , has first "hostile.text" "read=blocked"
                , expect second "done" "ok"
                , -- markup from the helper is shown as text and creates no element
                  expect second "markup.found" "yes"
                , expect second "images.value" "0"
                , -- the same link again: refused, and said so
                  expect second "replay.found" "yes"
                , -- sign-out
                  expect second "signedout.found" "yes"
                , expect second "storedafter.value" "false"
                , expect second "after.found" "yes"
                , lacks second "after.text" "Installed"
                ]
          assertBool ("browser expectations failed:\n" <> L.unlines failures) (L.null failures)
          afterFirst @?= 2
          -- the old session is refused by the pane itself
          let
            session = L.filter (/= '"') (value second "session.value")
          resp <- httpRequest port "POST" "/api/requests" [("Origin", BS8.pack base), ("X-Lockstep-Session", BS8.pack session)] "status"
          responseStatus resp @?= 401
          -- the token never reached the pane's log
          paneLog <- readFile (paneDir env <> ".log")
          assertBool "the token appears in the pane log" (not (T.unpack token `L.isInfixOf` paneLog))
    ]

countResults :: Env -> IO Int
countResults env =
  L.length . L.filter (".res" `L.isSuffixOf`) <$> listDirectory (paneDir env <> "/results")

firstHalf :: String -> String -> Int -> Int -> String
firstHalf base link hostilePort port =
  jsonList
    [ obj [("op", str "open"), ("label", str "landing"), ("url", str link)]
    , obj [("op", str "wait_text"), ("label", str "signin"), ("text", str "Ready"), ("timeout", "20")]
    , obj [("op", str "eval"), ("label", str "url"), ("expression", str "location.href")]
    , obj [("op", str "eval"), ("label", str "stored"), ("expression", str "localStorage.getItem('lockstep.control.session') !== null")]
    , obj [("op", str "open"), ("label", str "reloaded"), ("url", str (base <> "/"))]
    , obj [("op", str "wait_text"), ("label", str "reload"), ("text", str "Installed"), ("timeout", "20")]
    , obj [("op", str "serve"), ("port", show hostilePort), ("html", str (hostilePage port))]
    , obj [("op", str "open"), ("label", str "hostilepage"), ("url", str ("http://127.0.0.1:" <> show hostilePort <> "/"))]
    , obj [("op", str "wait_text"), ("label", str "hostile"), ("text", str "DONE"), ("timeout", "10")]
    ]

-- | A second browser (a fresh profile): sign in with a new link, see markup as text, replay the first link, sign out.
secondHalf :: String -> String -> String -> String
secondHalf base link usedLink =
  jsonList
    [ obj [("op", str "open"), ("label", str "signin2"), ("url", str link)]
    , obj [("op", str "wait_text"), ("label", str "markup"), ("text", str "<img src=x onerror=alert(1)>"), ("timeout", "20")]
    , obj [("op", str "eval"), ("label", str "images"), ("expression", str "document.querySelectorAll('img').length")]
    , obj [("op", str "open"), ("label", str "replaypage"), ("url", str usedLink)]
    , obj [("op", str "wait_text"), ("label", str "replay"), ("text", str "already used"), ("timeout", "10")]
    , obj [("op", str "eval"), ("label", str "session"), ("expression", str "localStorage.getItem('lockstep.control.session')")]
    , obj [("op", str "click"), ("label", str "signout"), ("selector", str "#sign-out")]
    , obj [("op", str "wait_text"), ("label", str "signedout"), ("text", str "You are signed out"), ("timeout", "10")]
    , obj [("op", str "eval"), ("label", str "storedafter"), ("expression", str "localStorage.getItem('lockstep.control.session') !== null")]
    , obj [("op", str "open"), ("label", str "afterpage"), ("url", str (base <> "/"))]
    , obj [("op", str "wait_text"), ("label", str "after"), ("text", str "You are signed out"), ("timeout", "10")]
    ]

-- | A page on another port of the same host that tries to use the pane.
hostilePage :: Int -> String
hostilePage port =
  let
    target = "http://127.0.0.1:" <> show port
  in
    L.concat
      [ "<!doctype html><html><body>working<script>"
      , "(async function(){var out=[];"
      , "out.push('storage='+localStorage.getItem('lockstep.control.session'));"
      , "try{var r=await fetch('" <> target <> "/api/requests',{method:'POST',headers:{'X-Lockstep-Session':'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'},body:'status'});out.push('header='+r.status);}catch(e){out.push('header=blocked');}"
      , "try{await fetch('" <> target <> "/api/requests',{method:'POST',mode:'no-cors',body:'status'});out.push('simple=sent');}catch(e){out.push('simple=error');}"
      , "try{var g=await fetch('" <> target <> "/api/requests/00000000000000000000000000000000');out.push('read='+g.status);}catch(e){out.push('read=blocked');}"
      , "document.body.textContent=out.join(' ')+' DONE';})();"
      , "</script></body></html>"
      ]

-- | Runs the driver (at most 180 s) and returns its key/value observations.
runDriver :: String -> IO [(String, String)]
runDriver input = do
  result <-
    timeout 180000000 $
      Process.readCreateProcessWithExitCode (Process.proc "python3" ["test/browser/control_driver.py"]) input
  case result of
    Nothing -> assertFailure "the browser driver did not finish within 180 s"
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

jsonList :: [String] -> String
jsonList items =
  "[" <> L.intercalate "," items <> "]"

obj :: [(String, String)] -> String
obj fields =
  "{" <> L.intercalate "," [str k <> ":" <> v | (k, v) <- fields] <> "}"

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
