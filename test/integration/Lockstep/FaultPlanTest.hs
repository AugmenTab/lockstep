module Lockstep.FaultPlanTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Data.List qualified as L
import Flipstone.Prelude
import Network.HTTP.Client qualified as HTTPClient
import System.Exit (ExitCode (ExitFailure))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Process (freePort, httpGet, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "fault plans are refused by this build"
    [ testCase "serve with a fault plan exits 78 and never listens" $ do
        port <- freePort
        (code, out, err) <- runLockstep [faultPlan] ["serve", "--port", show port]
        code @?= ExitFailure 78
        out @?= ""
        err @?= expectedMessage
        threadDelay 300000
        listening <- try (httpGet port "/api/health_check")
        case listening of
          Left (_ :: HTTPClient.HttpException) -> pure ()
          Right reply -> assertBool ("something answered on the port: " <> show reply) False
    , testCase "every command refuses a fault plan before reading arguments or configuration" $
        traverse_
          refuses
          [ ["db", "status"]
          , ["workspace", "show"]
          , ["operator", "sign-in"]
          , ["no-such-command", "--bogus"]
          , []
          ]
    , testCase "a fault plan is refused even when LOCKSTEP_CONFIG names a missing file" $ do
        (code, out, err) <- runLockstep [faultPlan, ("LOCKSTEP_CONFIG", "/nonexistent/lockstep.json")] ["db", "status"]
        code @?= ExitFailure 78
        out @?= ""
        err @?= expectedMessage
    , testCase "without a fault plan, serve answers health as before" $
        withSystemTempDirectory "lockstep-faultplan" $ \dir -> do
          port <- freePort
          (reply, _) <- withService [] port (dir <> "/serve.log") (httpGet port "/api/health_check")
          fst reply @?= 204
    ]

faultPlan :: (String, String)
faultPlan =
  ("LOCKSTEP_FAULT_PLAN", "FP-CMD-AFTER-ADMIT")

expectedMessage :: String
expectedMessage =
  "lockstep: fault plans are not accepted by this build (no fault-injection flag)\n"

refuses :: [String] -> Assertion
refuses args = do
  (code, out, err) <- runLockstep [faultPlan] args
  assertBool ("exit for " <> show args <> ": " <> show code) (code == ExitFailure 78)
  assertBool ("stdout for " <> show args) (L.null out)
  err @?= expectedMessage
