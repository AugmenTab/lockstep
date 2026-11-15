{-# LANGUAGE OverloadedStrings #-}

{- | The work policy of each kind (contract C-P6.6 G1–G3, G5): test-first
rules, reproductions, budgets, floors, the built-in engineering Profile, the
green-only candidate rule and the classification of changed paths.
-}
module Lockstep.Kernel.WorkPolicyTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Execution (bugFixRaw, missingBugChecks)
import Lockstep.Kernel.Plan (WorkKind (..))
import Lockstep.Kernel.Profile
  ( ArtifactKind (FrozenTests, ReviewRecord)
  , PathClass (..)
  , ProfileDefinition
  , RawGate (..)
  , RawProfile (..)
  , VerifierKind (..)
  , definitionAllows
  , definitionGates
  , gateArtifacts
  , gateExceptionPath
  , gateId
  , gateIdText
  , gateVerifiers
  , mkProfileDefinition
  )
import Lockstep.Kernel.Transaction
  ( BaselineClass (..)
  , Counters (..)
  , Stage (..)
  , Transaction (..)
  , TxInput (..)
  , TxState (..)
  , maxAttempts
  , maxCorrections
  , noCounters
  , stepTransaction
  )
import Lockstep.Kernel.Transition (Principal (Supervisor))
import Lockstep.Kernel.WorkPolicy
  ( TestFirst (..)
  , WorkPolicy (..)
  , documentationOnly
  , engineeringDefinition
  , engineeringProfileId
  , kindClass
  , kindFloor
  , missingChecks
  , pathClassOf
  , testFirstCode
  , workPolicy
  )

kinds :: [WorkKind]
kinds =
  [minBound .. maxBound]

-- | A Profile of just these gates.
profileOf :: [RawGate] -> IO ProfileDefinition
profileOf gates =
  either
    (\e -> assertFailure ("not a Profile: " <> show e))
    pure
    (mkProfileDefinition (bugFixRaw {rawProfileId = "test-profile", rawGates = gates}))

floorOf :: WorkKind -> IO ProfileDefinition
floorOf =
  profileOf . kindFloor

engineering :: IO ProfileDefinition
engineering =
  either (\e -> assertFailure ("lockstep-engineering is not a Profile: " <> show e)) pure engineeringDefinition

candidate :: [BaselineClass] -> Int -> Either T.Text Transaction
candidate classes made =
  stepTransaction Supervisor (CandidateCharacterized classes) (Transaction (Running StageCandidate) noCounters {candidatesMade = made})

tests :: TestTree
tests =
  testGroup
    "C-P6.6 work policy (pure)"
    [ testGroup
        "each kind's policy (G1)"
        [ testCase "class tags, test-first rules, reproductions and non-behavioural work" $
            fmap (\k -> let p = workPolicy k in (policyKind p, policyClass p, testFirstCode (policyTestFirst p), policyReproduction p, policyNonBehavioural p)) kinds
              @?= [ (BugFix, "bug", "red-first", True, False)
                  , (Feature, "feature", "red-first", True, False)
                  , (GreenfieldBuild, "greenfield", "red-first", True, False)
                  , (Refactor, "refactor", "green-only", False, False)
                  , (Documentation, "documentation", "green-only", False, True)
                  ]
        , testCase "the class tag is the policy's" $
            traverse_ (\k -> kindClass k @?= policyClass (workPolicy k)) kinds
        , testCase "no silent removal of budgets: every kind has the engine's own correction and attempt budgets" $
            traverse_ (\k -> (policyCorrections (workPolicy k), policyAttempts (workPolicy k)) @?= (maxCorrections, maxAttempts)) kinds
        , testCase "the test-first rules are two, each named" $
            fmap testFirstCode [minBound .. maxBound :: TestFirst] @?= ["red-first", "green-only"]
        ]
    , testGroup
        "floors (G2)"
        [ testCase "each floor's checks, by id" $ do
            fmap (L.sort . fmap rawGateId . kindFloor) kinds
              @?= [ ["bug-regression-test", "bug-reproduction", "bug-requirements", "bug-review", "bug-verification"]
                  , ["feature-requirements", "feature-review", "feature-tests", "feature-verification"]
                  , ["greenfield-requirements", "greenfield-review", "greenfield-tests", "greenfield-verification"]
                  , ["refactor-authorization", "refactor-characterization", "refactor-review", "refactor-verification"]
                  , ["documentation-classification", "documentation-review", "documentation-verification"]
                  ]
        , testCase "the bug fix's floor is the Bug Profile's checks, unchanged" $
            kindFloor BugFix @?= rawGates bugFixRaw
        , testCase "every floor is a valid Profile, each check scoped to engineering work of its kind's class" $
            traverse_
              ( \k -> do
                  _ <- floorOf k
                  traverse_ (\g -> (rawGateKinds g, rawGateClasses g) @?= (Just ["engineering"], Just [kindClass k])) (kindFloor k)
              )
              kinds
        , testCase "every floor has an independent review; every behaviour-changing floor freezes tests and verifies by command" $
            traverse_
              ( \k -> do
                  d <- floorOf k
                  let
                    gates = definitionGates d
                    has p = L.any p gates
                  assertBool (show k <> ": no independent review") (has (\g -> ReviewRecord `L.elem` gateArtifacts g && VerifyIndependentReview `L.elem` gateVerifiers g))
                  assertBool (show k <> ": no verification by command") (has (\g -> VerifyCommand `L.elem` gateVerifiers g))
                  when (k /= Documentation) $
                    assertBool (show k <> ": no frozen tests") (has ((FrozenTests `L.elem`) . gateArtifacts))
              )
              kinds
        , testCase "required tests cannot be disabled through an exception: no check that freezes tests has an exception path" $
            traverse_
              ( \k -> do
                  d <- floorOf k
                  traverse_ (\g -> assertBool (T.unpack (gateIdText (gateId g)) <> " may be excepted") (not (gateExceptionPath g))) [g | g <- definitionGates d, FrozenTests `L.elem` gateArtifacts g]
              )
              kinds
        , testCase "a refactor needs a person's approval record" $
            fmap rawGateApproval (L.filter ((== "refactor-authorization") . rawGateId) (kindFloor Refactor)) @?= ["human"]
        ]
    , testGroup
        "lockstep-engineering and missing checks (G3, G4)"
        [ testCase "it holds every kind's floor unchanged, and the Bug Profile's checks; it allows non-behavioural work" $ do
            d <- engineering
            traverse_ (\k -> missingChecks k (definitionGates d) @?= []) kinds
            missingBugChecks (definitionGates d) @?= []
            definitionAllows d @?= Just True
            engineeringProfileId @?= "lockstep-engineering"
        , testCase "the Bug Profile holds the bug fix's floor and none of the others" $ do
            d <- profileOf (rawGates bugFixRaw)
            missingChecks BugFix (definitionGates d) @?= []
            missingChecks Feature (definitionGates d) @?= ["feature-requirements", "feature-review", "feature-tests", "feature-verification"]
            missingChecks Documentation (definitionGates d) @?= ["documentation-classification", "documentation-review", "documentation-verification"]
        , testCase "invalid weakening refused: a check without its independent review, or with an exception path, counts as missing" $ do
            let
              weaken name f = fmap (\g -> if rawGateId g == name then f g else g) (kindFloor Feature)
            noReview <- profileOf (weaken "feature-review" (\g -> g {rawGateVerifiers = ["human-inspection"]}))
            missingChecks Feature (definitionGates noReview) @?= ["feature-review"]
            excepted <- profileOf (weaken "feature-tests" (\g -> g {rawGateExceptionPath = True}))
            missingChecks Feature (definitionGates excepted) @?= ["feature-tests"]
        ]
    , testGroup
        "the green-only candidate rule (G5 b)"
        [ testCase "all green at the basis goes on to the challenge, counting the candidate" $
            candidate [GreenConfirmed, GreenConfirmed] 0 @?= Right (Transaction (Running StageChallengePre) noCounters {candidatesMade = 1})
        , testCase "a red test is never accepted: it is a correction round" $
            candidate [GreenConfirmed, RedConfirmed] 0 @?= Right (Transaction (Running StageCandidate) noCounters {candidatesMade = 1})
        , testCase "a green test that fails at the basis is a correction round" $
            candidate [GreenCandidateFailed] 0 @?= Right (Transaction (Running StageCandidate) noCounters {candidatesMade = 1})
        , testCase "a run failure halts" $
            fmap txState (candidate [GreenConfirmed, RunFailed] 0) @?= Right (Halted StageCandidate "baseline-run-failed")
        , testCase "the corrections are bounded by the engine's budget" $
            fmap txState (candidate [RedConfirmed] maxCorrections) @?= Right (Halted StageCandidate "candidates-exhausted")
        , testCase "no tests at all is not all green" $
            fmap txState (candidate [] maxCorrections) @?= Right (Halted StageCandidate "candidates-exhausted")
        , testCase "the rule applies only at the candidate stage" $
            stepTransaction Supervisor (CandidateCharacterized [GreenConfirmed]) (Transaction (Running StageVerify) noCounters) @?= Left "illegal-input"
        ]
    , testGroup
        "changed paths (G5 c)"
        [ testCase "documentation is known by its name, conservatively" $ do
            fmap pathClassOf ["README.md", "docs/guide.md", "CHANGELOG", "notes.txt", "manual.rst", "LICENSE"]
              @?= [PathDocs, PathDocs, PathDocs, PathDocs, PathDocs, PathDocs]
            fmap pathClassOf ["f1.py", "src/Main.hs", "docs/conf.py", "test_f1.py", "tests/a.py", "package.yaml", "stack.yaml.lock", "requirements.txt", "settings.toml", ".gitignore"]
              @?= [PathSource, PathSource, PathSource, PathTests, PathTests, PathBuild, PathDependencies, PathDependencies, PathConfiguration, PathSource]
        , testCase "documentation only: every path, and a behavioural one spoils it" $ do
            documentationOnly ["README.md", "docs/guide.md"] @?= True
            documentationOnly ["README.md", "f1.py"] @?= False
            documentationOnly ["docs/conf.py"] @?= False
        ]
    ]
