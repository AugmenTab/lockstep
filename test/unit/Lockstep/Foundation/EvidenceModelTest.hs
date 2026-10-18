{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Foundation.EvidenceModelTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Foundation.EvidenceModel
  ( Disposition (..)
  , EvidenceItem (..)
  , RowInput (..)
  , TestedRevision (..)
  , aggregate
  , dispositionClass
  , dispositionLabel
  , effectiveDisposition
  )

tests :: TestTree
tests =
  testGroup
    "EvidenceModel"
    [ testGroup
        "rules"
        [ testCase "a complete, current, matching PASSED stays PASSED" $
            eff passedRow @?= Passed
        , testCase "PASSED without an actual observation is incomplete" $
            eff passedRow {rowActual = Nothing} @?= Inconclusive "incomplete evidence"
        , testCase "PASSED without evidence is incomplete" $
            eff passedRow {rowEvidence = []} @?= Inconclusive "incomplete evidence"
        , testCase "PASSED without a tested revision is incomplete" $
            eff passedRow {rowTestedRevision = Nothing} @?= Inconclusive "incomplete evidence"
        , testCase "PASSED from a dirty tree is incomplete" $
            eff passedRow {rowTestedRevision = Just (TestedRevision current True)} @?= Inconclusive "incomplete evidence"
        , testCase "an unavailable evidence locator makes PASSED inconclusive" $
            eff passedRow {rowEvidence = [item "db:gone/1" "aa"]} @?= Inconclusive "evidence unavailable"
        , testCase "a changed evidence digest makes PASSED inconclusive" $
            eff passedRow {rowEvidence = [item locator "bb"]} @?= Inconclusive "evidence changed"
        , testCase "a stale PASSED is inconclusive" $
            eff passedRow {rowTestedRevision = Just (TestedRevision "schema 3" False)} @?= Inconclusive "stale revision"
        , testCase "a stale FAILED stays FAILED" $
            eff passedRow {rowClaimed = Failed, rowTestedRevision = Just (TestedRevision "schema 3" False)} @?= Failed
        , testCase "non-PASSED claims keep their claim" $ do
            eff passedRow {rowClaimed = NotRun "queued"} @?= NotRun "queued"
            eff passedRow {rowClaimed = Blocked "decision"} @?= Blocked "decision"
            eff passedRow {rowClaimed = Inconclusive "flaky"} @?= Inconclusive "flaky"
            eff passedRow {rowClaimed = Failed, rowEvidence = []} @?= Failed
        ]
    , testCase "exhaustive: effective PASSED iff claim PASSED, actual, matching evidence, clean current revision" $
        traverse_ checkCombination combinations
    , testGroup
        "aggregate"
        [ testCase "worst required wins: FAILED > BLOCKED > INCONCLUSIVE > NOT_RUN > PASSED" $ do
            aggregate [(True, Passed), (True, NotRun "q"), (True, Inconclusive "x"), (True, Blocked "b"), (True, Failed)] @?= Failed
            aggregate [(True, Passed), (True, NotRun "q"), (True, Inconclusive "x"), (True, Blocked "b")] @?= Blocked "b"
            aggregate [(True, Passed), (True, NotRun "q"), (True, Inconclusive "x")] @?= Inconclusive "x"
            aggregate [(True, Passed), (True, NotRun "q")] @?= NotRun "q"
            aggregate [(True, Passed), (True, Passed)] @?= Passed
        , testCase "non-required rows do not count" $
            aggregate [(True, Passed), (False, Failed)] @?= Passed
        , testCase "no required rows is NOT_RUN, never a vacuous PASSED" $ do
            aggregate [] @?= NotRun "no required rows"
            aggregate [(False, Passed)] @?= NotRun "no required rows"
        ]
    , testGroup
        "labels"
        [ testCase "only PASSED has the PASSED label and class" $ do
            dispositionLabel Passed @?= "PASSED"
            dispositionClass Passed @?= "ls-passed"
            traverse_
              ( \d -> do
                  assertBool ("label " <> show d) (not ("PASSED" `T.isInfixOf` dispositionLabel d))
                  assertBool ("class " <> show d) (dispositionClass d /= "ls-passed")
              )
              nonPassed
        , testCase "labels carry the reason" $ do
            dispositionLabel Failed @?= "FAILED"
            dispositionLabel (Inconclusive "evidence changed") @?= "INCONCLUSIVE (evidence changed)"
            dispositionLabel (Blocked "decision") @?= "BLOCKED (decision)"
            dispositionLabel (NotRun "queued") @?= "NOT_RUN (queued)"
        , testCase "classes" $
            fmap dispositionClass nonPassed @?= ["ls-failed", "ls-inconclusive", "ls-blocked", "ls-not-run"]
        ]
    ]

current :: T.Text
current =
  "schema 5"

locator :: T.Text
locator =
  "db:lockstep_jobs/1"

item :: T.Text -> T.Text -> EvidenceItem
item loc digest =
  EvidenceItem loc digest "db-row" "lockstep serve"

resolve :: T.Text -> Maybe T.Text
resolve loc =
  if loc == locator then Just "aa" else Nothing

eff :: RowInput -> Disposition
eff =
  effectiveDisposition current resolve

passedRow :: RowInput
passedRow =
  RowInput
    { rowCriterion = "AC-JOB-1@v1"
    , rowStatement = "Job 1 completes all 2 steps"
    , rowSourceRefs = ["C-P1.5 E4"]
    , rowRequired = True
    , rowMethod = "background dispatcher"
    , rowExpected = "succeeded, 2/2 steps"
    , rowActual = Just "succeeded, 2/2 steps"
    , rowClaimed = Passed
    , rowEvidence = [item locator "aa"]
    , rowTestedRevision = Just (TestedRevision current False)
    }

nonPassed :: [Disposition]
nonPassed =
  [Failed, Inconclusive "x", Blocked "y", NotRun "z"]

data Evid = NoEvidence | Matching | Changed | Unavailable
  deriving (Eq, Show)

data Rev = NoRev | CleanCurrent | CleanStale | DirtyCurrent
  deriving (Eq, Show)

combinations :: [(Disposition, Bool, Evid, Rev)]
combinations =
  [ (claim, hasActual, evid, rev)
  | claim <- Passed : nonPassed
  , hasActual <- [True, False]
  , evid <- [NoEvidence, Matching, Changed, Unavailable]
  , rev <- [NoRev, CleanCurrent, CleanStale, DirtyCurrent]
  ]

checkCombination :: (Disposition, Bool, Evid, Rev) -> IO ()
checkCombination combination@(claim, hasActual, evid, rev) =
  let
    row =
      passedRow
        { rowClaimed = claim
        , rowActual = if hasActual then Just "observed" else Nothing
        , rowEvidence =
            case evid of
              NoEvidence -> []
              Matching -> [item locator "aa"]
              Changed -> [item locator "bb"]
              Unavailable -> [item "db:gone/1" "aa"]
        , rowTestedRevision =
            case rev of
              NoRev -> Nothing
              CleanCurrent -> Just (TestedRevision current False)
              CleanStale -> Just (TestedRevision "schema 1" False)
              DirtyCurrent -> Just (TestedRevision current True)
        }
    shouldPass = claim == Passed && hasActual && evid == Matching && rev == CleanCurrent
    result = eff row
  in
    do
      assertBool ("combination " <> show combination <> " gave " <> show result) ((result == Passed) == shouldPass)
      assertBool ("label for " <> show combination) (("PASSED" `T.isInfixOf` dispositionLabel result) == shouldPass)
      assertBool "a non-PASSED claim changed" (claim == Passed || result == claim)
      assertBool "combinations are distinct" (L.length combinations == 160)
