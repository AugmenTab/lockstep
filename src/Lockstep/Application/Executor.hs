{- | The effect executor and one dispatcher pass (contract C-P2.6 X4, X5, X8,
X10, X11; DG-04 D-4.5, D-4.9). Each step is its own transaction, so what is
committed when a worker dies is exactly what a restarted worker finds: a
claim without a dispatch marker may be reclaimed once its lease ends; a
dispatch marker may only be recovered, by the effect's class. The adapter
runs only after the marker commits, once per call; there is no retry loop.
-}
module Lockstep.Application.Executor
  ( Executor (..)
  , ExecutorFaults (..)
  , noExecutorFaults
  , RunOutcome (..)
  , executeIntent
  , recoverAndExecute
  , executeOnce
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Ledger
  ( LedgerFailure (..)
  , beginDispatchLeased
  , claimForExecution
  , concludeIntent
  , loadIntent
  , recoverDispatched
  , recoverableIntents
  , runnableIntents
  )
import Lockstep.Effects.Executor (EffectAdapter (..), invokeAdapter)
import Lockstep.Kernel.Effect (EffectClass (..), Intent (..), IntentState (..), OperationId, Settlement (..), effectSpecClass, effectSpecName)

data Executor
  = Executor
  { executorOwner :: T.Text
  , executorLeaseSeconds :: Int
  , executorTimeoutMs :: Int
  , executorAdapters :: [EffectAdapter]
  }

-- | Test-only fault hooks (X11); nothing in the binary uses them.
data ExecutorFaults
  = ExecutorFaults
  { faultAfterClaim :: IO ()
  , faultAfterDispatch :: IO ()
  , faultAfterEffect :: IO ()
  }

noExecutorFaults :: ExecutorFaults
noExecutorFaults =
  ExecutorFaults (pure ()) (pure ()) (pure ())

data RunOutcome
  = RanApplied T.Text
  | RanNotApplied T.Text
  | RanExhausted T.Text
  | RanUnknown T.Text
  deriving (Eq, Show)

refusal :: String -> String -> Either LedgerFailure a
refusal code message =
  Left (LedgerRefused (T.pack code) (T.pack message))

-- | X4.
validExecutor :: Executor -> Bool
validExecutor executor =
  not (T.null owner)
    && not (T.any Char.isControl owner)
    && lease >= 1
    && lease <= 3600
    && executorTimeoutMs executor >= 1
    && executorTimeoutMs executor < lease * 1000
    && L.length names == L.length (L.nub names)
 where
  owner = executorOwner executor
  lease = executorLeaseSeconds executor
  names = fmap (effectSpecName . adapterSpec) (executorAdapters executor)

-- | X5 step (1): the executor's adapter for the intent's exact spec.
adapterFor :: Executor -> Intent -> Either LedgerFailure EffectAdapter
adapterFor executor intent =
  case L.find ((== effectSpecName (intentSpec intent)) . effectSpecName . adapterSpec) (executorAdapters executor) of
    Nothing -> refusal "no-adapter" "this executor has no adapter for the effect"
    Just adapter
      | adapterSpec adapter /= intentSpec intent -> refusal "adapter-mismatch" "the adapter implements another spec than the intent declares"
      | otherwise -> Right adapter

-- | Loads the intent and finds its adapter, after the configuration check.
prepared :: DatabaseRuntime -> Executor -> OperationId -> IO (Either LedgerFailure EffectAdapter)
prepared runtime executor operation
  | not (validExecutor executor) = pure (refusal "invalid-record" "an executor needs an owner, a lease of 1-3600 s, a timeout below the lease, and one adapter per spec")
  | otherwise = fmap (>>= adapterFor executor) (loadIntent runtime operation)

executeIntent :: DatabaseRuntime -> Executor -> ExecutorFaults -> OperationId -> IO (Either LedgerFailure RunOutcome)
executeIntent runtime executor faults operation = do
  ready <- prepared runtime executor operation
  case ready of
    Left failure -> pure (Left failure)
    Right adapter -> do
      claimed <- claimForExecution runtime (executorOwner executor) (executorLeaseSeconds executor) operation
      case claimed of
        Left failure -> pure (Left failure)
        Right intent -> do
          faultAfterClaim faults
          runClaimed runtime executor faults adapter operation (intentGeneration intent)

-- | X8: recovers a dispatched intent; a redispatch continues at X5 step (3).
recoverAndExecute :: DatabaseRuntime -> Executor -> ExecutorFaults -> OperationId -> IO (Either LedgerFailure RunOutcome)
recoverAndExecute runtime executor faults operation = do
  ready <- prepared runtime executor operation
  case ready of
    Left failure -> pure (Left failure)
    Right adapter -> do
      recovered <- recoverDispatched runtime (executorOwner executor) (executorLeaseSeconds executor) operation
      case recovered of
        Left failure -> pure (Left failure)
        Right intent ->
          case intentState intent of
            IntentClaimed _ -> do
              faultAfterClaim faults
              runClaimed runtime executor faults adapter operation (intentGeneration intent)
            IntentUnknown reason -> pure (Right (RanUnknown reason))
            _ -> pure (Left (LedgerIntegrity (T.pack "a recovery left the intent neither claimed nor unknown")))

-- | X5 steps (3) to (5) under the claimed generation.
runClaimed :: DatabaseRuntime -> Executor -> ExecutorFaults -> EffectAdapter -> OperationId -> Int -> IO (Either LedgerFailure RunOutcome)
runClaimed runtime executor faults adapter operation generation = do
  dispatched <- beginDispatchLeased runtime operation generation (executorLeaseSeconds executor)
  case dispatched of
    Left failure -> pure (Left failure)
    Right intent -> do
      faultAfterDispatch faults
      observation <- invokeAdapter (executorTimeoutMs executor) adapter operation (intentParameters intent)
      faultAfterEffect faults
      concluded <- concludeIntent runtime operation generation observation
      pure (concluded >>= outcomeOf)

outcomeOf :: Intent -> Either LedgerFailure RunOutcome
outcomeOf intent =
  case intentState intent of
    IntentSettled (SettledApplied result) -> Right (RanApplied result)
    IntentNotApplied reason -> Right (RanNotApplied reason)
    IntentSettled (SettledNotApplied reason) -> Right (RanExhausted reason)
    IntentUnknown reason -> Right (RanUnknown reason)
    _ -> Left (LedgerIntegrity (T.pack "a conclusion left the intent in an unexpected state"))

{- | X10: one dispatcher pass. The oldest recoverable intent this executor
has an adapter for is recovered first; else the oldest runnable one is
executed; else nothing happens.
-}
executeOnce :: DatabaseRuntime -> Executor -> ExecutorFaults -> IO (Either LedgerFailure (Maybe (OperationId, RunOutcome)))
executeOnce runtime executor faults
  | not (validExecutor executor) = pure (refusal "invalid-record" "an executor needs an owner, a lease of 1-3600 s, a timeout below the lease, and one adapter per spec")
  | otherwise = do
      recoverable <- recoverableIntents runtime >>= traverse (findM recoverableHere)
      case recoverable of
        Left failure -> pure (Left failure)
        Right (Just operation) -> fmap (fmap (Just . (,) operation)) (recoverAndExecute runtime executor faults operation)
        Right Nothing -> do
          runnable <- runnableIntents runtime >>= firstHandled
          case runnable of
            Left failure -> pure (Left failure)
            Right (Just operation) -> fmap (fmap (Just . (,) operation)) (executeIntent runtime executor faults operation)
            Right Nothing -> pure (Right Nothing)
 where
  names = fmap (effectSpecName . adapterSpec) (executorAdapters executor)
  handled operation =
    either (const False) (\intent -> effectSpecName (intentSpec intent) `L.elem` names) <$> loadIntent runtime operation
  firstHandled = traverse (findM handled)
  -- C-P2.9-R1 M6: a queryable effect is left to reconciliation, which may prove its outcome.
  recoverableHere operation =
    either (const False) (\intent -> effectSpecName (intentSpec intent) `L.elem` names && effectSpecClass (intentSpec intent) /= Queryable) <$> loadIntent runtime operation

findM :: (a -> IO Bool) -> [a] -> IO (Maybe a)
findM predicate xs =
  case xs of
    [] -> pure Nothing
    x : rest -> do
      yes <- predicate x
      if yes then pure (Just x) else findM predicate rest
