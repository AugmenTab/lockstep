{- | Recording that accepted fixes stopped counting (contract C-P6.7 V2): when
the owner rejects a fix, every fix built on it; when the owner approves a plan
revision that changes units, their fixes and every fix built on those. Each
fix is recorded once, with its first cause; nothing is deleted or changed.
Callers run these inside their own database transaction.
-}
module Lockstep.Application.Invalidations
  ( invalidationOf
  , rejectedIn
  , planChangedIn
  ) where

import Data.List qualified as L
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O

import Lockstep.Application.Conversation (withdrawOpenIn)
import Lockstep.Kernel.Identity (PlanRevisionId, TransactionId)
import Lockstep.Kernel.Inbox (WithdrawalReason (..))
import Lockstep.Kernel.Invalidation (InvalidationCause (..), descendantsOf, invalidationCode)
import Lockstep.Persistence.Dispatch qualified as Store
import Lockstep.Persistence.Transactions qualified as Transactions

-- | The code of a fix's first invalidation, if it has one.
invalidationOf :: TransactionId -> O.Orville (Maybe T.Text)
invalidationOf tx =
  fmap Store.invalidationCodeOf . listToMaybe <$> Store.invalidationsOf tx

{- | Records one invalidation unless the fix already has one; whether it was
recorded. R-P6.7-1: under the fix's row lock, so it serializes with any step of
that fix, the person's Done among them.
-}
recordOnce :: Store.InvalidationRow -> O.Orville Bool
recordOnce row = do
  locked <- Transactions.lockTransaction (Store.invalidationTransaction row)
  existing <- invalidationOf (Store.invalidationTransaction row)
  case existing of
    Just _ -> pure False
    Nothing -> do
      Store.insertInvalidation row
      -- Update 2 R6.3: its open requests lose their authority in the same transaction; they stay as records.
      traverse_ (\tx -> withdrawOpenIn (Transactions.txRowWorkOrder tx) Nothing (WithdrawnInvalidated (Store.invalidationCodeOf row))) locked
      pure True

-- | Every fix built on this one, directly or not, as the recorded bases say.
descendants :: TransactionId -> O.Orville [TransactionId]
descendants tx = do
  bases <- Store.allFixBases
  pure (L.filter (/= tx) (descendantsOf [(Store.fixBaseTransaction b, Store.fixBaseAncestor b) | b <- bases] [tx]))

-- | V2 a, b: the owner rejected this fix; every fix built on it stops counting (@ancestor-rejected@).
rejectedIn :: TransactionId -> O.Orville ()
rejectedIn tx = do
  built <- descendants tx
  traverse_ (\d -> recordOnce (Store.InvalidationRow d (invalidationCode AncestorRejected) (Just tx) Nothing)) built

-- | V2 c: the owner approved this revision, which changed these fixes' units (@plan-changed@); then their descendants.
planChangedIn :: PlanRevisionId -> [TransactionId] -> O.Orville ()
planChangedIn revision =
  traverse_
    ( \tx -> do
        _ <- recordOnce (Store.InvalidationRow tx (invalidationCode PlanChanged) Nothing (Just revision))
        built <- descendants tx
        traverse_ (\d -> recordOnce (Store.InvalidationRow d (invalidationCode AncestorRejected) (Just tx) Nothing)) built
    )
