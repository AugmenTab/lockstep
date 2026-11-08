{- | Reconciliation of uncertain queryable effects (contract C-P2.7 R4; DG-04
D-4.5 class C, binding requirement 3). The effect's class is checked, its
reconciler chosen, and the Kernel's checks run with nothing written; the
lookup then runs outside any transaction, at most once;
its result is applied only if the intent has not moved on meanwhile, and that
raises the generation, fencing out every earlier worker.
-}
module Lockstep.Application.Reconciler
  ( Reconciliation (..)
  , ReconcileOutcome (..)
  , reconcileEffect
  , reconcileOnce
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Ledger
  ( LedgerFailure (..)
  , applyLookup
  , loadIntent
  , prepareLookup
  , reconcilableIntents
  )
import Lockstep.Effects.Reconciler (EffectReconciler (..), invokeLookup)
import Lockstep.Kernel.Effect (EffectClass (..), Intent (..), IntentState (..), OperationId, Settlement (..), effectSpecClass, effectSpecName)

data Reconciliation
  = Reconciliation
  { reconciliationTimeoutMs :: Int
  , reconciliationReconcilers :: [EffectReconciler]
  }

data ReconcileOutcome
  = ReconciledApplied T.Text
  | ReconciledNotApplied T.Text
  | ReconciledExhausted T.Text
  | StillUnknown T.Text
  deriving (Eq, Show)

refusal :: String -> String -> Either LedgerFailure a
refusal code message =
  Left (LedgerRefused (T.pack code) (T.pack message))

validReconciliation :: Reconciliation -> Bool
validReconciliation reconciliation =
  reconciliationTimeoutMs reconciliation >= 1
    && reconciliationTimeoutMs reconciliation <= 600000
    && L.length names == L.length (L.nub names)
 where
  names = fmap (effectSpecName . reconcilerSpec) (reconciliationReconcilers reconciliation)

reconcilerFor :: Reconciliation -> Intent -> Either LedgerFailure EffectReconciler
reconcilerFor reconciliation intent =
  case L.find ((== effectSpecName (intentSpec intent)) . effectSpecName . reconcilerSpec) (reconciliationReconcilers reconciliation) of
    Nothing -> refusal "no-reconciler" "no reconciler serves the effect"
    Just reconciler
      | reconcilerSpec reconciler /= intentSpec intent -> refusal "reconciler-mismatch" "the reconciler serves another spec than the intent declares"
      | otherwise -> Right reconciler

reconcileEffect :: DatabaseRuntime -> Reconciliation -> OperationId -> IO (Either LedgerFailure ReconcileOutcome)
reconcileEffect runtime reconciliation operation
  | not (validReconciliation reconciliation) = pure (refusal "invalid-record" "a reconciliation needs a timeout of 1-600000 ms and one reconciler per spec")
  | otherwise = do
      loaded <- loadIntent runtime operation
      case loaded >>= queryable >>= (\intent -> fmap ((,) intent) (reconcilerFor reconciliation intent)) of
        Left failure -> pure (Left failure)
        Right (intent, reconciler) -> do
          prepared <- prepareLookup runtime operation
          case prepared of
            Left failure -> pure (Left failure)
            Right generation -> do
              result <- invokeLookup (reconciliationTimeoutMs reconciliation) reconciler operation (intentParameters intent)
              applied <- applyLookup runtime operation generation result
              pure (applied >>= outcomeOf)

-- | Only a queryable effect has a lookup, so its class is checked before its reconciler is chosen.
queryable :: Intent -> Either LedgerFailure Intent
queryable intent =
  case effectSpecClass (intentSpec intent) of
    Queryable -> Right intent
    _ -> refusal "not-queryable" "only a queryable effect can be looked up at its destination"

outcomeOf :: Intent -> Either LedgerFailure ReconcileOutcome
outcomeOf intent =
  case intentState intent of
    IntentSettled (SettledApplied result) -> Right (ReconciledApplied result)
    IntentNotApplied reason -> Right (ReconciledNotApplied reason)
    IntentSettled (SettledNotApplied reason) -> Right (ReconciledExhausted reason)
    IntentUnknown reason -> Right (StillUnknown reason)
    _ -> Left (LedgerIntegrity (T.pack "a reconciliation left the intent in an unexpected state"))

-- | R4: the oldest reconcilable intent this reconciliation serves, or nothing.
reconcileOnce :: DatabaseRuntime -> Reconciliation -> IO (Either LedgerFailure (Maybe (OperationId, ReconcileOutcome)))
reconcileOnce runtime reconciliation
  | not (validReconciliation reconciliation) = pure (refusal "invalid-record" "a reconciliation needs a timeout of 1-600000 ms and one reconciler per spec")
  | otherwise = do
      listed <- reconcilableIntents runtime
      case listed of
        Left failure -> pure (Left failure)
        Right operations -> do
          found <- findM served operations
          case found of
            Nothing -> pure (Right Nothing)
            Just operation -> fmap (fmap (Just . (,) operation)) (reconcileEffect runtime reconciliation operation)
 where
  names = fmap (effectSpecName . reconcilerSpec) (reconciliationReconcilers reconciliation)
  served operation =
    either (const False) (\intent -> effectSpecName (intentSpec intent) `L.elem` names) <$> loadIntent runtime operation

findM :: (a -> IO Bool) -> [a] -> IO (Maybe a)
findM predicate xs =
  case xs of
    [] -> pure Nothing
    x : rest -> do
      yes <- predicate x
      if yes then pure (Just x) else findM predicate rest
