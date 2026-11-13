{-# LANGUAGE OverloadedStrings #-}

{- | Stabilization S1: a role that exits non-zero because the provider refused
its sign-in is named @provider-auth-rejected@, not an opaque crash. The
fixture is the CLI result the Brigid run recorded (its Planner's first run,
@docs/gates/VM-1/evidence/p5.12-brigid/role-results-tail.txt@).
-}
module Lockstep.Effects.RoleCrashTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Effects.Process (RunResult (..))
import Lockstep.Effects.Roles
  ( RoleOutcome (..)
  , Runner (..)
  , View (..)
  , Workspace (..)
  , crashCode
  , providerAuthRejected
  , runPrepared
  )
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Runner (RunOutcome (..))

tests :: TestTree
tests =
  testGroup
    "S1 a provider's refusal of the sign-in is named, not a crash"
    [ testCase "the CLI's 401 result (an expired access token) is provider-auth-rejected" $ do
        providerAuthRejected brigid401 @?= True
        crashCode (exited 1 brigid401) @?= "provider-auth-rejected"
    , testCase "any other failure is still role-crashed" $ do
        fmap (crashCode . exited 1) [rateLimited, notAnError, noStatus, "not json", "", "{\"is_error\":true,\"api_error_status\":\"401\"}"]
          @?= L.replicate 6 "role-crashed"
    , testCase "the role's run ends RoleFailed provider-auth-rejected, never an answer" $ do
        outcome <- runWith (exited 1 brigid401)
        outcome @?= RoleFailed "provider-auth-rejected" (Just (exited 1 brigid401))
    , testCase "an ordinary crash is unchanged" $ do
        outcome <- runWith (exited 3 "")
        outcome @?= RoleFailed "role-crashed" (Just (exited 3 ""))
    ]

brigid401 :: BS.ByteString
brigid401 =
  TE.encodeUtf8 $
    T.concat
      [ "{\"duration_api_ms\":0,\"stop_reason\":\"stop_sequence\",\"session_id\":\"71a6485a-f2c3-9fac-40fa-50cbffc61415\",\"total_cost_usd\":0,"
      , "\"usage\":{\"input_tokens\":0,\"output_tokens\":0},\"modelUsage\":{},\"permission_denials\":[],\"terminal_reason\":\"api_error\","
      , "\"is_error\":true,\"num_turns\":1,\"subtype\":\"success\",\"api_error_status\":401,\"api_error_origin\":\"first_party\","
      , "\"result\":\"Failed to authenticate. API Error: 401 OAuth access token has expired. Re-authenticate to continue.\",\"type\":\"result\"}\n"
      ]

rateLimited :: BS.ByteString
rateLimited =
  "{\"is_error\":true,\"api_error_status\":429,\"result\":\"rate limited\",\"type\":\"result\"}"

notAnError :: BS.ByteString
notAnError =
  "{\"is_error\":false,\"api_error_status\":401,\"type\":\"result\"}"

noStatus :: BS.ByteString
noStatus =
  "{\"is_error\":true,\"result\":\"something else\",\"type\":\"result\"}"

exited :: Int -> BS.ByteString -> RunResult
exited n out =
  RunResult
    { resultOutcome = Exited n
    , resultStdout = out
    , resultStderr = ""
    , resultStdoutBytes = BS.length out
    , resultStderrBytes = 0
    , resultMillis = 10
    , resultDescendantsKilled = False
    }

-- | A runner that returns the given result once, for a Planner in a workspace that is never read.
runWith :: RunResult -> IO RoleOutcome
runWith result =
  let
    workspace = Workspace "/nonexistent/tree" "/nonexistent/input" "/nonexistent/output" (View "/work/tree" "/input" "/output") "w"
    runner =
      Runner
        { runnerName = "fake"
        , runnerPrepare = pure (Right workspace)
        , runnerRun = \_ _ _ _ _ -> pure (Right result)
        , runnerRelease = \_ -> pure ()
        }
  in
    runPrepared runner Planner workspace ["claude"] []
