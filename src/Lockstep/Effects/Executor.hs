{- | Typed effect adapters and their invocation (contract C-P2.6 X1, X2;
DG-04 D-4.9, binding requirement 7). An adapter declares the exact effect spec
it implements; its effect-specific semantics (deduplication, lookup) live in
it and its destination, never in a generic retry wrapper. 'invokeAdapter'
runs it once and reports what happened as an 'Observation': only a valid
answer from the destination is applied or not applied, and a timeout, a
failure or a malformed answer is an unknown outcome.
-}
module Lockstep.Effects.Executor
  ( DestinationAnswer (..)
  , EffectAdapter (..)
  , invokeAdapter
  ) where

import Control.Exception (SomeAsyncException, SomeException, evaluate, fromException, throwIO, try)
import Data.Char qualified as Char
import Data.Text qualified as T
import Flipstone.Prelude
import System.Timeout (timeout)
import Text.Show (Show)

import Lockstep.Kernel.Effect (EffectSpec, Observation (..), OperationId)

data DestinationAnswer
  = AnswerApplied T.Text
  | AnswerNotApplied T.Text
  deriving (Eq, Show)

data EffectAdapter
  = EffectAdapter
  { adapterSpec :: EffectSpec
  , adapterRun :: OperationId -> T.Text -> IO DestinationAnswer
  }

{- | X2: one run, bounded by the timeout in milliseconds. A synchronous
exception is @adapter-failed@; an asynchronous one (the worker itself being
cancelled) propagates.
-}
invokeAdapter :: Int -> EffectAdapter -> OperationId -> T.Text -> IO Observation
invokeAdapter timeoutMs adapter operation parameters = do
  result <- try (timeout (timeoutMs * 1000) (adapterRun adapter operation parameters >>= evaluate . validated))
  case result of
    Left e
      | isAsync e -> throwIO e
      | otherwise -> pure (NoAnswer (T.pack "adapter-failed"))
    Right Nothing -> pure (NoAnswer (T.pack "timeout"))
    Right (Just observation) -> pure observation

isAsync :: SomeException -> Bool
isAsync e =
  case fromException e :: Maybe SomeAsyncException of
    Just _ -> True
    Nothing -> False

validated :: DestinationAnswer -> Observation
validated answer =
  case answer of
    AnswerApplied text | valid text -> DestinationApplied text
    AnswerNotApplied text | valid text -> DestinationNotApplied text
    _ -> NoAnswer (T.pack "malformed-answer")

valid :: T.Text -> Bool
valid text =
  not (T.null text) && T.length text <= 4096 && not (T.any Char.isControl text)
