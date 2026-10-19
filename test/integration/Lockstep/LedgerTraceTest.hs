{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.8 integration: seeded executor scenarios with injected crashes and
real restarts on real PostgreSQL (V7). A restart is a new runtime over the
same database; the scripted destination stands for the external world and
outlives it. Each scenario then runs recovery and reconciliation passes until
nothing is left, and checks that no effect was duplicated, that nothing
uncertain is PASSED, and that the projection survives another restart.
-}
module Lockstep.LedgerTraceTest
  ( tests
  ) where

import Control.Exception (SomeException, throwIO, try)
import Data.Bits (shiftR, xor)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO.Error (userError)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Executor (Executor (..), ExecutorFaults (..), RunOutcome, executeIntent, executeOnce, noExecutorFaults)
import Lockstep.Application.Ledger
  ( LedgerFailure (..)
  , NewWorkOrder (..)
  , Receipt (..)
  , ScheduleReceipt (..)
  , createTicket
  , createWorkOrder
  , decideTicket
  , decideWorkOrder
  , loadIntent
  , noFaults
  , recordGateEvidence
  , scheduleOnce
  )
import Lockstep.Application.LedgerView (EffectLine (..), LedgerProjection (..), OrderLine (..), projectLedger, renderProjection)
import Lockstep.Application.Reconciler (Reconciliation (..), reconcileOnce)
import Lockstep.Effects.Executor (EffectAdapter)
import Lockstep.Effects.Reconciler (EffectReconciler)
import Lockstep.Effects.Scripted (Application (..), ScriptStep (..), ScriptedDestination, destinationApplications, newScriptedDestination, scriptedAdapter, scriptedReconciler)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectSpec
  , IdempotencyTerms (..)
  , Intent (..)
  , IntentRequest (..)
  , IntentState (..)
  , LookupTerms (..)
  , OperationId (..)
  , Settlement (..)
  , effectSpecName
  , mkEffectKey
  , mkEffectSpec
  )
import Lockstep.Kernel.EffectView (EffectStatus (..))
import Lockstep.Kernel.Identity (TicketId, WorkOrderId)
import Lockstep.Kernel.Profile (Approval (..), ArtifactKind (..), GateEvidence (..), VerifierKind (..), mkContentDigest)
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (WorkOrderInput (..), WorkOrderKind (..))
import Lockstep.Support.Ledger (Ledger (..), sql, withLedger)
import Lockstep.Support.Postgres (databaseConfigFor, withRuntime)

tests :: TestTree
tests =
  testGroup
    "Seeded database traces with crashes and restarts (C-P2.8; real PostgreSQL)"
    [ testCase "the scenario generator is deterministic and covers every class, script and crash point" $ do
        let
          again = L.take scenarioCount (L.unfoldr (Just . genScenario) (Gen seed))
        fmap show again @?= fmap show scenarios
        let
          plans = L.concatMap scenarioIntentPlans scenarios
        traverse_ (\c -> assertBool ("crash point never drawn: " <> show c) (c `L.elem` fmap planCrash plans)) [minBound .. maxBound]
        traverse_ (\s -> assertBool ("script never drawn: " <> show s) (s `L.elem` fmap planScript plans)) [minBound .. maxBound]
    , testGroup "scenarios" (L.zipWith scenarioCase [1 :: Int ..] scenarios)
    ]

seed :: Word64
seed =
  20261019

scenarioCount :: Int
scenarioCount =
  12

-- SplitMix64 -------------------------------------------------------------------

newtype Gen
  = Gen Word64

nextWord :: Gen -> (Word64, Gen)
nextWord (Gen s) =
  let
    s' = s + 0x9e3779b97f4a7c15
    z1 = (s' `xor` (s' `shiftR` 30)) * 0xbf58476d1ce4e5b9
    z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
  in
    (z2 `xor` (z2 `shiftR` 31), Gen s')

below :: Int -> Gen -> (Int, Gen)
below n g =
  let
    (w, g') = nextWord g
  in
    (fromIntegral (w `mod` fromIntegral (max 1 n)), g')

pickFrom :: (Enum a, Bounded a) => Gen -> (a, Gen)
pickFrom g =
  let
    choices = [minBound .. maxBound]
    (i, g') = below (L.length choices) g
  in
    ( case L.drop i choices of
        x : _ -> x
        [] -> minBound
    , g'
    )

-- Scenarios ------------------------------------------------------------------

data Crash = NoCrash | CrashAfterClaim | CrashAfterDispatch | CrashAfterEffect
  deriving (Eq, Show, Enum, Bounded)

data Script = ScriptApply | ScriptRefuse | ScriptHang | ScriptApplyThenHang
  deriving (Eq, Show, Enum, Bounded)

-- | One intent's plan: its spec index (0 repeatable, 1 idempotent, 2 queryable, 3 unqueryable), script and crash point.
data IntentPlan
  = IntentPlan
  { planSpec :: Int
  , planScript :: Script
  , planCrash :: Crash
  }
  deriving (Eq, Show)

newtype Scenario
  = Scenario
  { scenarioIntentPlans :: [IntentPlan]
  }
  deriving (Eq, Show)

genScenario :: Gen -> (Scenario, Gen)
genScenario g0 =
  let
    step (acc, g) n =
      let
        (script, g1) = pickFrom g
        (crash, g2) = pickFrom g1
      in
        (IntentPlan n script crash : acc, g2)
    (plans, g') = L.foldl' step ([], g0) [0, 1, 2, 3]
  in
    (Scenario (L.reverse plans), g')

scenarios :: [Scenario]
scenarios =
  L.take scenarioCount (L.unfoldr (Just . genScenario) (Gen seed))

specTable :: [(T.Text, ClassTerms, Int)]
specTable =
  [ ("alpha", TermsRepeatable, 1)
  , ("bravo", TermsIdempotent (IdempotencyTerms 86400 True), 1)
  , ("charlie", TermsQueryable (LookupTerms True True), 1)
  , ("delta", TermsUnqueryable, 0)
  ]

specOf :: Int -> IO EffectSpec
specOf n =
  case L.drop n specTable of
    (name, terms, budget) : _ -> either (assertFailure . show) pure (mkEffectSpec name terms budget)
    [] -> assertFailure "no such spec"

scriptSteps :: Script -> [ScriptStep]
scriptSteps s =
  case s of
    ScriptApply -> [StepApply "ok"]
    ScriptRefuse -> [StepRefuse "busy"]
    ScriptHang -> [StepHang]
    ScriptApplyThenHang -> [StepApplyThenHang "late"]

-- Running --------------------------------------------------------------------

scenarioCase :: Int -> Scenario -> TestTree
scenarioCase n scenario =
  testCase ("scenario " <> show n <> ": " <> L.intercalate ", " (fmap describe (scenarioIntentPlans scenario))) $
    withLedger $ \lg -> do
      dest <- newScriptedDestination
      adapters <- traverse (\p -> specOf (planSpec p) >>= \s -> scriptedAdapter s dest (scriptSteps (planScript p))) (scenarioIntentPlans scenario)
      charlie <- specOf 2
      reconciler <- scriptedReconciler charlie dest []
      let
        reconcilers = [reconciler]
      ops <- startOrder lg
      -- the first worker: one attempt per intent, each may crash at its point
      traverse_
        ( \(p, o) -> do
            _ <- try (executeIntent (lgRuntime lg) (worker "w1" adapters) (faultsFor (planCrash p)) o) :: IO (Either SomeException (Either LedgerFailure RunOutcome))
            pure ()
        )
        (L.zip (scenarioIntentPlans scenario) ops)
      -- a restart: a new runtime over the same database, then passes until nothing is left
      config <- databaseConfigFor (lgAdmin lg) (lgDb lg)
      withRuntime config $ \runtime -> do
        settle lg runtime adapters reconcilers (20 :: Int)
        checkInvariants lg runtime dest scenario ops
        before <- projected runtime
        withRuntime config $ \again -> do
          after <- projected again
          renderProjection after @?= renderProjection before
 where
  describe p = T.unpack (nameOf (planSpec p)) <> " " <> show (planScript p) <> " " <> show (planCrash p)
  nameOf i = case L.drop i specTable of (name, _, _) : _ -> name; [] -> "?"

worker :: T.Text -> [EffectAdapter] -> Executor
worker owner adapters =
  Executor {executorOwner = owner, executorLeaseSeconds = 60, executorTimeoutMs = 200, executorAdapters = adapters}

faultsFor :: Crash -> ExecutorFaults
faultsFor c =
  case c of
    NoCrash -> noExecutorFaults
    CrashAfterClaim -> noExecutorFaults {faultAfterClaim = crash}
    CrashAfterDispatch -> noExecutorFaults {faultAfterDispatch = crash}
    CrashAfterEffect -> noExecutorFaults {faultAfterEffect = crash}
 where
  crash = throwIO (userError "the worker died here")

-- | Ends every lease, then reconciles and executes until both find nothing.
settle :: Ledger -> DatabaseRuntime -> [EffectAdapter] -> [EffectReconciler] -> Int -> Assertion
settle lg runtime adapters reconcilers budget
  | budget <= 0 = assertFailure "the passes did not finish"
  | otherwise = do
      sql lg "UPDATE lockstep_effect_intents SET lease_until = now() - interval '1 second' WHERE state IN ('claimed', 'dispatched')"
      reconciled <- reconcileOnce runtime (Reconciliation 2000 reconcilers)
      executed <- executeOnce runtime (worker "w2" adapters) noExecutorFaults
      case (reconciled, executed) of
        (Right Nothing, Right Nothing) -> pure ()
        (Left f, _) -> assertFailure ("reconcile: " <> show f)
        (_, Left f) | ledgerCode f /= "claim-held" -> assertFailure ("execute: " <> show f)
        _ -> settle lg runtime adapters reconcilers (budget - 1)

ledgerCode :: LedgerFailure -> T.Text
ledgerCode f =
  case f of
    LedgerRefused code _ -> code
    LedgerIntegrity _ -> "integrity"
    LedgerUnavailable _ -> "unavailable"

checkInvariants :: Ledger -> DatabaseRuntime -> ScriptedDestination -> Scenario -> [OperationId] -> Assertion
checkInvariants _ runtime dest scenario ops = do
  applied <- destinationApplications dest
  traverse_
    ( \(p, o) -> do
        i <- either (assertFailure . show) pure =<< loadIntent runtime o
        let
          n = L.length (L.filter ((== o) . appliedOperation) applied)
        if planSpec p == 0
          then assertBool ("repeatable applied more often than dispatched: " <> show (n, intentDispatches i)) (n <= intentDispatches i)
          else assertBool ("applied " <> show n <> " times: " <> show p) (n <= 1)
        assertBool "an application without a dispatch marker" (n == 0 || intentDispatches i >= 1)
    )
    (L.zip (scenarioIntentPlans scenario) ops)
  projection <- projected runtime
  traverse_
    ( \line ->
        when (effectLineStatus line == StatusPassed) $
          case intentState (effectLineIntent line) of
            IntentSettled (SettledApplied _) -> pure ()
            other -> assertFailure ("PASSED for " <> show other)
    )
    (L.concatMap orderLineEffects (projectionOrders projection))

projected :: DatabaseRuntime -> IO LedgerProjection
projected runtime =
  projectLedger runtime >>= either (assertFailure . show) pure

-- | Alice's order for a new ready Ticket, claimed and started with one intent per spec, in spec order.
startOrder :: Ledger -> IO [OperationId]
startOrder lg = do
  t <- ok "ticket" (createTicket (lgRuntime lg) "Fix login")
  _ <- ok "accept" (decideTicket (lgRuntime lg) noFaults t 1 (Command Human TicketAccept))
  wo <- ok "order" (createWorkOrder (lgRuntime lg) (order t))
  evidence lg wo
  receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
  c <- case scheduleClaimed receipt of
    Just (claimed, c) | claimed == wo -> pure c
    other -> assertFailure ("not claimed: " <> show other)
  requests <-
    traverse
      ( \n -> do
          s <- specOf n
          k <- either (assertFailure . show) pure (mkEffectKey (effectSpecName s))
          pure (IntentRequest k s ("p=" <> effectSpecName s))
      )
      [0, 1, 2, 3]
  started <- ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Supervisor (WoStart c)) requests)
  pure (receiptOperations started)

ok :: String -> IO (Either LedgerFailure a) -> IO a
ok what action =
  action >>= either (\failure -> assertFailure (what <> ": " <> show failure)) pure

order :: TicketId -> NewWorkOrder
order t =
  NewWorkOrder
    { newTicket = t
    , newEngineer = "alice"
    , newKind = Engineering
    , newPriority = 5
    , newDependencies = []
    , newClasses = []
    , newPathClasses = ["source"]
    , newNonBehavioural = Nothing
    }

evidence :: Ledger -> WorkOrderId -> Assertion
evidence lg wo = do
  digest <- maybe (assertFailure "digest") pure (mkContentDigest (T.replicate 64 "a"))
  ok
    "evidence"
    ( recordGateEvidence
        (lgRuntime lg)
        Human
        wo
        GateEvidence
          { evidenceArtifact = ImpactAssessment
          , evidenceDigest = digest
          , evidenceVerifiedBy = [VerifyHumanInspection]
          , evidenceApproval = ApprovalSupervisor
          }
    )
