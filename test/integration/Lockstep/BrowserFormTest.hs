{- | Real-browser form tests (C-P1.7-R1 §5). Headless Chromium, driven by
@test/browser/cdp.py@, signs in and submits the forms the service actually
serves; the browser builds every request. Results are checked from what the
browser observed and from PostgreSQL.
-}
module Lockstep.BrowserFormTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import System.Exit (ExitCode (ExitSuccess))
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Postgres
  ( AdminSettings (..)
  , queryBool
  , queryInts
  , requireAdmin
  , withFreshDatabase
  , writeConfigFile
  )
import Lockstep.Support.Process (freePort, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "real browser (headless Chromium) against the real service"
    [ testCase "served forms work in a real browser; cross-origin, tampered-CSRF and null-Origin submissions are refused" $
        withMigrated $ \fx dir -> do
          port <- freePort
          crossPort <- freePort
          nullPort <- freePort
          (observed, serverLog) <-
            withService (fxEnv fx) port (dir <> "/serve.log") $ do
              (code, out, _) <- runLockstep (fxEnv fx) ["operator", "sign-in", "--port", show port]
              code @?= ExitSuccess
              let
                link = L.filter (/= '\n') out
              runDriver (scenario port crossPort nullPort link)
          let
            origin = "http://127.0.0.1:" <> show port
            value key = fromMaybe "<missing>" (L.lookup key observed)
            check ok message = [message | not ok]
            expect key expected = check (value key == expected) (key <> ": expected " <> show expected <> ", got " <> show (value key))
            expectPrefix key prefix = check (prefix `L.isPrefixOf` value key) (key <> ": expected prefix " <> show prefix <> ", got " <> show (value key))
            expectText key needle = check (needle `L.isInfixOf` value key) (key <> " lacks " <> show needle <> ": " <> show (L.take 200 (value key)))
          -- Every browser expectation is checked; all failures are reported together.
          let
            failures =
              L.concat
                [ expect "done" "ok"
                , -- sign-in in the browser
                  expect "signin.post.origin" origin
                , expect "signin.post.status" "303"
                , expect "signin.url" (origin <> "/operator")
                , -- the /operator page and the queue form page send Referrer-Policy: origin (R1)
                  expect "op.status" "200"
                , expect "op.referrer_policy" "origin"
                , expect "op.csp" "frame-ancestors 'none'"
                , expect "op.x_frame_options" "DENY"
                , -- tampered CSRF on the real page: refused by the CSRF check
                  expect "tamper.post.origin" origin
                , expect "tamper.post.status" "403"
                , expectText "tamper.text" "not from this session"
                , -- rename through the served form
                  expect "rename.post.origin" origin
                , expect "rename.post.referer" (origin <> "/")
                , expect "rename.post.sec_fetch_site" "same-origin"
                , expect "rename.post.status" "303"
                , expectPrefix "rename.post.location" "/operator/receipts/"
                , expect "rename.url" (origin <> value "rename.post.location")
                , expectText "rename.text" "applied"
                , expect "rename.referrer_policy" "no-referrer"
                , -- queue through the served form
                  expect "queueform.referrer_policy" "origin"
                , expect "queue.post.origin" origin
                , expect "queue.post.status" "303"
                , expectPrefix "queue.post.location" "/operator/receipts/"
                , expectText "queue.text" "queued"
                , -- cross-origin page (same site, so the cookie is sent): refused by the Origin check
                  expect "cross.post.origin" ("http://127.0.0.1:" <> show crossPort)
                , expect "cross.post.status" "403"
                , expectText "cross.text" "did not come from a page of this service"
                , -- a no-referrer page makes the browser send Origin: null: still refused (no exception)
                  expect "nullorigin.post.origin" "null"
                , expect "nullorigin.post.status" "403"
                , expectText "nullorigin.text" "did not come from a page of this service"
                , -- read-only pages keep no-referrer
                  expect "center.referrer_policy" "no-referrer"
                , -- sign-out through the served form
                  expect "signout.post.origin" origin
                , expect "signout.post.status" "303"
                , expect "signout.post.location" "/"
                , expect "signout.url" (origin <> "/")
                , expect "after.status" "401"
                ]
          assertBool ("browser expectations failed:\n" <> L.unlines failures) (L.null failures)
          -- durable state, from PostgreSQL
          queryInts (fxAdmin fx) (fxDb fx) "SELECT revision::integer AS v FROM lockstep_workspace" >>= (@?= [1])
          renamed <- queryBool (fxAdmin fx) (fxDb fx) "SELECT name = 'Browser Renamed' AS v FROM lockstep_workspace"
          assertBool "the workspace was not renamed by the browser form" renamed
          queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_command_receipts" >>= (@?= [2])
          queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_command_receipts WHERE actor = 'browser-session'" >>= (@?= [2])
          queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_command_receipts WHERE command_kind = 'rename-workspace' AND outcome = 'applied'" >>= (@?= [1])
          queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_command_receipts WHERE command_kind = 'queue-noop' AND outcome = 'queued'" >>= (@?= [1])
          queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_jobs WHERE state = 'succeeded' AND steps_done = 2" >>= (@?= [1])
          queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_operator_sessions" >>= (@?= [1])
          queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_operator_sessions WHERE revoked_at IS NULL" >>= (@?= [0])
          assertBool "the database password appeared in the server log" (not (adminPassword (fxAdmin fx) `L.isInfixOf` serverLog))
    ]

data Fixture
  = Fixture
  { fxAdmin :: AdminSettings
  , fxDb :: T.Text
  , fxEnv :: [(String, String)]
  }

withMigrated :: (Fixture -> String -> IO a) -> IO a
withMigrated action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-browser" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      let
        fx = Fixture admin db [("LOCKSTEP_CONFIG", path)]
      (code, _, err) <- runLockstep (fxEnv fx) ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      action fx dir

-- | The browser steps (C-P1.7-R1 §5), as the driver's JSON input.
scenario :: Int -> Int -> Int -> String -> String
scenario port crossPort nullPort link =
  let
    base = "http://127.0.0.1:" <> show port
    renameButton = "form[action=\"/operator/commands/rename-workspace\"] button"
    renameCsrf = "form[action=\"/operator/commands/rename-workspace\"] input[name=\"csrf\"]"
    nameField = "input[name=\"name\"]"
    attacker label =
      "<!doctype html><html><body><form method=\"post\" action=\""
        <> base
        <> "/operator/commands/rename-workspace\">"
        <> "<input name=\"name\" value=\""
        <> label
        <> "\"><input name=\"expected_revision\" value=\"1\">"
        <> "<input name=\"idempotency_key\" value=\"attack-key-"
        <> fmap (\c -> if Char.isAlphaNum c then c else '-') label
        <> "-0001\"><input name=\"csrf\" value=\"__CSRF__\">"
        <> "<button id=\"go\">Go</button></form></body></html>"
  in
    jsonList
      [ obj [("op", str "open"), ("label", str "confirm"), ("url", str link)]
      , obj [("op", str "click"), ("label", str "signin"), ("selector", str "form[action=\"/operator/sign-in\"] button")]
      , obj [("op", str "open"), ("label", str "op"), ("url", str (base <> "/operator"))]
      , obj [("op", str "set_dom_value"), ("selector", str renameCsrf), ("value", str "0qaHzxn_v8Upc4bffhI6afA_xIAGTDTqTqbLRVQjALU")]
      , obj [("op", str "type"), ("selector", str nameField), ("text", str "Tampered")]
      , obj [("op", str "click"), ("label", str "tamper"), ("selector", str renameButton)]
      , obj [("op", str "open"), ("label", str "op2"), ("url", str (base <> "/operator"))]
      , obj [("op", str "type"), ("selector", str nameField), ("text", str "Browser Renamed")]
      , obj [("op", str "click"), ("label", str "rename"), ("selector", str renameButton)]
      , obj [("op", str "open"), ("label", str "queueform"), ("url", str (base <> "/operator/jobs/new"))]
      , obj [("op", str "type"), ("selector", str "input[name=\"steps\"]"), ("text", str "2")]
      , obj [("op", str "type"), ("selector", str "input[name=\"step_ms\"]"), ("text", str "50")]
      , obj [("op", str "click"), ("label", str "queue"), ("selector", str "form[action=\"/operator/commands/queue-noop\"] button")]
      , obj [("op", str "open"), ("label", str "op3"), ("url", str (base <> "/operator"))]
      , obj
          [ ("op", str "serve")
          , ("port", show crossPort)
          , ("html", str (attacker "Cross Origin"))
          , ("fill", obj [("__CSRF__", str renameCsrf)])
          ]
      , obj
          [ ("op", str "serve")
          , ("port", show nullPort)
          , ("html", str (attacker "Null Origin"))
          , ("headers", obj [("Referrer-Policy", str "no-referrer")])
          , ("fill", obj [("__CSRF__", str renameCsrf)])
          ]
      , obj [("op", str "open"), ("label", str "crosspage"), ("url", str ("http://127.0.0.1:" <> show crossPort <> "/"))]
      , obj [("op", str "click"), ("label", str "cross"), ("selector", str "#go")]
      , obj [("op", str "open"), ("label", str "nullpage"), ("url", str ("http://127.0.0.1:" <> show nullPort <> "/"))]
      , obj [("op", str "click"), ("label", str "nullorigin"), ("selector", str "#go")]
      , obj [("op", str "open"), ("label", str "center"), ("url", str (base <> "/operator/center"))]
      , obj [("op", str "open"), ("label", str "op4"), ("url", str (base <> "/operator"))]
      , obj [("op", str "click"), ("label", str "signout"), ("selector", str "form[action=\"/operator/sign-out\"] button")]
      , obj [("op", str "open"), ("label", str "after"), ("url", str (base <> "/operator"))]
      ]

{- | Runs the driver (at most 120 s) and returns its key/value observations.
The job queued through the form is given time to finish before returning.
-}
runDriver :: String -> IO [(String, String)]
runDriver input = do
  result <-
    timeout 120000000 $
      Process.readCreateProcessWithExitCode (Process.proc "python3" ["test/browser/cdp.py"]) input
  case result of
    Nothing -> assertFailure "the browser driver did not finish within 120 s"
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
        Nothing -> threadDelay 1000000 >> pure pairs

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
