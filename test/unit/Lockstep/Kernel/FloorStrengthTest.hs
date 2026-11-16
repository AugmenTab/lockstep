{-# LANGUAGE OverloadedStrings #-}

{- | Update 2 R6.4: a kind's floor is held by value. Each floor check is held
as required, or more strongly (every axis at least as strong, the same stage,
no exception path), or it is missing, weaker, or cannot be compared — and only
the first two hold it.
-}
module Lockstep.Kernel.FloorStrengthTest
  ( tests
  ) where

import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Lockstep.Kernel.Plan (WorkKind (..))
import Lockstep.Kernel.Profile (Gate, RawGate (..), RawProfile (..), definitionGates, mkProfileDefinition)
import Lockstep.Kernel.WorkPolicy (engineeringRaw, floorStandings, kindFloor, missingChecks)

-- | The gates of Lockstep's engineering checks with one change to the named one.
gatesWith :: T.Text -> (RawGate -> RawGate) -> IO [Gate]
gatesWith gate change =
  either (const (assertFailure "the variant does not read")) (pure . definitionGates) $
    mkProfileDefinition engineeringRaw {rawGates = [if rawGateId g == gate then change g else g | g <- rawGates engineeringRaw]}

tests :: TestTree
tests =
  testGroup
    "R6.4 a floor is held by value"
    [ testCase "the floor itself holds, as required" $ do
        gates <- gatesWith "none" id
        missingChecks Feature gates @?= []
        fmap snd (floorStandings Feature gates) @?= fmap (const "as-required") (kindFloor Feature)
    , testCase "a check stronger on every axis it changes holds, and says so" $ do
        gates <- gatesWith "feature-review" (\g -> g {rawGateApproval = "human", rawGateVerifiers = rawGateVerifiers g <> ["deterministic-command"]})
        missingChecks Feature gates @?= []
        lookup' "feature-review" (floorStandings Feature gates) @?= Just "stronger"
    , testCase "a weaker check does not hold" $ do
        gates <- gatesWith "feature-review" (\g -> g {rawGateApproval = "none"})
        missingChecks Feature gates @?= ["feature-review"]
        lookup' "feature-review" (floorStandings Feature gates) @?= Just "weaker"
    , testCase "an exception path on a floor check does not hold, whatever else is stronger" $ do
        gates <- gatesWith "feature-tests" (\g -> g {rawGateExceptionPath = True, rawGateApproval = "human"})
        missingChecks Feature gates @?= ["feature-tests"]
    , testCase "a check moved to another stage cannot be compared, so it does not hold" $ do
        gates <- gatesWith "feature-review" (\g -> g {rawGateStage = "before-completion"})
        missingChecks Feature gates @?= ["feature-review"]
        lookup' "feature-review" (floorStandings Feature gates) @?= Just "incomparable"
    , testCase "a check that is not there does not hold" $ do
        gates <- either (const (assertFailure "does not read")) (pure . definitionGates) (mkProfileDefinition engineeringRaw {rawGates = [g | g <- rawGates engineeringRaw, rawGateId g /= "feature-tests"]})
        missingChecks Feature gates @?= ["feature-tests"]
        lookup' "feature-tests" (floorStandings Feature gates) @?= Just "missing"
    ]
 where
  lookup' key pairs =
    snd <$> listToMaybe [p | p <- pairs, fst p == key]
