{-# LANGUAGE OverloadedStrings #-}

{- | Update 2 R6.5, truthful usage evidence, against real PostgreSQL, Git and
processes with scripted helpers that report usage as the Claude CLI does:
complete evidence gives an exact total; some runs without usage, a missing
class, or an output Lockstep kept only the tail of make it partial, never
complete; a project with no run has no provider invocation, and runs that
report zero tokens are complete zeros; an invalidated fix keeps its usage; the
summary names each run it counted, by its recorded invocation.
-}
module Lockstep.UsageEvidenceTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Conversation (Channel (..), Sender (..))
import Lockstep.Application.Engine (Engine (..), TransactionView (..), decideCompletion)
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Summary (ProjectSummary (..), projectSummary)
import Lockstep.Application.Tasks (TaskView (..))
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter (..), Workspace (..), directRunner, scriptedAdapter)
import Lockstep.Kernel.Plan (EdgeKind (..), PlanEdge (..), PlanMode (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Summary (Usage (..), UsageStanding (..))
import Lockstep.Support.Scheduling (Scenario (..), Scripts, accepted, acceptedCount, approveIn, count, fixOfTask, js, k, passesUntil, planOf, projectWith, ready, scriptsOf, tasksOf, valueFiles, valueScripts, valueTitle, valueUnit, withScenario)

tests :: TestTree
tests =
  testGroup
    "R6.5 truthful usage evidence (real Git, processes, PostgreSQL; scripted helpers)"
    [ testCase "every run reports every class: the usage is complete and exact, each run named by its invocation (R6.5)" complete
    , testCase "runs without usage, or without a cache-read count, make the usage partial; the missing count stays unknown (R6.5)" partial
    , testCase "an output kept only as its tail is never complete accounting (R6.5)" truncated
    , testCase "no run is no provider invocation; runs reporting zero tokens are complete zeros (R6.5)" noRunAndZero
    , testCase "an invalidated fix keeps its usage (R6.5)" invalidatedKeeps
    ]

-- Fixtures ---------------------------------------------------------------------------------------

prefix :: T.Text
prefix =
  "test-usage-evidence-"

usageLine :: Maybe Int -> T.Text
usageLine cacheRead =
  "{\"type\":\"result\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20,\"cache_creation_input_tokens\":5"
    <> maybe "" (\n -> ",\"cache_read_input_tokens\":" <> T.pack (show n)) cacheRead
    <> "}}\n"

zeroLine :: T.Text
zeroLine =
  "{\"type\":\"result\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}\n"

-- | What a run prints before its answer, by role and the run's index for that role (Nothing: no usage).
type Printed =
  Role -> Int -> Maybe T.Text

{- | An engine whose helpers answer with the value scripts, each printing first
what the table says.
-}
engineWith :: Scenario -> Printed -> IO Engine
engineWith sc printed = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    table = fmap valueScripts [1, 2, 3]
    steps :: Scripts -> Role -> Int -> Maybe T.Text
    steps s role n =
      withPrinted role n <$> L.lookup n (L.zip [0 ..] (scriptsOf s role))
    withPrinted role n step =
      maybe step (\out -> "{\"stdout\":" <> js out <> "}," <> step) (printed role n)
    adapter role n =
      Adapter
        { adapterName = "scripted-with-usage"
        , adapterPrepare = \workspace -> do
            context <- TE.decodeUtf8 <$> BS.readFile (workspaceInput workspace <> "/context.json")
            let
              chosen = L.find ((`T.isInfixOf` context) . fst) table >>= \(_, s) -> steps s role n
            adapterPrepare (scriptedAdapter "scripts/runner/scripted-role" (TE.encodeUtf8 ("{\"steps\":[" <> fromMaybe "" chosen <> "]}"))) workspace
        }
  pure (Engine runner (\role n -> Just (adapter role n)))

-- | A project with one approved plan of the value units, run until this many fixes are accepted.
ran :: Scenario -> T.Text -> [Int] -> [PlanEdge] -> Printed -> IO ProjectView
ran sc name units edges printed = do
  (view, _) <- projectWith sc prefix name (valueFiles 3) True
  _ <- approveIn sc prefix view name (planOf "Values" Brownfield (fmap valueUnit units) edges)
  engine <- engineWith sc printed
  passesUntil sc engine 120 ((== L.length units) <$> acceptedCount sc)
  pure view

summaryOf :: Scenario -> ProjectView -> IO ProjectSummary
summaryOf sc view =
  ready (projectSummary (scRuntime sc) (projectId view)) >>= maybe (assertFailure "no summary") pure

-- | Discovery, candidate, two challenges, the Implementer and the Reviewer: six role runs per fix.
runsPerFix :: Int
runsPerFix =
  6

-- Cases ------------------------------------------------------------------------------------------

complete :: Assertion
complete =
  withScenario $ \sc -> do
    view <- ran sc "complete" [1] [] (\_ _ -> Just (usageLine (Just 300)))
    s <- summaryOf sc view
    summaryUsageStanding s @?= UsageComplete (Usage (Just 600) (Just 120) (Just 30) (Just 1800))
    summaryUsage s @?= Usage (Just 600) (Just 120) (Just 30) (Just 1800)
    fmap snd (summaryUsageRuns s) @?= L.replicate runsPerFix "complete"
    -- Each source is a recorded invocation.
    traverse_ (\(i, _) -> count sc ("lockstep_invocations WHERE id = '" <> T.unpack i <> "'") >>= (@?= 1)) (summaryUsageRuns s)

partial :: Assertion
partial = do
  withScenario $ \sc -> do
    -- Only the discovery reports usage.
    one <- ran sc "one-reports" [1] [] (\role n -> if role == Planner && n == 0 then Just (usageLine (Just 300)) else Nothing)
    s1 <- summaryOf sc one
    summaryUsageStanding s1 @?= UsagePartial (Usage (Just 100) (Just 20) (Just 5) (Just 300))
    L.sort (fmap snd (summaryUsageRuns s1)) @?= L.sort ("complete" : L.replicate (runsPerFix - 1) "missing")
  withScenario $ \sc -> do
    -- Every run reports, none the cache reads.
    noCache <- ran sc "no-cache-read" [1] [] (\_ _ -> Just (usageLine Nothing))
    s2 <- summaryOf sc noCache
    summaryUsageStanding s2 @?= UsagePartial (Usage (Just 600) (Just 120) (Just 30) Nothing)
    usageCacheRead (summaryUsage s2) @?= Nothing

truncated :: Assertion
truncated =
  withScenario $ \sc -> do
    let
      noise = T.replicate 3000 "x" <> "\n"
      printed role n =
        Just (if role == Planner && n == 0 then noise <> usageLine (Just 300) else usageLine (Just 300))
    view <- ran sc "truncated" [1] [] printed
    s <- summaryOf sc view
    case summaryUsageStanding s of
      UsagePartial _ -> pure ()
      other -> assertFailure ("a truncated output gave " <> show other)
    L.sort (fmap snd (summaryUsageRuns s)) @?= L.sort ("truncated" : L.replicate (runsPerFix - 1) "complete")

noRunAndZero :: Assertion
noRunAndZero =
  withScenario $ \sc -> do
    (idle, _) <- projectWith sc prefix "idle" (valueFiles 1) False
    _ <- approveIn sc prefix idle "idle" (planOf "Values" Brownfield [valueUnit 1] [])
    s0 <- summaryOf sc idle
    summaryUsageStanding s0 @?= NoProviderInvocation
    summaryUsageRuns s0 @?= []
    zero <- ran sc "zero" [1] [] (\_ _ -> Just zeroLine)
    s1 <- summaryOf sc zero
    summaryUsageStanding s1 @?= UsageComplete (Usage (Just 0) (Just 0) (Just 0) (Just 0))

invalidatedKeeps :: Assertion
invalidatedKeeps =
  withScenario $ \sc -> do
    view <- ran sc "invalidated" [1, 2] [PlanEdge (k "f2") (k "f1") Technical] (\_ _ -> Just (usageLine (Just 300)))
    before <- summaryOf sc view
    ts <- tasksOf sc view
    t1 <- maybe (assertFailure "no f1") pure (L.find ((== valueTitle 1) . taskTitle) ts)
    f1 <- fixOfTask sc (taskId t1)
    void (accepted (ready (decideCompletion (scRuntime sc) (viewId f1) (SenderHuman ApplicationChannel) "not-done")))
    count sc "lockstep_fix_invalidations" >>= (@?= 1)
    after <- summaryOf sc view
    summaryUsageStanding after @?= summaryUsageStanding before
    L.length (summaryUsageRuns after) @?= 2 * runsPerFix
    assertBool "usage was lost" (summaryUsage after == summaryUsage before)
