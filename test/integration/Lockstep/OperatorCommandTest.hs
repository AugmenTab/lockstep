{-# LANGUAGE OverloadedStrings #-}

module Lockstep.OperatorCommandTest
  ( tests
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Database (runMigrations)
import Lockstep.Foundation.OperatorToken (csrfFor, decodeToken)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader, responseHeaders)
import Lockstep.Support.Postgres
  ( AdminSettings (..)
  , databaseConfigFor
  , queryInts
  , requireAdmin
  , withFreshDatabase
  , withRuntime
  , writeConfigFile
  )
import Lockstep.Support.Process (freePort, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "typed operator command (PostgreSQL + real binary)"
    [ testCase "CLI: show, rename, replay, key conflict, stale and its replay" $
        withMigrated $ \fx -> do
          (c0, show0, _) <- runLockstep (fxEnv fx) ["workspace", "show"]
          c0 @?= ExitSuccess
          show0 @?= "name: Lockstep\nrevision: 0\n"
          (c1, out1, err1) <- rename fx 0 (Just keyA) "Lockstep Two"
          c1 @?= ExitSuccess
          err1 @?= ""
          (rid, rest1) <- receiptLine out1
          rest1 @?= "applied revision 1 key " <> keyA
          (_, show1, _) <- runLockstep (fxEnv fx) ["workspace", "show"]
          show1 @?= "name: Lockstep Two\nrevision: 1\n"
          (c2, out2, _) <- rename fx 0 (Just keyA) "Lockstep Two"
          c2 @?= ExitSuccess
          out2 @?= "receipt " <> rid <> " applied revision 1 key " <> keyA <> " (replayed)\n"
          receipts fx >>= (@?= [1])
          (c3, out3, err3) <- rename fx 1 (Just keyA) "Something Else"
          c3 @?= ExitFailure 65
          out3 @?= ""
          contains "idempotency key" err3
          (c4, out4, err4) <- rename fx 0 (Just keyB) "Stale Name"
          c4 @?= ExitFailure 65
          (sid, rest4) <- receiptLine out4
          rest4 @?= "refused_stale revision 1 key " <> keyB
          contains "stale" err4
          (c5, out5, _) <- rename fx 0 (Just keyB) "Stale Name"
          c5 @?= ExitFailure 65
          out5 @?= "receipt " <> sid <> " refused_stale revision 1 key " <> keyB <> " (replayed)\n"
          (_, show2, _) <- runLockstep (fxEnv fx) ["workspace", "show"]
          show2 @?= "name: Lockstep Two\nrevision: 1\n"
          receipts fx >>= (@?= [2])
          noSecret fx [show0, out1, err1, out2, out3, err3, out4, err4, out5]
    , testCase "CLI: a generated key is printed; invalid input stores nothing" $
        withMigrated $ \fx -> do
          (c1, out1, _) <- rename fx 0 Nothing "Generated"
          c1 @?= ExitSuccess
          (_, rest) <- receiptLine out1
          case L.stripPrefix "applied revision 1 key " rest of
            Just key -> L.length key @?= 22
            Nothing -> assertFailure ("unexpected receipt: " <> rest)
          (c2, out2, _) <- rename fx 1 (Just keyC) "   "
          c2 @?= ExitFailure 65
          out2 @?= ""
          (c3, _, _) <- rename fx 1 (Just keyC) (L.replicate 81 'a')
          c3 @?= ExitFailure 65
          (c4, _, _) <- rename fx 1 (Just "short") "Fine"
          c4 @?= ExitFailure 65
          receipts fx >>= (@?= [1])
          revision fx >>= (@?= [1])
    , testCase "CLI: not configured exits 66, an unmigrated database exits 69" $ do
        (c1, _, _) <- runLockstep [] ["workspace", "show"]
        c1 @?= ExitFailure 66
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-config" $ \dir -> do
            path <- writeConfigFile dir admin db (adminPassword admin)
            (c2, _, err2) <- runLockstep [("LOCKSTEP_CONFIG", path)] ["workspace", "rename", "--expected-revision", "0", "X"]
            c2 @?= ExitFailure 69
            contains "not_ready" err2
    , testCase "HTTP: operator page form, rename, receipt page, replay" $
        withOperatorService $ \fx port -> do
          (cookie, csrf) <- signIn fx port
          page <- httpRequest port "GET" "/operator" [cookieHeader cookie] ""
          responseStatus page @?= 200
          contains' "Lockstep" (responseBody page)
          fieldValue "expected_revision" (responseBody page) @?= Just "0"
          key <- maybe (assertFailure "no idempotency_key field") pure (fieldValue "idempotency_key" (responseBody page))
          BS.length key @?= 22
          first <- renamePost port cookie csrf key "0" "Browser Name" [exactOrigin port]
          responseStatus first @?= 303
          location <- maybe (assertFailure "no Location") pure (responseHeader HTTP.hLocation first)
          assertBool ("unexpected Location " <> show location) ("/operator/receipts/" `BS.isPrefixOf` location)
          receiptPage <- httpRequest port "GET" (BS8.unpack location) [cookieHeader cookie] ""
          responseStatus receiptPage @?= 200
          responseHeader "Cache-Control" receiptPage @?= Just "no-store"
          contains' "applied" (responseBody receiptPage)
          contains' key (responseBody receiptPage)
          again <- renamePost port cookie csrf key "0" "Browser Name" [exactOrigin port]
          responseStatus again @?= 303
          responseHeader HTTP.hLocation again @?= Just location
          receipts fx >>= (@?= [1])
          (_, shown, _) <- runLockstep (fxEnv fx) ["workspace", "show"]
          shown @?= "name: Browser Name\nrevision: 1\n"
          page2 <- httpRequest port "GET" "/operator" [cookieHeader cookie] ""
          fieldValue "expected_revision" (responseBody page2) @?= Just "1"
          assertBool "the form reused an idempotency key" (fieldValue "idempotency_key" (responseBody page2) /= Just key)
          missing <- httpRequest port "GET" "/operator/receipts/999999" [cookieHeader cookie] ""
          responseStatus missing @?= 404
          malformed <- httpRequest port "GET" "/operator/receipts/abc" [cookieHeader cookie] ""
          responseStatus malformed @?= 404
          pure [page, first, receiptPage, again, page2, missing, malformed]
    , testCase "CLI and HTTP share one operation: one key, one receipt" $
        withOperatorService $ \fx port -> do
          (c, out, _) <- rename fx 0 (Just keyA) "Shared"
          c @?= ExitSuccess
          (rid, _) <- receiptLine out
          (cookie, csrf) <- signIn fx port
          viaHttp <- renamePost port cookie csrf (BS8.pack keyA) "0" "Shared" [exactOrigin port]
          responseStatus viaHttp @?= 303
          responseHeader HTTP.hLocation viaHttp @?= Just ("/operator/receipts/" <> BS8.pack rid)
          conflict <- renamePost port cookie csrf (BS8.pack keyA) "1" "Different" [exactOrigin port]
          responseStatus conflict @?= 409
          receipts fx >>= (@?= [1])
          revision fx >>= (@?= [1])
          pure [viaHttp, conflict]
    , testCase "HTTP: stale, conflict and invalid input are refused without changing state" $
        withOperatorService $ \fx port -> do
          (cookie, csrf) <- signIn fx port
          ok <- renamePost port cookie csrf (BS8.pack keyA) "0" "One" [exactOrigin port]
          responseStatus ok @?= 303
          stale <- renamePost port cookie csrf (BS8.pack keyB) "0" "Two" [exactOrigin port]
          responseStatus stale @?= 409
          contains' "refused_stale" (responseBody stale)
          staleAgain <- renamePost port cookie csrf (BS8.pack keyB) "0" "Two" [exactOrigin port]
          responseStatus staleAgain @?= 409
          conflict <- renamePost port cookie csrf (BS8.pack keyA) "1" "Three" [exactOrigin port]
          responseStatus conflict @?= 409
          empty <- renamePost port cookie csrf (BS8.pack keyC) "1" "" [exactOrigin port]
          responseStatus empty @?= 400
          badRevision <- renamePost port cookie csrf (BS8.pack keyC) "x" "Four" [exactOrigin port]
          responseStatus badRevision @?= 400
          badKey <- renamePost port cookie csrf "short" "1" "Four" [exactOrigin port]
          responseStatus badKey @?= 400
          receipts fx >>= (@?= [2])
          revision fx >>= (@?= [1])
          pure [ok, stale, staleAgain, conflict, empty, badRevision, badKey]
    , testCase "HTTP authority: no session, wrong CSRF and foreign Origin store nothing" $
        withOperatorService $ \fx port -> do
          (cookie, _) <- signIn fx port
          noSession <- httpRequest port "POST" "/operator/commands/rename-workspace" [formType, exactOrigin port] (renameForm "x" (BS8.pack keyA) "0" "N")
          responseStatus noSession @?= 401
          badCsrf <- renamePost port cookie "0qaHzxn_v8Upc4bffhI6afA_xIAGTDTqTqbLRVQjALU" (BS8.pack keyA) "0" "N" [exactOrigin port]
          responseStatus badCsrf @?= 403
          foreign' <- httpRequest port "POST" "/operator/commands/rename-workspace" [formType, cookieHeader cookie, ("Origin", "http://attacker.example")] (renameForm "x" (BS8.pack keyA) "0" "N")
          responseStatus foreign' @?= 403
          receipts fx >>= (@?= [0])
          revision fx >>= (@?= [0])
          pure [noSession, badCsrf, foreign']
    , testCase "concurrency: one key twice gives one receipt; two keys at one revision give one applied, one stale" $
        withOperatorService $ \fx port -> do
          (cookie, csrf) <- signIn fx port
          (a, b) <- both (renamePost port cookie csrf (BS8.pack keyA) "0" "Same" [exactOrigin port]) (renamePost port cookie csrf (BS8.pack keyA) "0" "Same" [exactOrigin port])
          fmap responseStatus [a, b] @?= [303, 303]
          responseHeader HTTP.hLocation a @?= responseHeader HTTP.hLocation b
          receipts fx >>= (@?= [1])
          (c, d) <- both (renamePost port cookie csrf (BS8.pack keyB) "1" "B" [exactOrigin port]) (renamePost port cookie csrf (BS8.pack keyC) "1" "C" [exactOrigin port])
          L.sort (fmap responseStatus [c, d]) @?= [303, 409]
          revision fx >>= (@?= [2])
          receipts fx >>= (@?= [3])
          pure [a, b, c, d]
    , testCase "a client that disconnects right after sending does not undo the accepted command" $
        withOperatorService $ \fx port -> do
          (cookie, csrf) <- signIn fx port
          let
            body = renameForm csrf (BS8.pack keyA) "0" "Disconnected"
            raw =
              BS.concat
                [ "POST /operator/commands/rename-workspace HTTP/1.1\r\n"
                , "Host: 127.0.0.1:" <> BS8.pack (show port) <> "\r\n"
                , "Origin: http://127.0.0.1:" <> BS8.pack (show port) <> "\r\n"
                , "Cookie: lockstep_session=" <> cookie <> "\r\n"
                , "Content-Type: application/x-www-form-urlencoded\r\n"
                , "Content-Length: " <> BS8.pack (show (BS.length body)) <> "\r\n"
                , "Connection: close\r\n\r\n"
                , body
                ]
          bracket
            (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol)
            Socket.close
            ( \sock -> do
                Socket.connect sock (Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (127, 0, 0, 1)))
                SocketBS.sendAll sock raw
            )
          found <- pollReceipts fx 50
          found @?= [1]
          revision fx >>= (@?= [1])
          (_, shown, _) <- runLockstep (fxEnv fx) ["workspace", "show"]
          shown @?= "name: Disconnected\nrevision: 1\n"
          pure []
    , testCase "db migrate from revision 2 needs a backup decision for migration 0003" $ do
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-config" $ \dir -> do
            config <- databaseConfigFor admin db
            first <- withRuntime config (runMigrations (L.take 2 migrations))
            fmap L.length first @?= Right 2
            path <- writeConfigFile dir admin db (adminPassword admin)
            let
              env = [("LOCKSTEP_CONFIG", path)]
            (code, _, _) <- runLockstep env ["db", "migrate"]
            code @?= ExitFailure 75
            (code2, out2, _) <- runLockstep env ["db", "migrate", "--no-backup"]
            code2 @?= ExitSuccess
            contains "applied migrations: 3" out2
    ]

data Fixture
  = Fixture
  { fxAdmin :: AdminSettings
  , fxDb :: T.Text
  , fxEnv :: [(String, String)]
  }

keyA :: String
keyA =
  "cmd-key-aaaaaaaaaaaa"

keyB :: String
keyB =
  "cmd-key-bbbbbbbbbbbb"

keyC :: String
keyC =
  "cmd-key-cccccccccccc"

withMigrated :: (Fixture -> IO a) -> IO a
withMigrated action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-config" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      let
        fx = Fixture admin db [("LOCKSTEP_CONFIG", path)]
      (code, _, err) <- runLockstep (fxEnv fx) ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      action fx

{- | A migrated database and a running service; checks the server log and every
returned response for the database password afterwards.
-}
withOperatorService :: (Fixture -> Int -> IO [HttpResponse]) -> Assertion
withOperatorService action =
  withMigrated $ \fx -> withSystemTempDirectory "lockstep-log" $ \dir -> do
    port <- freePort
    (responses, serverLog) <- withService (fxEnv fx) port (dir <> "/serve.log") (action fx port)
    noSecret fx (serverLog : fmap (BS8.unpack . responseBody) responses)

rename :: Fixture -> Integer -> Maybe String -> String -> IO (ExitCode, String, String)
rename fx expected key name =
  runLockstep
    (fxEnv fx)
    (["workspace", "rename", "--expected-revision", show expected] <> maybe [] (\k -> ["--idempotency-key", k]) key <> [name])

-- | Splits @receipt <id> <rest>@ (one line) into the id and the rest.
receiptLine :: String -> IO (String, String)
receiptLine out =
  case L.lines out of
    [line]
      | Just rest <- L.stripPrefix "receipt " line ->
          let
            (rid, remainder) = L.break (== ' ') rest
          in
            pure (rid, L.drop 1 remainder)
    _ -> assertFailure ("expected one receipt line, got: " <> show out)

signIn :: Fixture -> Int -> IO (BS.ByteString, BS.ByteString)
signIn fx port = do
  (code, out, _) <- runLockstep (fxEnv fx) ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  token <-
    maybe (assertFailure "no token") pure $
      L.stripPrefix ("http://127.0.0.1:" <> show port <> "/operator/sign-in?token=") (L.filter (/= '\n') out)
  response <- httpRequest port "POST" "/operator/sign-in" [formType, exactOrigin port] ("token=" <> BS8.pack token)
  responseStatus response @?= 303
  cookie <-
    case responseHeaders "Set-Cookie" response of
      [value] | Just rest <- BS.stripPrefix "lockstep_session=" value -> pure (BS8.takeWhile (/= ';') rest)
      other -> assertFailure ("unexpected Set-Cookie: " <> show other)
  session <- maybe (assertFailure "cookie is not a token") pure (decodeToken (TE.decodeLatin1 cookie))
  pure (cookie, TE.encodeUtf8 (csrfFor session))

renamePost :: Int -> BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString -> [HTTP.Header] -> IO HttpResponse
renamePost port cookie csrf key expected name headers =
  httpRequest
    port
    "POST"
    "/operator/commands/rename-workspace"
    (formType : cookieHeader cookie : headers)
    (renameForm csrf key expected name)

renameForm :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
renameForm csrf key expected name =
  BS.intercalate "&" ["name=" <> HTTP.urlEncode True name, "expected_revision=" <> expected, "idempotency_key=" <> key, "csrf=" <> csrf]

-- | The value attribute of the @<input>@ whose name attribute is the given one.
fieldValue :: BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
fieldValue name body =
  let
    tags = fmap (BS8.takeWhile (/= '>')) (L.drop 1 (splitOn "<input" body))
    wanted = L.filter (BS.isInfixOf ("name=\"" <> name <> "\"")) tags
  in
    case wanted of
      [tag] ->
        case splitOn "value=\"" tag of
          [_, rest] -> Just (BS8.takeWhile (/= '"') rest)
          _ -> Nothing
      _ -> Nothing

splitOn :: BS.ByteString -> BS.ByteString -> [BS.ByteString]
splitOn sep input =
  let
    (before, rest) = BS.breakSubstring sep input
  in
    if BS.null rest
      then [before]
      else before : splitOn sep (BS.drop (BS.length sep) rest)

both :: IO a -> IO b -> IO (a, b)
both left right = do
  a <- newEmptyMVar
  b <- newEmptyMVar
  _ <- forkIO (left >>= putMVar a)
  _ <- forkIO (right >>= putMVar b)
  (,) <$> takeMVar a <*> takeMVar b

pollReceipts :: Fixture -> Int -> IO [Int]
pollReceipts fx remaining = do
  n <- receipts fx
  if n == [1] || remaining <= 0
    then pure n
    else threadDelay 100000 >> pollReceipts fx (remaining - 1)

receipts :: Fixture -> IO [Int]
receipts fx =
  queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_command_receipts"

revision :: Fixture -> IO [Int]
revision fx =
  queryInts (fxAdmin fx) (fxDb fx) "SELECT revision::integer AS v FROM lockstep_workspace"

exactOrigin :: Int -> HTTP.Header
exactOrigin port =
  ("Origin", "http://127.0.0.1:" <> BS8.pack (show port))

formType :: HTTP.Header
formType =
  (HTTP.hContentType, "application/x-www-form-urlencoded")

cookieHeader :: BS.ByteString -> HTTP.Header
cookieHeader value =
  (HTTP.hCookie, "lockstep_session=" <> value)

contains :: String -> String -> Assertion
contains needle haystack =
  assertBool ("expected output to contain " <> needle <> " in:\n" <> haystack) (needle `L.isInfixOf` haystack)

contains' :: BS.ByteString -> BS.ByteString -> Assertion
contains' needle haystack =
  assertBool ("expected the page to contain " <> BS8.unpack needle) (needle `BS.isInfixOf` haystack)

noSecret :: Fixture -> [String] -> Assertion
noSecret fx outputs =
  assertBool
    "the database password appeared in output or a page"
    (not (any (adminPassword (fxAdmin fx) `L.isInfixOf`) outputs))
