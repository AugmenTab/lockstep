{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Application.NoopCommandTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Command
  ( Actor (..)
  , CommandEnvelope
  , Decision (..)
  , InvalidReason (..)
  , NoopSpec (..)
  , OperatorCommand (..)
  , Revision (..)
  , WorkspaceState (..)
  , decide
  , mkEnvelope
  , mkIdempotencyKey
  , mkNoopSpec
  , mkWorkspaceName
  , payloadDigest
  )

tests :: TestTree
tests =
  testGroup
    "Queue no-op command"
    [ testGroup
        "spec bounds"
        [ testCase "1 and 20 steps are accepted; 0 and 21 are StepsOutOfRange" $ do
            specError 1 0 Nothing @?= Nothing
            specError 20 0 Nothing @?= Nothing
            specError 0 0 Nothing @?= Just StepsOutOfRange
            specError 21 0 Nothing @?= Just StepsOutOfRange
        , testCase "0 and 5000 ms are accepted; -1 and 5001 are StepMillisOutOfRange" $ do
            specError 3 5000 Nothing @?= Nothing
            specError 3 (-1) Nothing @?= Just StepMillisOutOfRange
            specError 3 5001 Nothing @?= Just StepMillisOutOfRange
        , testCase "a failure step must be within 1..steps" $ do
            specError 3 0 (Just 1) @?= Nothing
            specError 3 0 (Just 3) @?= Nothing
            specError 3 0 (Just 0) @?= Just FailAtOutOfRange
            specError 3 0 (Just 4) @?= Just FailAtOutOfRange
        , testCase "the spec keeps its fields" $
            fmap (\s -> (noopSteps s, noopStepMillis s, noopFailAtStep s)) (mkNoopSpec 4 250 (Just 2)) @?= Right (4, 250, Just 2)
        ]
    , testGroup
        "digest"
        [ testCase "differs by each spec field and from a rename" $ do
            base <- queue 0 3 100 Nothing
            moreSteps <- queue 0 4 100 Nothing
            slower <- queue 0 3 200 Nothing
            failing <- queue 0 3 100 (Just 2)
            otherRevision <- queue 1 3 100 Nothing
            rename <- renameEnvelope 0
            let
              digests = fmap payloadDigest [base, moreSteps, slower, failing, otherRevision, rename]
            assertBool ("digests collide: " <> show digests) (distinct digests)
        , testCase "is equal for equal specs" $ do
            a <- queue 0 3 100 (Just 2)
            b <- queue 0 3 100 (Just 2)
            payloadDigest a @?= payloadDigest b
        ]
    , testGroup
        "decide"
        [ testCase "queueing at the current revision applies without changing the revision" $ do
            e <- queue 3 3 100 Nothing
            decide (WorkspaceState "Lockstep" (Revision 3)) Nothing e @?= Apply (Revision 3)
        , testCase "queueing at another revision is refused as stale" $ do
            e <- queue 2 3 100 Nothing
            decide (WorkspaceState "Lockstep" (Revision 3)) Nothing e @?= RefuseStale (Revision 3)
        ]
    ]

specError :: Int -> Int -> Maybe Int -> Maybe InvalidReason
specError steps millis failAt =
  either Just (const Nothing) (mkNoopSpec steps millis failAt)

queue :: Int64 -> Int -> Int -> Maybe Int -> IO CommandEnvelope
queue expected steps millis failAt = do
  key <- either (assertFailure . show) pure (mkIdempotencyKey "queue-key-aaaaaaaaaaa")
  spec <- either (assertFailure . show) pure (mkNoopSpec steps millis failAt)
  pure (mkEnvelope ActorCli key (Revision expected) (QueueNoop spec))

renameEnvelope :: Int64 -> IO CommandEnvelope
renameEnvelope expected = do
  key <- either (assertFailure . show) pure (mkIdempotencyKey "queue-key-aaaaaaaaaaa")
  name <- either (assertFailure . show) pure (mkWorkspaceName (T.pack "steps=3;step_ms=100;fail_at=none"))
  pure (mkEnvelope ActorCli key (Revision expected) (RenameWorkspace name))

distinct :: Eq a => [a] -> Bool
distinct xs =
  case xs of
    [] -> True
    x : rest -> x `L.notElem` rest && distinct rest
