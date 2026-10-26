{-# LANGUAGE OverloadedStrings #-}

{- | Human decisions over real HTTP (contract C-P3.8 M5–M7): the real service
on a 'Lockstep.Support.Ledger.withLedger' database; the decisions are made
ready in this process through the C-P2.5 ledger; the session comes from the
real CLI as in C-P3.4.
-}
module Lockstep.DecisionsPageTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Exit (ExitCode (ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Effect (OperationId (..))
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidText)
import Lockstep.Support.Decisions (stepWithUnknownOutcome, stoppedWork)
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Ledger (Ledger (..), count, withLedger)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data Svc
  = Svc
  { svcPort :: Int
  , svcSession :: BS.ByteString
  , svcLedger :: Ledger
  }

withDecisions :: (Svc -> IO ()) -> IO ()
withDecisions action =
  withLedger $ \lg -> do
    port <- freePort
    (result, _) <-
      withService (lgEnv lg) port (lgDir lg <> "/serve.log") $ do
        session <- signIn port (lgEnv lg)
        action (Svc port session lg)
    pure result

origin :: Int -> BS.ByteString
origin port =
  "http://127.0.0.1:" <> BS8.pack (show port)

signIn :: Int -> [(String, String)] -> IO BS.ByteString
signIn port env = do
  (code, out, err) <- runLockstep env ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  token <-
    case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
      Just t | L.length t == 43 -> pure (BS8.pack t)
      _ -> assertFailure ("unexpected sign-in output: " <> out <> err)
  resp <- httpRequest port "POST" "/app/api/session" [("Origin", origin port)] token
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

fragment :: Svc -> String -> IO HttpResponse
fragment svc path =
  httpRequest (svcPort svc) "GET" ("/app/fragments/" <> path) [("X-Lockstep-Session", svcSession svc)] ""

post :: Svc -> [HTTPTypes.Header] -> String -> [(BS.ByteString, BS.ByteString)] -> IO HttpResponse
post svc headers path fields =
  httpRequest (svcPort svc) "POST" path (("Content-Type", "application/x-www-form-urlencoded") : headers) (HTTPTypes.renderSimpleQuery False fields)

asOperator :: Svc -> [HTTPTypes.Header]
asOperator svc =
  [("Origin", origin (svcPort svc)), ("X-Lockstep-Session", svcSession svc)]

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

has :: BS.ByteString -> [BS.ByteString] -> IO ()
has body =
  traverse_ (\needle -> assertBool ("missing " <> show needle <> ": " <> show body) (contains needle body))

inputValue :: BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
inputValue name page =
  let
    after = snd (BS.breakSubstring ("name=\"" <> name <> "\" value=\"") page)
  in
    if BS.null after
      then Nothing
      else Just (BS.takeWhile (/= 0x22) (BS.drop (BS.length name + 15) after))

ordinary :: BS.ByteString -> BS.ByteString
ordinary =
  BS8.map Char.toLower . fst . BS.breakSubstring "<details"

woId :: WorkOrderId -> String
woId (WorkOrderId u) =
  T.unpack (uuidText u)

opId :: OperationId -> String
opId (OperationId u) =
  T.unpack (uuidText u)

-- | The decision page's form fields, with the page's own key and expected value.
formFor :: Svc -> String -> [(BS.ByteString, BS.ByteString)] -> IO [(BS.ByteString, BS.ByteString)]
formFor svc subject fields = do
  page <- fragment svc ("decision/" <> subject)
  responseStatus page @?= 200
  k <- maybe (assertFailure "no key") pure (inputValue "key" (responseBody page))
  e <- maybe (assertFailure "no expected value") pure (inputValue "expected" (responseBody page))
  pure ([("key", k), ("expected", e)] <> fields)

tests :: TestTree
tests =
  testGroup
    "human decisions over HTTP (C-P3.8)"
    [ testCase "the Decisions section lists each open decision as a link and says what arrives later" $
        withDecisions $ \svc -> do
          empty <- fragment svc "decisions"
          has (responseBody empty) ["Nothing needs your decision right now.", "later update"]
          wo <- stoppedWork (svcLedger svc) "Print the menu" "the printer jammed"
          (_, op) <- stepWithUnknownOutcome (svcLedger svc) "Send the invoice"
          section <- fragment svc "decisions"
          responseStatus section @?= 200
          let
            body = responseBody section
          has body ["href=\"/app/decisions/" <> BS8.pack wo' <> "\"" | wo' <- [woId wo, opId op]]
          has body ["Print the menu", "Send the invoice", "later update"]
          assertBool "a form on the section" (not (contains "<form" body))
          assertBool "a button on the section" (not (contains "<button" body))
          home <- fragment svc "home"
          has (responseBody home) ["href=\"/app/decisions\""]
    , testCase "a decision page says what it is about, how it stands, and what each choice will do" $
        withDecisions $ \svc -> do
          wo <- stoppedWork (svcLedger svc) "Print the menu" "the printer jammed"
          stopped <- fragment svc ("decision/" <> woId wo)
          responseStatus stopped @?= 200
          has
            (responseBody stopped)
            [ "Print the menu"
            , "the printer jammed"
            , "Put it back in line"
            , "Cancel this work"
            , "goes back to the queue"
            , "name=\"expected\" value=\"4\""
            , "name=\"key\" value=\""
            , "action=\"/app/api/decisions/" <> BS8.pack (woId wo) <> "\""
            , "id=\"choice-put-back\""
            , "id=\"decide\""
            , "<details"
            ]
          assertBool "an answer that does not apply" (not (contains "It happened" (responseBody stopped)))
          (_, op) <- stepWithUnknownOutcome (svcLedger svc) "Send the invoice"
          unknown <- fragment svc ("decision/" <> opId op)
          has
            (responseBody unknown)
            [ "Send the invoice"
            , "the mail server timed out"
            , "It happened"
            , "It did not happen"
            , "Try it again"
            , "Give up on it"
            , "name=\"expected\" value=\"1\""
            , "id=\"acknowledge\""
            , "name=\"text\""
            ]
          shell <- httpRequest (svcPort svc) "GET" ("/app/decisions/" <> woId wo) [] ""
          responseStatus shell @?= 200
    , testCase "deciding needs the session and this origin; the answer is Done, and a replay returns the same receipt" $
        withDecisions $ \svc -> do
          wo <- stoppedWork (svcLedger svc) "Print the menu" "the printer jammed"
          fields <- formFor svc (woId wo) [("choice", "put-back")]
          let
            path = "/app/api/decisions/" <> woId wo
          none <- post svc [("Origin", origin (svcPort svc))] path fields
          responseStatus none @?= 401
          elsewhere <- post svc [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", svcSession svc)] path fields
          responseStatus elsewhere @?= 403
          count (svcLedger svc) "lockstep_decision_receipts" >>= (@?= 0)
          done <- post svc (asOperator svc) path fields
          responseStatus done @?= 200
          has (responseBody done) ["Done", "Put it back in line", "href=\"/app/decisions\""]
          responseHeader "X-Lockstep-Path" done @?= Just (BS8.pack ("/app/decisions/" <> woId wo))
          again <- post svc (asOperator svc) path fields
          has (responseBody again) ["Done", "already recorded"]
          count (svcLedger svc) "lockstep_decision_receipts" >>= (@?= 1)
          decided <- fragment svc ("decision/" <> woId wo)
          responseStatus decided @?= 200
          has (responseBody decided) ["Put it back in line"]
          assertBool "a decided page still offers choices" (not (contains "<form" (responseBody decided)))
    , testCase "a stale page and a missing acknowledgment are explained in words and change nothing" $
        withDecisions $ \svc -> do
          wo <- stoppedWork (svcLedger svc) "Print the menu" "the printer jammed"
          fields <- formFor svc (woId wo) [("choice", "cancel")]
          let
            stale = [(k, if k == "expected" then "3" else v) | (k, v) <- fields]
          resp <- post svc (asOperator svc) ("/app/api/decisions/" <> woId wo) stale
          responseStatus resp @?= 200
          has (responseBody resp) ["changed since the page was shown", "name=\"expected\" value=\"4\""]
          (_, op) <- stepWithUnknownOutcome (svcLedger svc) "Send the invoice"
          retry <- formFor svc (opId op) [("choice", "try-again")]
          unacknowledged <- post svc (asOperator svc) ("/app/api/decisions/" <> opId op) retry
          has (responseBody unacknowledged) ["Tick the box", "Try it again"]
          emptyText <- formFor svc (opId op) [("choice", "happened"), ("text", "  ")]
          noWords <- post svc (asOperator svc) ("/app/api/decisions/" <> opId op) emptyText
          has (responseBody noWords) ["Write what you saw"]
          open <- fragment svc "decisions"
          has (responseBody open) ["Print the menu", "Send the invoice"]
    , testCase "typed text is escaped, and the ordinary text has no internal words" $
        withDecisions $ \svc -> do
          wo <- stoppedWork (svcLedger svc) "<script>alert(1)</script>" "<b>jam</b>"
          page <- fragment svc ("decision/" <> woId wo)
          assertBool "markup was not escaped" (not (contains "<script>alert(1)" (responseBody page)) && not (contains "<b>jam" (responseBody page)))
          has (responseBody page) ["&lt;script&gt;alert(1)&lt;/script&gt;"]
          (_, op) <- stepWithUnknownOutcome (svcLedger svc) "Send the invoice"
          traverse_
            ( \p -> do
                resp <- fragment svc p
                traverse_
                  (\word -> assertBool ("internal word " <> show word <> " in " <> p) (not (contains word (ordinary (responseBody resp)))))
                  ["work order", "ticket", "intent", "generation", "supervisor", "scheduler"]
            )
            ["decisions", "decision/" <> woId wo, "decision/" <> opId op]
    , testCase "unknown decisions and other addresses are 404; bodies over 16 KiB are refused" $
        withDecisions $ \svc -> do
          wo <- stoppedWork (svcLedger svc) "Print the menu" "the printer jammed"
          missing <- fragment svc "decision/00000000-0000-4000-8000-000000000000"
          responseStatus missing @?= 404
          traverse_
            ( \p -> do
                resp <- httpRequest (svcPort svc) "GET" p [] ""
                assertBool (p <> " gave " <> show (responseStatus resp)) (responseStatus resp == 404)
            )
            ["/app/decisions/not-a-uuid", "/app/decisions/" <> woId wo <> "/more", "/app/fragments/decision/not-a-uuid"]
          big <- post svc (asOperator svc) ("/app/api/decisions/" <> woId wo) [("choice", "cancel"), ("text", BS.replicate 17000 0x61)]
          responseStatus big @?= 413
          stillOpen <- fragment svc ("decision/" <> woId wo)
          has (responseBody stillOpen) ["Put it back in line"]
    ]
