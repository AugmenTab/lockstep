{-# LANGUAGE OverloadedStrings #-}

{- | The evidence-linked summary's rules (contract C-P6.8 E1–E6), pure, and
the reading of a helper's reported usage.
-}
module Lockstep.Kernel.SummaryTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Application.Summary (usageFromOutput)
import Lockstep.Kernel.Summary
  ( Category (..)
  , Checks (..)
  , Evidence (..)
  , FixSummary (..)
  , Intervention (..)
  , ItemFacts (..)
  , ReviewOutcome (..)
  , Usage (..)
  , addUsage
  , categoryCode
  , categoryOf
  , checksCode
  , evidenceCode
  , interventionCode
  , interventionOf
  , noUsage
  , reviewOutcomeCode
  , summaryStale
  , usageKnown
  )
import Lockstep.Kernel.Task (TaskReadiness (..))

fix :: T.Text -> Maybe T.Text -> FixSummary
fix state halt =
  FixSummary "tx" state halt False ChecksNotRun Nothing ReviewNotRun Nothing Nothing

item :: Maybe FixSummary -> ItemFacts
item =
  ItemFacts True ReadyToWork

tests :: TestTree
tests =
  testGroup
    "C-P6.8 the evidence-linked summary (pure)"
    [ testGroup
        "categories (E1)"
        [ testCase "each category has its code" $
            fmap categoryCode [minBound .. maxBound]
              @?= ["planned", "eligible", "active", "awaiting-person", "verified", "done", "invalidated", "uncertain", "stopped", "canceled", "waiting"]
        , testCase "a fix's state decides; a technically accepted fix is verified, not done" $ do
            categoryOf (item (Just (fix "running" Nothing))) @?= CategoryActive
            categoryOf (item (Just (fix "halted" (Just "review-needs-human")))) @?= CategoryAwaitingPerson
            categoryOf (item (Just (fix "accepted" Nothing))) @?= CategoryVerified
            categoryOf (item (Just (fix "done" Nothing))) @?= CategoryDone
            categoryOf (item (Just (fix "stopped" (Just "stopped by a person")))) @?= CategoryStopped
        , testCase "unknown effect is neither failure nor completion: an uncertain run is uncertain" $
            categoryOf (item (Just (fix "halted" (Just "uncertain-invocation role-uncertain")))) @?= CategoryUncertain
        , testCase "an accepted fix that stopped counting stays visible as invalidated" $ do
            categoryOf (item (Just (fix "accepted" Nothing) {fixInvalidated = True})) @?= CategoryInvalidated
            categoryOf (item (Just (fix "halted" (Just "ancestor-rejected")) {fixInvalidated = True})) @?= CategoryInvalidated
        , testCase "without a fix: eligible when ready, planned when a plan unit not yet ready, else its own" $ do
            categoryOf (ItemFacts True ReadyToWork Nothing) @?= CategoryEligible
            categoryOf (ItemFacts True (WaitingFor ["x"]) Nothing) @?= CategoryPlanned
            categoryOf (ItemFacts False (WaitingFor ["x"]) Nothing) @?= CategoryWaiting
            categoryOf (ItemFacts False TaskCanceled Nothing) @?= CategoryCanceled
            categoryOf (ItemFacts False Finished Nothing) @?= CategoryDone
        ]
    , testGroup
        "outcomes are never assumed (E2)"
        [ testCase "no-run is not success" $
            fmap checksCode [minBound .. maxBound] @?= ["passed", "failed", "not-run"]
        , testCase "an incomplete review is not approval" $
            fmap reviewOutcomeCode [minBound .. maxBound] @?= ["approved", "rejected", "needs-person", "not-run"]
        ]
    , testGroup
        "evidence (E3)"
        [ testCase "each kind of evidence has its code" $
            fmap evidenceCode [OfFix "t", OfRecord "t" 3, OfCommit "c", OfInvalidation "t", OfRequest "r"]
              @?= ["fix", "record", "commit", "invalidation", "request"]
        ]
    , testGroup
        "interventions (E4)"
        [ testCase "decisions only a person may take are necessary" $
            fmap (interventionCode . interventionOf) ["done", "not-done", "reproduction-missing", "review-needs-human", "ancestor-rejected", "supervisor-failed behaviour-in-documentation"]
              @?= ["necessary", "necessary", "necessary", "necessary", "necessary", "necessary"]
        , testCase "failures of the environment or a role are avoidable" $
            fmap interventionOf ["role-failed answer-invalid", "uncertain-invocation lost", "supervisor-failed git-failed", "repository-dirty", "verification-environment-missing"]
              @?= [AvoidableIntervention, AvoidableIntervention, AvoidableIntervention, AvoidableIntervention, AvoidableIntervention]
        , testCase "anything else is unclassified, never guessed" $
            interventionOf "something-new" @?= UnclassifiedIntervention
        ]
    , testGroup
        "usage as observed (E5)"
        [ testCase "a helper's result names every class" $
            usageFromOutput "{\"type\":\"result\",\"result\":\"ok\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"cache_creation_input_tokens\":3,\"cache_read_input_tokens\":2}}\n"
              @?= Usage (Just 10) (Just 5) (Just 3) (Just 2)
        , testCase "a class not reported is unknown, not zero" $
            usageFromOutput "{\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}" @?= Usage (Just 7) (Just 1) Nothing Nothing
        , testCase "the last result in the output counts; text that is not one is ignored" $
            usageFromOutput "starting\n{\"usage\":{\"input_tokens\":1}}\nmore text\n{\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}\n"
              @?= Usage (Just 4) (Just 2) Nothing Nothing
        , testCase "nothing reported is unknown usage" $ do
            usageFromOutput "" @?= noUsage
            usageFromOutput "not json" @?= noUsage
            usageFromOutput "{\"result\":\"no usage here\"}" @?= noUsage
            usageKnown noUsage @?= False
        , testCase "totals add only known counts, class by class" $
            addUsage (Usage (Just 1) Nothing (Just 2) Nothing) (Usage (Just 3) (Just 4) Nothing Nothing) @?= Usage (Just 4) (Just 4) (Just 2) Nothing
        ]
    , testGroup
        "freshness (E6)"
        [ testCase "a summary of another revision is stale" $ do
            summaryStale (Just "d1") (Just "d1") @?= False
            summaryStale (Just "d1") (Just "d2") @?= True
            summaryStale Nothing (Just "d1") @?= True
            summaryStale (Just "d1") Nothing @?= True
        ]
    ]
