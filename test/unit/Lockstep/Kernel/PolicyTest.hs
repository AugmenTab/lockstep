{-# LANGUAGE OverloadedStrings #-}

{- | The plain words for checks and for what can start (contract C-P3.7 L1, L2,
L5), and the built-in starting choice.
-}
module Lockstep.Kernel.PolicyTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.ProfileDocument (decodeProfileDocument)
import Lockstep.Application.ProjectChecks (basicChecksDocument, basicChecksId)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.Policy
  ( CheckRow (..)
  , Loss (..)
  , approvalWords
  , artifactWords
  , checkRow
  , checksLost
  , checksRefusalWords
  , ineligibilityWords
  , invariantWords
  , kindWords
  , lossWords
  , pathWords
  , stageWords
  , verifierWords
  )
import Lockstep.Kernel.Profile
  ( Approval (..)
  , ArtifactKind (..)
  , GateBlock (..)
  , GateId
  , ProfileDefinition
  , ProfileId
  , RawGate (..)
  , RawProfile (..)
  , definitionGates
  , definitionId
  , definitionVersion
  , mkGateId
  , mkProfileDefinition
  , mkProfileId
  , profileIdText
  )
import Lockstep.Kernel.Scheduler (Ineligibility (..), mkResourceName)
import Lockstep.Kernel.WorkOrder (WorkOrderKind)

-- | Words a person should never need to read on the ordinary path.
internalWords :: [T.Text]
internalWords =
  ["profile", "gate", "invariant", "work order", "ticket", "engineer", "scheduler", "digest"]

plain :: T.Text -> Assertion
plain text = do
  assertBool "empty words" (not (T.null (T.strip text)))
  traverse_
    (\word -> assertBool (T.unpack ("internal word " <> word <> " in: " <> text)) (not (word `T.isInfixOf` T.toLower text)))
    internalWords

impactGate :: RawGate
impactGate =
  RawGate
    { rawGateId = "impact"
    , rawGateStage = "before-execution"
    , rawGateArtifacts = ["impact-assessment"]
    , rawGateKinds = Just ["engineering"]
    , rawGateClasses = Just ["bug-fix"]
    , rawGatePathClasses = Just ["source"]
    , rawGateVerifiers = ["human-inspection"]
    , rawGateApproval = "human"
    , rawGateExceptionPath = False
    }

reviewGate :: RawGate
reviewGate =
  RawGate
    { rawGateId = "review"
    , rawGateStage = "before-acceptance"
    , rawGateArtifacts = ["review-record", "verification-record"]
    , rawGateKinds = Nothing
    , rawGateClasses = Nothing
    , rawGatePathClasses = Nothing
    , rawGateVerifiers = ["independent-review", "deterministic-command"]
    , rawGateApproval = "supervisor"
    , rawGateExceptionPath = True
    }

definition :: Maybe Bool -> [RawGate] -> IO ProfileDefinition
definition allows gates =
  either
    (\r -> assertFailure ("invalid test profile: " <> show r))
    pure
    (mkProfileDefinition (RawProfile "team" 1 allows [] gates []))

gid :: T.Text -> IO GateId
gid text =
  maybe (assertFailure "gate id") pure (mkGateId text)

pid :: T.Text -> IO ProfileId
pid text =
  maybe (assertFailure "profile id") pure (mkProfileId text)

order :: WorkOrderId
order =
  WorkOrderId (uuidFromWords 7 7)

tests :: TestTree
tests =
  testGroup
    "C-P3.7 plain words for checks and for what can start"
    [ testCase "each of the nine always-on rules has its own plain sentence" $ do
        let
          sentences = fmap invariantWords [minBound .. maxBound]
        L.length sentences @?= 9
        traverse_ plain sentences
        L.length (L.nub sentences) @?= 9
        invariantWords minBound @?= "Only one worker changes a piece of work at a time."
    , testCase "every stage, artifact, verifier, approval, kind and path class has plain words" $ do
        traverse_ (plain . stageWords) [minBound .. maxBound]
        traverse_ (plain . artifactWords) [minBound .. maxBound]
        traverse_ (plain . verifierWords) [minBound .. maxBound]
        traverse_ (plain . approvalWords) [minBound .. maxBound]
        traverse_ (plain . kindWords) ([minBound .. maxBound] :: [WorkOrderKind])
        traverse_ (plain . pathWords) [minBound .. maxBound]
        L.length (L.nub (fmap artifactWords [minBound .. maxBound])) @?= 13
    , testCase "a check is a checklist row in plain words" $ do
        d <- definition Nothing [impactGate, reviewGate]
        fmap checkRow (definitionGates d)
          @?= [ CheckRow
                  { rowCheck = "impact"
                  , rowWhen = "Before work starts"
                  , rowNeeds = ["what the change could affect"]
                  , rowCheckedBy = ["a person looking at it"]
                  , rowApproval = "A person must approve it"
                  , rowWaivable = "It cannot be waived"
                  , rowAppliesTo = "Only code changes, only work marked bug-fix, only when it changes source code"
                  }
              , CheckRow
                  { rowCheck = "review"
                  , rowWhen = "Before the work is accepted"
                  , rowNeeds = ["a record of the independent review", "a record of the automatic checks"]
                  , rowCheckedBy = ["an automatic check", "an independent reviewer"]
                  , rowApproval = "Lockstep's supervisor must approve it"
                  , rowWaivable = "A person may waive it for one piece of work, giving a reason"
                  , rowAppliesTo = "All work"
                  }
              ]
        let
          rowWords row = [rowWhen row, rowApproval row, rowWaivable row, rowAppliesTo row] <> rowNeeds row <> rowCheckedBy row
        traverse_ plain (L.concatMap (rowWords . checkRow) (definitionGates d))
    , testCase "with no current set of checks nothing is lost" $ do
        chosen <- definition (Just True) []
        checksLost Nothing chosen @?= []
    , testCase "an identical set or one that only adds checks loses nothing" $ do
        current <- definition (Just False) [impactGate]
        same <- definition (Just False) [impactGate]
        more <- definition (Just False) [impactGate, reviewGate]
        checksLost (Just current) same @?= []
        checksLost (Just current) more @?= []
    , testCase "a removed check and the documents-only rule are losses" $ do
        current <- definition (Just False) [impactGate, reviewGate]
        fewer <- definition Nothing [reviewGate]
        checksLost (Just current) fewer @?= [LostCheck "impact", LostDocsOnlyRule]
        loose <- definition (Just True) [impactGate, reviewGate]
        checksLost (Just current) loose @?= [LostDocsOnlyRule]
    , testCase "a changed check is a loss even when it is stricter" $ do
        current <- definition Nothing [impactGate]
        stricter <- definition Nothing [impactGate {rawGateVerifiers = ["human-inspection", "independent-review"]}]
        checksLost (Just current) stricter @?= [LostCheck "impact"]
    , testCase "an inherited documents-only setting reads as allowed" $ do
        current <- definition Nothing [impactGate]
        allowed <- definition (Just True) [impactGate]
        forbidden <- definition (Just False) [impactGate]
        checksLost (Just current) allowed @?= []
        checksLost (Just current) forbidden @?= []
        checksLost (Just forbidden) current @?= [LostDocsOnlyRule]
    , testCase "each loss is named in plain words" $ do
        lossWords (LostCheck "impact") @?= "the check impact"
        plain (lossWords LostDocsOnlyRule)
    , testCase "every reason work cannot start has plain words" $ do
        g <- gid "impact"
        p <- pid "team"
        r <- either (const (assertFailure "resource")) pure (mkResourceName "printer")
        let
          reasons =
            [ BindingMismatch
            , ProfileDefaultUnset
            , ProfileChangedSince [p]
            , PrerequisiteBlocked g (MissingArtifact ImpactAssessment)
            , PrerequisiteBlocked g (AmbiguousEvidence ImpactAssessment)
            , PrerequisiteBlocked g (Unverified ImpactAssessment [])
            , PrerequisiteBlocked g (NeedsApproval ImpactAssessment ApprovalHuman)
            , DependencyUnknown order
            , DependencyUnsatisfiable order
            , DependencyIncomplete order
            , RepositoryNotOwned
            , RepositoryReserved order
            , ResourceUnknownReason r
            , ResourceUnavailableReason r
            , SourceUnknown
            , SourceStale
            ]
        traverse_ (plain . ineligibilityWords) reasons
        L.length (L.nub (fmap ineligibilityWords reasons)) @?= L.length reasons
        ineligibilityWords ProfileDefaultUnset @?= "No checks are chosen for this project yet."
        ineligibilityWords (DependencyIncomplete order) @?= "It needs other work to finish first."
        assertBool "the missing check is not named" ("impact" `T.isInfixOf` ineligibilityWords (PrerequisiteBlocked g (MissingArtifact ImpactAssessment)))
    , testCase "every refusal has plain words, and an unknown code has general ones" $ do
        let
          codes = ["unknown-project", "project-has-no-folder", "checks-changed", "profile-unknown", "profile-integrity", "fewer-checks-unconfirmed"]
        traverse_ (plain . checksRefusalWords) codes
        L.length (L.nub (fmap checksRefusalWords codes)) @?= L.length codes
        plain (checksRefusalWords "something-else")
        assertBool "a known code reads like the unknown one" (checksRefusalWords "something-else" `L.notElem` fmap checksRefusalWords codes)
    , testCase "the built-in starting choice is lockstep-basic version 1 with no extra checks" $ do
        basicChecksId @?= "lockstep-basic"
        raw <- either (\e -> assertFailure ("not a profile document: " <> T.unpack e)) pure (decodeProfileDocument basicChecksDocument)
        d <- either (\r -> assertFailure ("refused: " <> show r)) pure (mkProfileDefinition raw)
        (profileIdText (definitionId d), definitionVersion d, L.length (definitionGates d)) @?= ("lockstep-basic", 1, 0)
        assertBool "not a small document" (LBS.length basicChecksDocument < 200)
    ]
