{-# LANGUAGE OverloadedStrings #-}

{- | The pure rules for letting Lockstep work in a project and handing it a bug
(contract C-P4.1 X1–X3, X6, X7, X10): the built-in Bug Profile and its stored
document, which bug checks a set lacks, which folders Lockstep may write, why a
task cannot be handed over, the request texts and the plain words.
-}
module Lockstep.Kernel.ExecutionTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Execution (bugFixDocument)
import Lockstep.Application.ProfileDocument (decodeProfileDocument)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Execution
  ( admissionBlock
  , admissionRequestText
  , bugCheckIds
  , bugClass
  , bugFixDefinition
  , bugFixProfileId
  , bugFixRaw
  , enablementRequestText
  , executionRefusalCodes
  , executionRefusalWords
  , insideProjectsFolder
  , missingBugChecks
  )
import Lockstep.Kernel.Profile
  ( Approval (..)
  , ArtifactKind (..)
  , Gate
  , GateStage (..)
  , ProfileDefinition
  , RawGate (..)
  , RawProfile (..)
  , VerifierKind (..)
  , definitionAllows
  , definitionGates
  , definitionId
  , definitionVersion
  , gateApproval
  , gateArtifacts
  , gateExceptionPath
  , gateId
  , gateIdText
  , gateScopes
  , gateStage
  , gateVerifiers
  , mkProfileDefinition
  , profileIdText
  , profileRef
  )
import Lockstep.Kernel.Task (TaskReadiness (..))

definition :: IO ProfileDefinition
definition =
  either (\r -> assertFailure ("the Bug Profile is not valid: " <> show r)) pure bugFixDefinition

gatesOf :: RawProfile -> IO [Gate]
gatesOf raw =
  either (const (assertFailure "a test profile is not valid")) (pure . definitionGates) (mkProfileDefinition raw)

gateNamed :: T.Text -> [Gate] -> IO Gate
gateNamed name gates =
  maybe (assertFailure ("no gate " <> T.unpack name)) pure (L.find ((== name) . gateIdText . gateId) gates)

internalWords :: [T.Text]
internalWords =
  ["profile", "gate", "invariant", "work order", "ticket", "engineer", "scheduler", "digest", "supervisor", "repositor", "git", "phase", "work unit", "contract"]

plain :: T.Text -> Assertion
plain text = do
  assertBool "empty words" (not (T.null (T.strip text)))
  traverse_
    (\word -> assertBool (T.unpack ("internal word " <> word <> " in: " <> text)) (not (word `T.isInfixOf` T.toLower text)))
    internalWords

contractCodes :: [T.Text]
contractCodes =
  [ "unknown-project"
  , "unknown-task"
  , "project-has-no-folder"
  , "folder-read-only"
  , "ownership-invalid"
  , "repository-changed"
  , "checks-changed"
  , "bug-checks-missing"
  , "already-enabled"
  , "execution-not-enabled"
  , "already-admitted"
  , "stale-revision"
  , "task-not-ready"
  , "task-waiting"
  , "task-blocked"
  , "task-cannot-start"
  , "task-closed"
  , "key-conflict"
  , "revision-out-of-range"
  , "admission-refused"
  ]

root :: T.Text
root =
  "/home/someone/lockstep-projects"

tests :: TestTree
tests =
  testGroup
    "letting Lockstep work in a project and handing it a bug (C-P4.1)"
    [ testCase "the Bug Profile is lockstep-bug-fix version 1: five checks on bug work, before acceptance" $ do
        d <- definition
        (profileIdText (definitionId d), definitionVersion d, definitionAllows d) @?= ("lockstep-bug-fix", 1, Nothing)
        (bugFixProfileId, bugClass) @?= ("lockstep-bug-fix", "bug")
        fmap (gateIdText . gateId) (definitionGates d) @?= ["bug-regression-test", "bug-reproduction", "bug-requirements", "bug-review", "bug-verification"]
        bugCheckIds @?= ["bug-regression-test", "bug-reproduction", "bug-requirements", "bug-review", "bug-verification"]
        traverse_
          ( \g -> do
              gateStage g @?= BeforeAcceptance
              gateScopes g @?= (Just ["engineering"], Just ["bug"], Nothing)
              gateApproval g @?= ApprovalSupervisor
          )
          (definitionGates d)
        rawSpecializations bugFixRaw @?= []
        rawInvariantExceptions bugFixRaw @?= []
    , testCase "each check needs what Bible §31.1 names, and only reproduction has a human exception path" $ do
        gates <- definitionGates <$> definition
        let
          shape name = do
            g <- gateNamed name gates
            pure (gateArtifacts g, gateVerifiers g, gateExceptionPath g)
        shape "bug-reproduction" >>= (@?= ([Reproduction], [VerifyCommand], True))
        shape "bug-requirements" >>= (@?= ([ImpactAssessment, RequirementsBasis], [VerifyDigest], False))
        shape "bug-regression-test" >>= (@?= ([FrozenTests], [VerifyCommand, VerifyDigest], False))
        shape "bug-verification" >>= (@?= ([RegressionEvidence, VerificationRecord], [VerifyCommand], False))
        shape "bug-review" >>= (@?= ([ReviewRecord], [VerifyIndependentReview], False))
    , testCase "the stored document decodes to exactly the Bug Profile, with the same digest" $ do
        d <- definition
        raw <- either (\e -> assertFailure ("the document does not decode: " <> T.unpack e)) pure (decodeProfileDocument bugFixDocument)
        stored <- either (const (assertFailure "the document is not a valid profile")) pure (mkProfileDefinition raw)
        stored @?= d
        profileRef sha256Hasher stored @?= profileRef sha256Hasher d
    , testCase "missing bug checks: none given, all five; the Bug Profile, none; a stricter variant, that one; extra checks, none" $ do
        d <- definition
        missingBugChecks [] @?= bugCheckIds
        missingBugChecks (definitionGates d) @?= []
        stricter <-
          gatesOf
            bugFixRaw
              { rawGates =
                  fmap
                    (\g -> if rawGateId g == "bug-review" then g {rawGateApproval = "human"} else g)
                    (rawGates bugFixRaw)
              }
        missingBugChecks stricter @?= ["bug-review"]
        extra <-
          gatesOf
            bugFixRaw
              { rawGates =
                  rawGates bugFixRaw
                    <> [RawGate "impact" "before-acceptance" ["impact-assessment"] (Just ["engineering"]) Nothing Nothing ["human-inspection"] "human" False]
              }
        missingBugChecks extra @?= []
        missingBugChecks (L.filter ((/= "bug-review") . gateIdText . gateId) (definitionGates d)) @?= ["bug-review"]
    , testCase "only a folder directly inside the projects folder is one Lockstep may write" $ do
        insideProjectsFolder root (root <> "/website") @?= True
        insideProjectsFolder root (root <> "/website-2") @?= True
        insideProjectsFolder root (root <> "/website/inner") @?= False
        insideProjectsFolder root root @?= False
        insideProjectsFolder root (root <> "/") @?= False
        insideProjectsFolder root (root <> "/.") @?= False
        insideProjectsFolder root (root <> "/..") @?= False
        insideProjectsFolder root (root <> "/website/") @?= False
        insideProjectsFolder (root <> "/") (root <> "/website") @?= False
        insideProjectsFolder root "/home/someone/elsewhere/website" @?= False
        insideProjectsFolder root (root <> "-x/website") @?= False
        insideProjectsFolder "" "/website" @?= False
    , testCase "a task can be handed over only when it is ready to work on" $ do
        admissionBlock ReadyToWork @?= Nothing
        admissionBlock NotYetReady @?= Just "task-not-ready"
        admissionBlock BeingWorkedOn @?= Just "task-not-ready"
        admissionBlock (WaitingFor ["Buy paper"]) @?= Just "task-waiting"
        admissionBlock (BlockedBecause "no paper") @?= Just "task-blocked"
        admissionBlock (CannotStart ["Buy paper"]) @?= Just "task-cannot-start"
        admissionBlock Finished @?= Just "task-closed"
        admissionBlock TaskCanceled @?= Just "task-closed"
    , testCase "the request texts are exact, and every field changes them" $ do
        let
          project = "0b6f8a52-35a6-4a3e-9a51-7d3b3c1d2e4f"
          task = "5d1c2b3a-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        enablementRequestText project "none" @?= "lockstep-execution-enable-v1\nproject 0b6f8a52-35a6-4a3e-9a51-7d3b3c1d2e4f\nexpected none\n"
        admissionRequestText task 3 @?= "lockstep-bug-admission-v1\ntask 5d1c2b3a-4e5f-4a6b-8c7d-9e0f1a2b3c4d\nexpected 3\n"
        assertBool "the project does not count" (enablementRequestText project "none" /= enablementRequestText task "none")
        assertBool "the expected checks do not count" (enablementRequestText project "none" /= enablementRequestText project "lockstep-basic")
        assertBool "the task does not count" (admissionRequestText task 3 /= admissionRequestText project 3)
        assertBool "the revision does not count" (admissionRequestText task 3 /= admissionRequestText task 4)
    , testCase "plain words for every refusal, none with an internal word" $ do
        L.sort executionRefusalCodes @?= L.sort contractCodes
        traverse_
          ( \code -> do
              plain (executionRefusalWords code)
              assertBool ("no words of its own for " <> T.unpack code) (executionRefusalWords code /= executionRefusalWords "no-such-code")
          )
          contractCodes
        plain (executionRefusalWords "no-such-code")
    ]
