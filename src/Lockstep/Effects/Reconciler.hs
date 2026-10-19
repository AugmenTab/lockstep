{- | Destination lookups for queryable effects (contract C-P2.7 R1; DG-04
binding requirement 3). A reconciler declares the exact spec it serves and
asks the destination whether an operation id was applied. 'invokeLookup' runs
it once: only a valid answer is found or not found, and anything else is a
failed lookup, which proves nothing.
-}
module Lockstep.Effects.Reconciler
  ( LookupAnswer (..)
  , EffectReconciler (..)
  , invokeLookup
  ) where

import Control.Exception (SomeAsyncException, SomeException, evaluate, fromException, throwIO, try)
import Data.Char qualified as Char
import Data.Text qualified as T
import Flipstone.Prelude
import System.Timeout (timeout)
import Text.Show (Show)

import Lockstep.Kernel.Effect (EffectSpec, OperationId)
import Lockstep.Kernel.Reconciliation (LookupResult (..))

data LookupAnswer
  = LookupApplied T.Text
  | LookupAbsent
  deriving (Eq, Show)

data EffectReconciler
  = EffectReconciler
  { reconcilerSpec :: EffectSpec
  , reconcilerLookup :: OperationId -> T.Text -> IO LookupAnswer
  }

-- | R1: one lookup, bounded by the timeout in milliseconds.
invokeLookup :: Int -> EffectReconciler -> OperationId -> T.Text -> IO LookupResult
invokeLookup timeoutMs reconciler operation parameters = do
  result <- try (timeout (timeoutMs * 1000) (reconcilerLookup reconciler operation parameters >>= evaluate . validated))
  case result of
    Left e
      | isAsync e -> throwIO e
      | otherwise -> pure (LookupFailed (T.pack "lookup-failed"))
    Right Nothing -> pure (LookupFailed (T.pack "timeout"))
    Right (Just found) -> pure found

isAsync :: SomeException -> Bool
isAsync e =
  case fromException e :: Maybe SomeAsyncException of
    Just _ -> True
    Nothing -> False

validated :: LookupAnswer -> LookupResult
validated answer =
  case answer of
    LookupApplied text
      | not (T.null text) && T.length text <= 4096 && not (T.any Char.isControl text) -> LookupFound text
      | otherwise -> LookupFailed (T.pack "malformed-answer")
    LookupAbsent -> LookupNotFound
