{-# LANGUAGE OverloadedStrings #-}

module Lockstep.OperatorTrustTest
  ( tests
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Bits (testBit)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Numeric (showHex)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Database (runMigrations)
import Lockstep.Foundation.OperatorToken (csrfFor, decodeToken, tokenDigest)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader, responseHeaders)
import Lockstep.Support.Postgres
  ( AdminSettings (..)
  , adminExecute
  , databaseConfigFor
  , queryBool
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
    "operator trust (PostgreSQL + real binary)"
    [ testCase "operator sign-in prints one loopback URL and stores only the token's SHA-256 digest" $
        withMigrated $ \fx -> do
          port <- freePort
          (code, out, err) <- runLockstep (fxEnv fx) ["operator", "sign-in", "--port", show port]
          code @?= ExitSuccess
          err @?= ""
          case L.lines out of
            [line] -> do
              let
                prefix = "http://127.0.0.1:" <> show port <> "/operator/sign-in?token="
              assertBool ("unexpected URL: " <> line) (prefix `L.isPrefixOf` line)
              let
                token = L.drop (L.length prefix) line
              L.length token @?= 43
              hexDigest <- digestHex token
              rows <- queryInts (fxAdmin fx) (fxDb fx) ("SELECT count(*)::integer AS v FROM lockstep_operator_sign_in_tokens WHERE digest = decode('" <> hexDigest <> "', 'hex')")
              rows @?= [1]
              total <- queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_operator_sign_in_tokens"
              total @?= [1]
              rawHex <- rawTokenHex token
              stored <- queryInts (fxAdmin fx) (fxDb fx) ("SELECT count(*)::integer AS v FROM lockstep_operator_sign_in_tokens WHERE digest = decode('" <> rawHex <> "', 'hex') OR position(convert_to('" <> token <> "', 'UTF8') in digest) > 0")
              stored @?= [0]
              fresh <- queryBool (fxAdmin fx) (fxDb fx) "SELECT bool_and(expires_at BETWEEN now() + interval '4 minutes' AND now() + interval '5 minutes 5 seconds' AND consumed_at IS NULL) AS v FROM lockstep_operator_sign_in_tokens"
              assertBool "expiry is not about 5 minutes" fresh
            other -> assertFailure ("expected exactly one stdout line, got " <> show other)
    , testCase "operator sign-in refuses an unmigrated database (exit 69) and an unset config (exit 66)" $ do
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-config" $ \dir -> do
            path <- writeConfigFile dir admin db (adminPassword admin)
            (code, out, err) <- runLockstep [("LOCKSTEP_CONFIG", path)] ["operator", "sign-in"]
            code @?= ExitFailure 69
            out @?= ""
            contains "not_ready" err
            (code2, _, _) <- runLockstep [("LOCKSTEP_CONFIG", path)] ["operator", "sign-out-all"]
            code2 @?= ExitFailure 69
            noSecret admin [out, err]
        (code3, out3, _) <- runLockstep [] ["operator", "sign-in"]
        code3 @?= ExitFailure 66
        out3 @?= ""
        (code4, _, _) <- runLockstep [] ["operator", "sign-out-all"]
        code4 @?= ExitFailure 66
    , testCase "happy path: confirm, exchange, operator page, sign-out with CSRF; bounded token exposure" $
        withOperatorService $ \fx port -> do
          (token, cliErr) <- issue fx port
          confirm <- httpRequest port "GET" ("/operator/sign-in?token=" <> token) [] ""
          responseStatus confirm @?= 200
          responseHeader "Cache-Control" confirm @?= Just "no-store"
          responseHeader "Referrer-Policy" confirm @?= Just "origin"
          occurrences (BS8.pack token) (responseBody confirm) @?= 1
          exchange <- signInPost port token [exactOrigin port, sameOriginReferer port, ("Sec-Fetch-Site", "same-origin")]
          responseStatus exchange @?= 303
          responseHeader HTTP.hLocation exchange @?= Just "/operator"
          responseHeader "Cache-Control" exchange @?= Just "no-store"
          responseHeader "Referrer-Policy" exchange @?= Just "no-referrer"
          cookie <- sessionCookie exchange
          setCookie <- singleSetCookie exchange
          traverse_
            (\attr -> assertBool ("Set-Cookie lacks " <> BS8.unpack attr) (attr `BS.isInfixOf` setCookie))
            ["HttpOnly", "SameSite=Strict", "Path=/", "Max-Age=43200"]
          assertBool "Set-Cookie must not be Secure on loopback HTTP" (not ("Secure" `BS.isInfixOf` setCookie))
          sessions <- queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_operator_sessions"
          sessions @?= [1]
          consumed <- queryBool (fxAdmin fx) (fxDb fx) "SELECT bool_and(consumed_at IS NOT NULL) AS v FROM lockstep_operator_sign_in_tokens"
          assertBool "the token was not marked consumed" consumed
          operatorPage <- httpRequest port "GET" "/operator" [cookieHeader cookie] ""
          responseStatus operatorPage @?= 200
          responseHeader "Cache-Control" operatorPage @?= Just "no-store"
          responseHeader "Referrer-Policy" operatorPage @?= Just "origin"
          csrf <- csrfOf cookie
          contains' "/operator/sign-out" (responseBody operatorPage)
          contains' csrf (responseBody operatorPage)
          contains' "expires" (lowerBS (responseBody operatorPage))
          home <- httpRequest port "GET" "/" [cookieHeader cookie] ""
          responseStatus home @?= 200
          signOut <- httpRequest port "POST" "/operator/sign-out" [cookieHeader cookie, exactOrigin port, formType] ("csrf=" <> csrf)
          responseStatus signOut @?= 303
          responseHeader HTTP.hLocation signOut @?= Just "/"
          cleared <- singleSetCookie signOut
          assertBool "sign-out does not clear the cookie" ("lockstep_session=;" `BS.isPrefixOf` cleared && "Max-Age=0" `BS.isInfixOf` cleared)
          after <- httpRequest port "GET" "/operator" [cookieHeader cookie] ""
          responseStatus after @?= 401
          reused <- signInPost port token [exactOrigin port]
          responseStatus reused @?= 403
          pure
            ( [token]
            , [cliErr]
            , [exchange, operatorPage, home, signOut, after, reused]
            , [stripBody confirm]
            )
    , testCase "browser-shaped sign-in [D-2d]: Origin null is refused and does not consume the token" $
        withOperatorService $ \fx port -> do
          (token, _) <- issue fx port
          nullOrigin <- signInPost port token [("Origin", "null"), ("Sec-Fetch-Site", "same-origin")]
          responseStatus nullOrigin @?= 403
          unconsumed <- queryBool (fxAdmin fx) (fxDb fx) "SELECT bool_and(consumed_at IS NULL) AS v FROM lockstep_operator_sign_in_tokens"
          assertBool "a refused Origin consumed the token" unconsumed
          noOrigin <- signInPost port token []
          responseStatus noOrigin @?= 403
          foreignOrigin <- signInPost port token [("Origin", "http://attacker.example")]
          responseStatus foreignOrigin @?= 403
          browser <- signInPost port token [exactOrigin port, sameOriginReferer port, ("Sec-Fetch-Site", "same-origin")]
          responseStatus browser @?= 303
          pure ([token], [], [nullOrigin, noOrigin, foreignOrigin, browser], [])
    , testCase "token refusals: reused, expired and unknown tokens answer 403 and create no session" $
        withOperatorService $ \fx port -> do
          (first, _) <- issue fx port
          ok <- signInPost port first [exactOrigin port]
          responseStatus ok @?= 303
          reused <- signInPost port first [exactOrigin port]
          responseStatus reused @?= 403
          (expired, _) <- issue fx port
          expiredHex <- digestHex expired
          adminExecute (fxAdmin fx) (T.unpack (fxDb fx)) ("UPDATE lockstep_operator_sign_in_tokens SET expires_at = now() - interval '1 second' WHERE digest = decode('" <> expiredHex <> "', 'hex')")
          late <- signInPost port expired [exactOrigin port]
          responseStatus late @?= 403
          unknown <- signInPost port "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" [exactOrigin port]
          responseStatus unknown @?= 403
          sessions <- queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_operator_sessions"
          sessions @?= [1]
          pure ([first, expired], [], [ok, reused, late, unknown], [])
    , testCase "two concurrent exchanges of one token: exactly one succeeds and one session exists" $
        withOperatorService $ \fx port -> do
          (token, _) <- issue fx port
          a <- newEmptyMVar
          b <- newEmptyMVar
          _ <- forkIO (signInPost port token [exactOrigin port] >>= putMVar a)
          _ <- forkIO (signInPost port token [exactOrigin port] >>= putMVar b)
          ra <- takeMVar a
          rb <- takeMVar b
          L.sort [responseStatus ra, responseStatus rb] @?= [303, 403]
          sessions <- queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_operator_sessions"
          sessions @?= [1]
          pure ([token], [], [ra, rb], [])
    , testCase "session refusals: expired session, sign-out-all, and missing or wrong CSRF" $
        withOperatorService $ \fx port -> do
          (t1, _) <- issue fx port
          c1 <- signInPost port t1 [exactOrigin port] >>= sessionCookie
          missingCsrf <- httpRequest port "POST" "/operator/sign-out" [cookieHeader c1, exactOrigin port, formType] ""
          responseStatus missingCsrf @?= 403
          wrongCsrf <- httpRequest port "POST" "/operator/sign-out" [cookieHeader c1, exactOrigin port, formType] "csrf=0qaHzxn_v8Upc4bffhI6afA_xIAGTDTqTqbLRVQjALU"
          responseStatus wrongCsrf @?= 403
          still <- httpRequest port "GET" "/operator" [cookieHeader c1] ""
          responseStatus still @?= 200
          c1Hex <- digestHex (BS8.unpack c1)
          adminExecute (fxAdmin fx) (T.unpack (fxDb fx)) ("UPDATE lockstep_operator_sessions SET expires_at = now() - interval '1 second' WHERE digest = decode('" <> c1Hex <> "', 'hex')")
          expired <- httpRequest port "GET" "/operator" [cookieHeader c1] ""
          responseStatus expired @?= 401
          (t2, _) <- issue fx port
          c2 <- signInPost port t2 [exactOrigin port] >>= sessionCookie
          (t3, _) <- issue fx port
          c3 <- signInPost port t3 [exactOrigin port] >>= sessionCookie
          (code, out, err) <- runLockstep (fxEnv fx) ["operator", "sign-out-all"]
          code @?= ExitSuccess
          out @?= "revoked sessions: 2\n"
          r2 <- httpRequest port "GET" "/operator" [cookieHeader c2] ""
          responseStatus r2 @?= 401
          r3 <- httpRequest port "GET" "/operator" [cookieHeader c3] ""
          responseStatus r3 @?= 401
          (code', out', _) <- runLockstep (fxEnv fx) ["operator", "sign-out-all"]
          code' @?= ExitSuccess
          out' @?= "revoked sessions: 0\n"
          pure ([t1, t2, t3], [out, err], [missingCsrf, wrongCsrf, still, expired, r2, r3], [])
    , testCase "Host and Origin over HTTP: foreign or localhost Host and foreign or missing Origin answer 403" $
        withOperatorService $ \fx port -> do
          (token, _) <- issue fx port
          cookie <- signInPost port token [exactOrigin port] >>= sessionCookie
          csrf <- csrfOf cookie
          foreignHost <- httpRequest port "GET" "/" [("Host", "attacker.example:" <> BS8.pack (show port))] ""
          responseStatus foreignHost @?= 403
          localhost <- httpRequest port "GET" "/operator" [("Host", "localhost:" <> BS8.pack (show port)), cookieHeader cookie] ""
          responseStatus localhost @?= 403
          foreignOrigin <- httpRequest port "POST" "/operator/sign-out" [cookieHeader cookie, ("Origin", "http://attacker.example"), formType] ("csrf=" <> csrf)
          responseStatus foreignOrigin @?= 403
          missingOrigin <- httpRequest port "POST" "/operator/sign-out" [cookieHeader cookie, formType] ("csrf=" <> csrf)
          responseStatus missingOrigin @?= 403
          still <- httpRequest port "GET" "/operator" [cookieHeader cookie] ""
          responseStatus still @?= 200
          pure ([token], [], [foreignHost, localhost, foreignOrigin, missingOrigin, still], [])
    , testCase "malformed input answers 4xx, never 500" $
        withOperatorService $ \fx port -> do
          (token, _) <- issue fx port
          garbage <- httpRequest port "GET" "/operator" [(HTTP.hCookie, "lockstep_session=\"\\;;;==")] ""
          responseStatus garbage @?= 401
          long <- httpRequest port "GET" "/operator" [(HTTP.hCookie, "lockstep_session=" <> BS8.replicate 6000 'A')] ""
          assertBool ("over-long cookie: " <> show (responseStatus long)) (is4xx (responseStatus long))
          nonUtf8 <- httpRequest port "POST" "/operator/sign-in" [exactOrigin port, formType] "token=\255\254\253"
          assertBool ("non-UTF-8 body: " <> show (responseStatus nonUtf8)) (is4xx (responseStatus nonUtf8))
          noField <- httpRequest port "POST" "/operator/sign-in" [exactOrigin port, formType] "other=1"
          responseStatus noField @?= 400
          huge <- httpRequest port "POST" "/operator/sign-in" [exactOrigin port, formType] ("token=" <> BS8.replicate 200000 'A')
          assertBool ("huge body: " <> show (responseStatus huge)) (is4xx (responseStatus huge))
          ok <- signInPost port token [exactOrigin port]
          responseStatus ok @?= 303
          pure ([token], [], [garbage, long, nonUtf8, noField, huge, ok], [])
    , testCase "db migrate from revision 1 needs a backup decision for migration 0002 (exit 75, then --no-backup)" $ do
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-config" $ \dir -> do
            config <- databaseConfigFor admin db
            first <- withRuntime config (runMigrations (L.take 1 migrations))
            fmap L.length first @?= Right 1
            path <- writeConfigFile dir admin db (adminPassword admin)
            let
              env = [("LOCKSTEP_CONFIG", path)]
            (code, out, err) <- runLockstep env ["db", "migrate"]
            code @?= ExitFailure 75
            out @?= ""
            (_, status1, _) <- runLockstep env ["db", "status"]
            contains "revision 1" status1
            (code2, out2, err2) <- runLockstep env ["db", "migrate", "--no-backup"]
            code2 @?= ExitSuccess
            contains "applied migrations: 2" out2
            noSecret admin [out, err, status1, out2, err2]
    ]

data Fixture
  = Fixture
  { fxAdmin :: AdminSettings
  , fxDb :: T.Text
  , fxEnv :: [(String, String)]
  }

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

{- | A migrated database and a running service. The action returns the raw
tokens it used, CLI streams, responses that must not contain any of the tokens,
and responses that may contain them only in the confirm-page body (already
checked by the action). After the service stops, the bounded-exposure and
database-password checks run over everything, the server log included.
-}
withOperatorService ::
  (Fixture -> Int -> IO ([String], [String], [HttpResponse], [HttpResponse])) ->
  Assertion
withOperatorService action =
  withMigrated $ \fx -> withSystemTempDirectory "lockstep-log" $ \dir -> do
    port <- freePort
    ((tokens, streams, clean, confirmHeaders), serverLog) <-
      withService (fxEnv fx) port (dir <> "/serve.log") (action fx port)
    let
      cleanTexts = fmap renderResponse clean <> fmap renderResponse confirmHeaders
    traverse_
      ( \token -> do
          assertBool "a raw token appeared in the server log" (not (token `L.isInfixOf` serverLog))
          assertBool "a raw token appeared in CLI stderr or other output" (not (any (token `L.isInfixOf`) streams))
          assertBool "a raw token appeared in a response outside the confirm page" (not (any (BS8.pack token `BS.isInfixOf`) cleanTexts))
      )
      tokens
    noSecret (fxAdmin fx) (serverLog : streams <> fmap BS8.unpack cleanTexts)

-- | Issues a sign-in token for the port; returns it and the CLI's stderr.
issue :: Fixture -> Int -> IO (String, String)
issue fx port = do
  (code, out, err) <- runLockstep (fxEnv fx) ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  case L.stripPrefix ("http://127.0.0.1:" <> show port <> "/operator/sign-in?token=") (L.filter (/= '\n') out) of
    Just token -> pure (token, err)
    Nothing -> assertFailure ("unexpected sign-in output: " <> out)

signInPost :: Int -> String -> [HTTP.Header] -> IO HttpResponse
signInPost port token headers =
  httpRequest port "POST" "/operator/sign-in" (formType : headers) ("token=" <> BS8.pack token)

exactOrigin :: Int -> HTTP.Header
exactOrigin port =
  ("Origin", "http://127.0.0.1:" <> BS8.pack (show port))

sameOriginReferer :: Int -> HTTP.Header
sameOriginReferer port =
  ("Referer", "http://127.0.0.1:" <> BS8.pack (show port) <> "/")

formType :: HTTP.Header
formType =
  (HTTP.hContentType, "application/x-www-form-urlencoded")

cookieHeader :: BS.ByteString -> HTTP.Header
cookieHeader value =
  (HTTP.hCookie, "lockstep_session=" <> value)

singleSetCookie :: HttpResponse -> IO BS.ByteString
singleSetCookie response =
  case responseHeaders "Set-Cookie" response of
    [value] -> pure value
    other -> assertFailure ("expected one Set-Cookie, got " <> show other)

sessionCookie :: HttpResponse -> IO BS.ByteString
sessionCookie response = do
  responseStatus response @?= 303
  value <- singleSetCookie response
  case BS.stripPrefix "lockstep_session=" value of
    Just rest -> pure (BS8.takeWhile (/= ';') rest)
    Nothing -> assertFailure "Set-Cookie is not lockstep_session"

csrfOf :: BS.ByteString -> IO BS.ByteString
csrfOf cookie =
  case decodeToken (TE.decodeLatin1 cookie) of
    Just session -> pure (TE.encodeUtf8 (csrfFor session))
    Nothing -> assertFailure "the session cookie is not a token"

digestHex :: String -> IO String
digestHex token =
  case decodeToken (T.pack token) of
    Just raw -> pure (hex (tokenDigest raw))
    Nothing -> assertFailure ("not a token: " <> token)

-- | The token's own bytes as hex (base64url decoded here, independently).
rawTokenHex :: String -> IO String
rawTokenHex token =
  let
    value c
      | Char.isAsciiUpper c = Just (Char.ord c - Char.ord 'A')
      | Char.isAsciiLower c = Just (Char.ord c - Char.ord 'a' + 26)
      | Char.isDigit c = Just (Char.ord c - Char.ord '0' + 52)
      | c == '-' = Just 62
      | c == '_' = Just 63
      | otherwise = Nothing
    bits = L.concatMap (\v -> [if testBit v i then 1 else 0 | i <- [5, 4, 3, 2, 1, 0]])
    bytes bs =
      case L.splitAt 8 bs of
        (byte, rest) | L.length byte == 8 -> L.foldl' (\acc b -> acc * 2 + b) 0 byte : bytes rest
        _ -> []
  in
    case traverse value token of
      Just values -> pure (hex (BS.pack (fmap fromIntegral (bytes (bits values :: [Int])))))
      Nothing -> assertFailure "not base64url"

hex :: BS.ByteString -> String
hex =
  L.concatMap byte . BS.unpack
 where
  byte w =
    let
      digits = showHex w ""
    in
      if L.length digits < 2 then '0' : digits else digits

renderResponse :: HttpResponse -> BS.ByteString
renderResponse response =
  BS.concat (fmap snd (responseHeaderList response)) <> responseBody response

stripBody :: HttpResponse -> HttpResponse
stripBody response =
  response {responseBody = ""}

occurrences :: BS.ByteString -> BS.ByteString -> Int
occurrences needle haystack =
  let
    (_, rest) = BS.breakSubstring needle haystack
  in
    if BS.null rest
      then 0
      else 1 + occurrences needle (BS.drop (BS.length needle) rest)

is4xx :: Int -> Bool
is4xx status =
  status >= 400 && status < 500

lowerBS :: BS.ByteString -> BS.ByteString
lowerBS =
  BS8.map Char.toLower

contains :: String -> String -> Assertion
contains needle haystack =
  assertBool ("expected output to contain " <> needle <> " in:\n" <> haystack) (needle `L.isInfixOf` haystack)

contains' :: BS.ByteString -> BS.ByteString -> Assertion
contains' needle haystack =
  assertBool ("expected the page to contain " <> BS8.unpack needle) (needle `BS.isInfixOf` haystack)

noSecret :: AdminSettings -> [String] -> Assertion
noSecret admin outputs =
  assertBool
    "the database password appeared in output or a page"
    (not (any (adminPassword admin `L.isInfixOf`) outputs))
