{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.8 integration: the operator commands, a real crash of a real
process, sandbox fencing, visible refusals, and the ledger page, through the
real binary and service against real PostgreSQL.
-}
module Lockstep.OperatorLedgerTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.IO (FilePath, IOMode (WriteMode), openFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeaders)
import Lockstep.Support.Ledger (Ledger (..), count, sql, withLedger)
import Lockstep.Support.Process (freePort, httpGet, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "Operator ledger commands and page (C-P2.8; real binary, service and PostgreSQL)"
    [ testCase "scenario setup: the binary scenario, polling, killing a real process, signing in" $
        withLedger $ \lg -> do
          count lg "lockstep_engineers" >>= (@?= 1)
          eventually "the engineer exists" ((== 1) <$> count lg "lockstep_engineers")
          withSystemTempDirectory "lockstep-p28" $ \tmp -> do
            port <- freePort
            handle <- spawn lg tmp "serve" ["serve", "--port", show port]
            -- any HTTP answer means it is listening (as the frozen Support.Process waitReady decides)
            eventually "the service answers" (either (const False) (const True) <$> tryGet port "/api/health_check")
            killed <- kill handle
            killed @?= ExitFailure (-9)
          withSystemTempDirectory "lockstep-p28" $ \tmp -> do
            port <- freePort
            (_, _) <-
              withService (lgEnv lg) port (tmp <> "/serve.log") $ do
                cookie <- signIn lg port
                withCookie <- httpRequest port "GET" "/operator/center" [cookieHeader cookie] ""
                responseStatus withCookie @?= 200
                without <- httpRequest port "GET" "/operator/center" [] ""
                assertBool "the center is refused without a session" (responseStatus without /= 200)
            pure ()
    , testCase "operator flow: a ticket to four applied sandbox effects, PASSED in the ledger" $
        withLedger $ \lg -> do
          (t, wo, ops) <- readyOrder lg ["sandbox-repeatable", "sandbox-idempotent", "sandbox-queryable", "sandbox-unqueryable"]
          (code, out, _) <- cli lg ["ticket", "accept", t, "--expected-revision", "1"]
          code @?= ExitFailure 65
          out @?= ["refused stale-revision"]
          fmap snd ops @?= ["sandbox-repeatable", "sandbox-idempotent", "sandbox-queryable", "sandbox-unqueryable"]
          traverse_ (\(o, _) -> okCli lg ["supervisor", "execute-once"] >>= (@?= ["executed " <> o <> " applied applied"])) ops
          okCli lg ["supervisor", "execute-once"] >>= (@?= ["idle"])
          ledger <- okCli lg ["ledger", "show"]
          assertBool "as of" (maybe False ("as of " `L.isPrefixOf`) (headMay ledger))
          L.length (L.filter ("status=PASSED" `L.isInfixOf`) ledger) @?= 4
          sandbox <- okCli lg ["sandbox", "show"]
          sandbox @?= fmap (\(o, e) -> "application " <> o <> " effect " <> e <> " count 1") ops
          unit <- okCli lg ["work-unit", "admit", wo]
          case unit of
            [line] -> assertBool line ("work-unit " `L.isPrefixOf` line)
            other -> assertFailure (show other)
    , testCase "a real crash: a killed process leaves an unqueryable effect UNKNOWN, applied once, then attested" $
        withLedger $ \lg ->
          withSystemTempDirectory "lockstep-p28" $ \tmp -> do
            (_, wo, ops) <- readyOrder lg ["sandbox-unqueryable:apply-then-hang"]
            o <- single ops
            handle <- spawn lg tmp "execute" ["supervisor", "execute-once", "--lease-seconds", "30", "--timeout-ms", "20000"]
            eventually "the effect was applied" ((== 1) <$> count lg ("lockstep_sandbox_applications WHERE operation_id = '" <> o <> "'"))
            _ <- kill handle
            effectLine lg o >>= assertContains "status=IN_PROGRESS"
            sql lg ("UPDATE lockstep_effect_intents SET lease_until = now() - interval '1 second' WHERE operation_id = '" <> o <> "'")
            effectLine lg o >>= assertContains "status=RECONCILIATION_NEEDED"
            okCli lg ["supervisor", "execute-once"] >>= (@?= ["executed " <> o <> " unknown dispatch-interrupted: unqueryable effect"])
            effectLine lg o >>= assertContains "status=UNKNOWN"
            orderLine lg wo >>= assertContains ("state=halted reason=\"outcome-unknown operation=" <> o <> "\"")
            okCli lg ["sandbox", "show"] >>= (@?= ["application " <> o <> " effect sandbox-unqueryable count 1"])
            okCli lg ["effects", "resolve", o, "--generation", "1", "--attest-applied", "the operator saw the record"]
              >>= (@?= ["intent " <> o <> " state settled generation 1"])
            line <- effectLine lg o
            assertContains "status=ATTESTED" line
            ledger <- okCli lg ["ledger", "show"]
            assertBool "nothing is PASSED" (not (L.any ("status=PASSED" `L.isInfixOf`) ledger))
    , testCase "queryable fencing: an unknown outcome looked up absent is not applied, and fenced at the destination" $
        withLedger $ \lg -> do
          (_, _, ops) <- readyOrder lg ["sandbox-queryable:hang"]
          o <- single ops
          okCli lg ["supervisor", "execute-once", "--timeout-ms", "1500"] >>= (@?= ["executed " <> o <> " unknown timeout"])
          effectLine lg o >>= assertContains "status=RECONCILIATION_NEEDED"
          okCli lg ["supervisor", "reconcile-once"] >>= (@?= ["reconciled " <> o <> " not-applied lookup: not found"])
          okCli lg ["supervisor", "reconcile-once"] >>= (@?= ["idle"])
          count lg ("lockstep_sandbox_queryable WHERE operation_id = '" <> o <> "' AND outcome = 'fenced'") >>= (@?= 1)
          okCli lg ["sandbox", "show"] >>= (@?= [])
    , testCase "idempotent crash: a killed process after its application, recovered, still one application" $
        withLedger $ \lg ->
          withSystemTempDirectory "lockstep-p28" $ \tmp -> do
            (_, _, ops) <- readyOrder lg ["sandbox-idempotent:apply-then-hang"]
            o <- single ops
            handle <- spawn lg tmp "execute" ["supervisor", "execute-once", "--lease-seconds", "30", "--timeout-ms", "20000"]
            eventually "the effect was applied" ((== 1) <$> count lg ("lockstep_sandbox_applications WHERE operation_id = '" <> o <> "'"))
            _ <- kill handle
            sql lg ("UPDATE lockstep_effect_intents SET lease_until = now() - interval '1 second' WHERE operation_id = '" <> o <> "'")
            okCli lg ["supervisor", "execute-once"] >>= (@?= ["executed " <> o <> " applied applied"])
            okCli lg ["sandbox", "show"] >>= (@?= ["application " <> o <> " effect sandbox-idempotent count 1"])
            effectLine lg o >>= assertContains "status=PASSED"
    , testCase "refusals are visible: listed by the ledger, exit 65 or 64 at the command line" $
        withLedger $ \lg -> do
          (t, wo, ops) <- readyOrder lg ["sandbox-repeatable:hang"]
          (illegal, illegalOut, _) <- cli lg ["ticket", "accept", t, "--expected-revision", "2"]
          (illegal, illegalOut) @?= (ExitFailure 65, ["refused illegal-transition"])
          (stale, staleOut, _) <- cli lg ["ticket", "accept", t, "--expected-revision", "1"]
          (stale, staleOut) @?= (ExitFailure 65, ["refused stale-revision"])
          ledger <- okCli lg ["ledger", "show"]
          let
            refusals = L.filter ("refusal subject=" `L.isPrefixOf`) ledger
          L.length refusals @?= 2
          assertBool "illegal-transition listed" (L.any ("code=illegal-transition" `L.isInfixOf`) refusals)
          assertBool "stale-revision listed" (L.any ("code=stale-revision" `L.isInfixOf`) refusals)
          o <- single ops
          okCli lg ["supervisor", "execute-once", "--timeout-ms", "1500"] >>= (@?= ["executed " <> o <> " unknown timeout"])
          (staleGen, staleGenOut, _) <- cli lg ["effects", "resolve", o, "--generation", "0", "--attest-applied", "x"]
          (staleGen, staleGenOut) @?= (ExitFailure 65, ["refused stale-claim"])
          (unack, _, _) <- cli lg ["effects", "resolve", o, "--generation", "1", "--retry"]
          unack @?= ExitFailure 64
          (badId, _, _) <- cli lg ["ticket", "accept", "not-a-uuid", "--expected-revision", "1"]
          badId @?= ExitFailure 64
          orderLine lg wo >>= assertContains "state=halted"
          (_, wo2) <- claimedOrder lg
          (unknownEffect, unknownOut, _) <- cli lg ["supervisor", "start", wo2, "--expected-revision", "3", "--effect", "sandbox-bogus"]
          (unknownEffect, unknownOut) @?= (ExitFailure 65, ["refused unknown-sandbox-effect"])
    , testCase "the ledger page: refused without a session; with one, every status as text, refusals marked, no form" $
        withLedger $ \lg ->
          withSystemTempDirectory "lockstep-p28" $ \tmp -> do
            (_, _, ops) <- readyOrder lg ["sandbox-repeatable", "sandbox-unqueryable:hang"]
            okCli lg ["supervisor", "execute-once"] >>= (@?= ["executed " <> fst (opAt 0 ops) <> " applied applied"])
            okCli lg ["supervisor", "execute-once", "--timeout-ms", "1500"] >>= (@?= ["executed " <> fst (opAt 1 ops) <> " unknown timeout"])
            port <- freePort
            (_, _) <-
              withService (lgEnv lg) port (tmp <> "/serve.log") $ do
                without <- httpRequest port "GET" "/operator/ledger" [] ""
                center <- httpRequest port "GET" "/operator/center" [] ""
                responseStatus without @?= responseStatus center
                cookie <- signIn lg port
                page <- httpRequest port "GET" "/operator/ledger" [cookieHeader cookie] ""
                responseStatus page @?= 200
                let
                  html = TE.decodeUtf8 (responseBody page)
                traverse_
                  (\needle -> assertBool ("missing: " <> T.unpack needle) (needle `T.isInfixOf` html))
                  [ "class=\"ls-effect-passed\">PASSED<"
                  , "class=\"ls-effect-unknown\">UNKNOWN<"
                  , T.pack (fst (opAt 0 ops))
                  , T.pack (fst (opAt 1 ops))
                  ]
                T.count "PASSED" html @?= 1
                assertBool "a form on the ledger page" (not ("<form" `T.isInfixOf` html))
            pure ()
    ]

-- Commands -------------------------------------------------------------------

cli :: Ledger -> [String] -> IO (ExitCode, [String], String)
cli lg args = do
  (code, out, err) <- runLockstep (lgEnv lg) args
  pure (code, L.lines out, err)

okCli :: Ledger -> [String] -> IO [String]
okCli lg args = do
  (code, out, err) <- cli lg args
  assertBool ("lockstep " <> show args <> " exited " <> show code <> ": " <> L.unlines out <> err) (code == ExitSuccess)
  pure out

-- | The id after a fixed prefix in a one-line output.
idOf :: String -> [String] -> IO String
idOf prefix out =
  case out of
    [line] | Just rest <- L.stripPrefix (prefix <> " ") line -> pure rest
    other -> assertFailure ("expected `" <> prefix <> " <id>`: " <> show other)

{- | A new ready Ticket, its order with gate evidence, claimed by `schedule
run-once` and started with the effects: (ticket, order, [(operation, effect)]).
-}
readyOrder :: Ledger -> [String] -> IO (String, String, [(String, String)])
readyOrder lg effects = do
  (t, wo) <- claimedOrder lg
  started <- okCli lg (["supervisor", "start", wo, "--expected-revision", "3"] <> L.concatMap (\e -> ["--effect", e]) effects)
  case started of
    header : intents -> do
      header @?= "work-order " <> wo <> " revision 4 state active"
      ops <- traverse intentLine intents
      fmap snd ops @?= fmap (L.takeWhile (/= ':')) effects
      pure (t, wo, ops)
    [] -> assertFailure "no output from supervisor start"

-- | A new ready Ticket and its order with gate evidence, claimed by `schedule run-once` (revision 3).
claimedOrder :: Ledger -> IO (String, String)
claimedOrder lg = do
  t <- okCli lg ["ticket", "create", "Fix login"] >>= idOf "ticket"
  okCli lg ["ticket", "accept", t, "--expected-revision", "1"] >>= (@?= ["ticket " <> t <> " revision 2 state ready"])
  wo <- okCli lg ["work-order", "create", "--ticket", t, "--engineer", "alice", "--priority", "5", "--path-class", "source"] >>= idOf "work-order"
  okCli lg ["work-order", "evidence", wo, "--artifact", "impact-assessment", "--digest", L.replicate 64 'a', "--verifier", "human-inspection", "--approval", "supervisor"]
    >>= (@?= ["evidence " <> wo <> " impact-assessment"])
  schedule <- okCli lg ["schedule", "run-once"]
  assertBool ("not selected: " <> show schedule) (lastMay schedule == Just ("selected " <> wo <> " generation 1"))
  assertBool "a digest line" (L.any ("digest " `L.isPrefixOf`) schedule)
  pure (t, wo)

lastMay :: [a] -> Maybe a
lastMay =
  headMay . L.reverse

intentLine :: String -> IO (String, String)
intentLine line =
  case L.words line of
    ["intent", o, "effect", e] -> pure (o, e)
    _ -> assertFailure ("not an intent line: " <> line)

opAt :: Int -> [(String, String)] -> (String, String)
opAt n ops =
  case L.drop n ops of
    x : _ -> x
    [] -> ("missing", "missing")

single :: [(String, String)] -> IO String
single ops =
  case ops of
    [(o, _)] -> pure o
    other -> assertFailure ("one intent expected: " <> show other)

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    x : _ -> Just x
    [] -> Nothing

effectLine :: Ledger -> String -> IO String
effectLine lg o = do
  ledger <- okCli lg ["ledger", "show"]
  case L.filter (("  effect " <> o <> " ") `L.isPrefixOf`) ledger of
    [line] -> pure line
    other -> assertFailure ("no effect line for " <> o <> ": " <> show other)

orderLine :: Ledger -> String -> IO String
orderLine lg wo = do
  ledger <- okCli lg ["ledger", "show"]
  case L.filter (("work-order " <> wo <> " ") `L.isPrefixOf`) ledger of
    [line] -> pure line
    other -> assertFailure ("no order line for " <> wo <> ": " <> show other)

assertContains :: String -> String -> Assertion
assertContains needle haystack =
  assertBool ("`" <> needle <> "` not in: " <> haystack) (needle `L.isInfixOf` haystack)

-- Processes ------------------------------------------------------------------

-- | Starts the real binary in the background, its output to a log file.
spawn :: Ledger -> FilePath -> String -> [String] -> IO Process.ProcessHandle
spawn lg tmp name args = do
  base <- getEnvironment
  let
    env = lgEnv lg <> L.filter (\(k, _) -> k `L.notElem` fmap fst (lgEnv lg)) base
  logHandle <- openFile (tmp <> "/" <> name <> ".log") WriteMode
  (_, _, _, handle) <-
    Process.createProcess
      (Process.proc "lockstep" args)
        { Process.env = Just env
        , Process.std_out = Process.UseHandle logHandle
        , Process.std_err = Process.UseHandle logHandle
        }
  pure handle

-- | SIGKILL: the process gets no chance to clean up; returns its exit code.
kill :: Process.ProcessHandle -> IO ExitCode
kill handle = do
  pid <- Process.getPid handle
  maybe (assertFailure "the process had already exited") (signalProcess sigKILL) pid
  code <- timeout 10000000 (Process.waitForProcess handle)
  maybe (assertFailure "the killed process did not exit") pure code

-- | A GET that reports a refused connection or a timeout as Left.
tryGet :: Int -> String -> IO (Either () (Int, String))
tryGet port path = do
  result <- try (timeout 2000000 (httpGet port path)) :: IO (Either SomeException (Maybe (Int, String)))
  pure $
    case result of
      Right (Just r) -> Right r
      _ -> Left ()

-- | Polls every 100 ms for up to 20 s.
eventually :: String -> IO Bool -> Assertion
eventually what check =
  go (200 :: Int)
 where
  go n = do
    done <- check
    if done
      then pure ()
      else
        if n <= 0
          then assertFailure ("not within 20 s: " <> what)
          else threadDelay 100000 >> go (n - 1)

-- Sign-in --------------------------------------------------------------------

signIn :: Ledger -> Int -> IO BS.ByteString
signIn lg port = do
  (code, out, _) <- runLockstep (lgEnv lg) ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  token <-
    maybe (assertFailure "no token") pure $
      L.stripPrefix ("http://127.0.0.1:" <> show port <> "/operator/sign-in?token=") (L.filter (/= '\n') out)
  response <- httpRequest port "POST" "/operator/sign-in" [("Content-Type", "application/x-www-form-urlencoded"), ("Origin", "http://127.0.0.1:" <> BS8.pack (show port))] ("token=" <> BS8.pack token)
  responseStatus response @?= 303
  case responseHeaders "Set-Cookie" response of
    [value] | Just rest <- BS.stripPrefix "lockstep_session=" value -> pure (BS8.takeWhile (/= ';') rest)
    other -> assertFailure ("unexpected Set-Cookie: " <> show other)

cookieHeader :: BS.ByteString -> HTTP.Header
cookieHeader cookie =
  ("Cookie", "lockstep_session=" <> cookie)
