{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | C-P2.3: Profile definitions, precedence, trust, exceptions, binding, staleness and gates.
module Lockstep.Kernel.ProfileTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Identity
  ( ContractId (..)
  , EngineerId (..)
  , RepositoryId (..)
  , TicketId (..)
  , WorkOrderId (..)
  , WorkUnitId (..)
  , uuidFromWords
  , uuidText
  )
import Lockstep.Kernel.Profile
  ( Approval (..)
  , ArtifactKind (..)
  , Behaviour (..)
  , ContentDigest
  , EffectiveProfile
  , ExceptionReceipt
  , ExceptionTarget (..)
  , Freshness (..)
  , Gate
  , GateBlock (..)
  , GateEvidence (..)
  , GateStage (..)
  , GateStatus (..)
  , Hasher (..)
  , LayerLevel (..)
  , Override
  , PathClass (..)
  , ProfileBinding
  , ProfileConfirmation
  , ProfileDefinition
  , ProfileRef (..)
  , ProfileRefusal (..)
  , RawGate (..)
  , RawProfile (..)
  , RawSpecialization (..)
  , ResolutionInput (..)
  , VerifierKind (..)
  , WorkFacts
  , acceptanceGateIds
  , admitWorkUnitException
  , bindProfile
  , bindingDigest
  , bindingExceptions
  , bindingFreshness
  , bindingProfile
  , bindingWorkOrder
  , checkObservedPaths
  , contentDigestText
  , definitionGates
  , definitionId
  , definitionVersion
  , effectiveAllowsNonBehavioural
  , effectiveDigest
  , effectiveGates
  , effectiveInvariants
  , effectiveSources
  , evaluateGate
  , executionPrerequisites
  , gateApplies
  , gateId
  , gateIdText
  , gateStage
  , installationBaseline
  , mkClassTag
  , mkContentDigest
  , mkExceptionReceipt
  , mkGateId
  , mkNonBehaviouralBasis
  , mkOverride
  , mkProfileConfirmation
  , mkProfileDefinition
  , mkWorkFacts
  , parsePathClass
  , producibleBeforeExecution
  , profileIdText
  , profileRef
  , profileRefusalCode
  , renderBinding
  , renderEffectiveProfile
  , renderProfileDefinition
  , requiresFrozenTests
  , resolveProfile
  , verifyProvenance
  )
import Lockstep.Kernel.Transition (Principal (..))
import Lockstep.Kernel.WorkOrder (WorkOrderKind (..), parseWorkOrderKind, workOrderKindName)
import Lockstep.Kernel.WorkUnit (AdmittedWorkUnit (..), WorkUnitRequest (..))
import Lockstep.Kernel.WorkUnitLifecycle (frozenDigest, frozenGates, mkFrozenContract)

tests :: TestTree
tests =
  testGroup
    "Kernel Profile policy (C-P2.3, DG-05)"
    [ definitionTests
    , renderingTests
    , precedenceTests
    , factsTests
    , exceptionTests
    , bindingTests
    , freshnessTests
    , gateTests
    ]

-- Fixtures ------------------------------------------------------------------

h :: Hasher
h =
  sha256Hasher

hashOf :: T.Text -> ContentDigest
hashOf text =
  case h of
    Hasher f -> f text

-- | A gate with any applicability and no exception path.
rawGate :: T.Text -> T.Text -> [T.Text] -> [T.Text] -> T.Text -> RawGate
rawGate gid stage artifacts verifiers approval =
  RawGate
    { rawGateId = gid
    , rawGateStage = stage
    , rawGateArtifacts = artifacts
    , rawGateKinds = Nothing
    , rawGateClasses = Nothing
    , rawGatePathClasses = Nothing
    , rawGateVerifiers = verifiers
    , rawGateApproval = approval
    , rawGateExceptionPath = False
    }

raw :: T.Text -> Integer -> [RawGate] -> RawProfile
raw pid version gates =
  RawProfile
    { rawProfileId = pid
    , rawProfileVersion = version
    , rawAllowsNonBehavioural = Nothing
    , rawInvariantExceptions = []
    , rawGates = gates
    , rawSpecializations = []
    }

kindSpec :: T.Text -> T.Text -> RawSpecialization
kindSpec kind =
  RawSpecialization (Just kind) Nothing

classSpec :: T.Text -> T.Text -> RawSpecialization
classSpec tag =
  RawSpecialization Nothing (Just tag)

-- | The default's "impact" gate: engineering only, exception path.
impactGate :: RawGate
impactGate =
  (rawGate "impact" "before-execution" ["impact-assessment"] ["human-inspection"] "supervisor")
    { rawGateKinds = Just ["engineering"]
    , rawGateExceptionPath = True
    }

reviewGate :: RawGate
reviewGate =
  rawGate "review" "before-acceptance" ["review-record"] ["independent-review"] "human"

-- | Applies only to investigate orders; has an exception path.
investigateGate :: RawGate
investigateGate =
  (rawGate "inv-only" "before-execution" ["requirements-basis"] ["human-inspection"] "human")
    { rawGateKinds = Just ["investigate"]
    , rawGateExceptionPath = True
    }

teamRaw :: RawProfile
teamRaw =
  (raw "team" 1 [impactGate, reviewGate, investigateGate])
    { rawSpecializations = [kindSpec "engineering" "eng", classSpec "security" "sec"]
    }

-- | A strengthening specialization: impact broadened and tightened, plus a new gate.
engRaw :: RawProfile
engRaw =
  raw
    "eng"
    1
    [ rawGate "impact" "before-execution" ["reproduction", "impact-assessment"] ["human-inspection", "digest-check"] "human"
    , rawGate "threat" "before-execution" ["threat-model"] ["human-inspection"] "human"
    ]

secRaw :: RawProfile
secRaw =
  raw "sec" 1 [rawGate "sec-gate" "before-completion" ["threat-model"] ["independent-review"] "human"]

def :: RawProfile -> IO ProfileDefinition
def r =
  either (\refusal -> assertFailure ("fixture refused: " <> show refusal)) pure (mkProfileDefinition r)

named :: (T.Text -> Maybe a) -> T.Text -> IO a
named parse text =
  maybe (assertFailure ("fixture name refused: " <> T.unpack text)) pure (parse text)

facts :: WorkOrderKind -> [T.Text] -> [PathClass] -> IO WorkFacts
facts kind tags paths = do
  classes <- traverse (named mkClassTag) tags
  either (\refusal -> assertFailure ("facts refused: " <> show refusal)) pure (mkWorkFacts Human kind classes paths BehaviourChanging)

-- | The shared fixtures: the default, its two specializations and two kinds of work.
data Base
  = Base
  { team :: ProfileDefinition
  , eng :: ProfileDefinition
  , sec :: ProfileDefinition
  , engineering :: WorkFacts
  , investigating :: WorkFacts
  , otherDigest :: ContentDigest
  }

withBase :: (Base -> Assertion) -> Assertion
withBase action = do
  base <-
    Base
      <$> def teamRaw
      <*> def engRaw
      <*> def secRaw
      <*> facts Engineering [] []
      <*> facts Investigate [] []
      <*> named mkContentDigest (T.replicate 64 "0")
  action base

resolveWith :: ProfileDefinition -> [ProfileDefinition] -> [Override] -> WorkFacts -> Either ProfileRefusal EffectiveProfile
resolveWith d catalog overrides f =
  resolveProfile h (ResolutionInput d catalog overrides f)

resolved :: ProfileDefinition -> [ProfileDefinition] -> [Override] -> WorkFacts -> IO EffectiveProfile
resolved d catalog overrides f =
  either (\refusal -> assertFailure ("resolution refused: " <> show refusal)) pure (resolveWith d catalog overrides f)

codeOf :: Either ProfileRefusal a -> Maybe T.Text
codeOf =
  either (Just . profileRefusalCode) (const Nothing)

-- | The refusal code and the refusal's names, for comparison without smart constructors.
shape :: Either ProfileRefusal a -> (Maybe T.Text, [T.Text])
shape result =
  case result of
    Right _ -> (Nothing, [])
    Left refusal -> (Just (profileRefusalCode refusal), payload refusal)

payload :: ProfileRefusal -> [T.Text]
payload refusal =
  case refusal of
    WeakensGate g axis -> [gateIdText g, axis]
    UnprovableStrengthening g axis -> [gateIdText g, axis]
    ProfileConflict subject -> [subject]
    ProfileUnavailable p -> [profileIdText p]
    GateUnsatisfiableBeforeExecution g -> [gateIdText g]
    ExceptionUnknownGate g -> [gateIdText g]
    ExceptionNotApplicable g -> [gateIdText g]
    ExceptionNotPermitted g -> [gateIdText g]
    UntrustedClassification p -> [T.pack (show p)]
    BindingNotAuthorized p -> [T.pack (show p)]
    _ -> []

changed :: Freshness -> Maybe [T.Text]
changed freshness =
  case freshness of
    Fresh -> Nothing
    ProfileChanged ids -> Just (fmap profileIdText ids)

refusedWith :: T.Text -> Either ProfileRefusal a -> Assertion
refusedWith code result =
  codeOf result @?= Just code

accepted :: Either ProfileRefusal a -> Assertion
accepted result =
  codeOf result @?= Nothing

renderedLines :: EffectiveProfile -> [T.Text]
renderedLines =
  T.lines . renderEffectiveProfile

hasLine :: T.Text -> EffectiveProfile -> Assertion
hasLine line eff =
  assertBool ("missing line: " <> T.unpack line <> "\n" <> T.unpack (renderEffectiveProfile eff)) (line `L.elem` renderedLines eff)

lacksPrefix :: T.Text -> EffectiveProfile -> Assertion
lacksPrefix prefix eff =
  assertBool ("unexpected line " <> T.unpack prefix) (not (L.any (T.isPrefixOf prefix) (renderedLines eff)))

gateIds :: [Gate] -> [T.Text]
gateIds =
  fmap (gateIdText . gateId)

wo1, wo2 :: WorkOrderId
wo1 = WorkOrderId (uuidFromWords 0 1)
wo2 = WorkOrderId (uuidFromWords 0 2)

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 18) (secondsToDiffTime 3600)

override :: [RawGate] -> IO Override
override gates =
  either (\refusal -> assertFailure ("override refused: " <> show refusal)) pure (mkOverride Human "alice" "stricter for this order" Nothing gates)

-- Definitions ----------------------------------------------------------------

definitionTests :: TestTree
definitionTests =
  testGroup
    "definitions (F1-F4, D-5.1a, D-5.2)"
    [ testCase "a valid definition is accepted with its gates" $
        withBase $ \Base {team} -> do
          gateIds (definitionGates team) @?= ["impact", "inv-only", "review"]
          definitionVersion team @?= 1
          profileIdText (definitionId team) @?= "team"
    , testCase "invalid ids, versions and vocabulary are invalid-profile" $ do
        let
          bad = refusedWith "invalid-profile" . mkProfileDefinition
          withGate g = raw "p" 1 [g]
          ok = rawGate "g" "before-acceptance" ["review-record"] ["independent-review"] "human"
        accepted (mkProfileDefinition (withGate ok))
        bad (raw "Bad" 1 [])
        bad (raw "" 1 [])
        bad (raw "p" 0 [])
        bad (withGate ok {rawGateId = "G"})
        bad (withGate ok {rawGateStage = "later"})
        bad (withGate ok {rawGateArtifacts = ["essay"]})
        bad (withGate ok {rawGateArtifacts = []})
        bad (withGate ok {rawGateVerifiers = ["vibes"]})
        bad (withGate ok {rawGateVerifiers = []})
        bad (withGate ok {rawGateApproval = "manager"})
        bad (withGate ok {rawGateKinds = Just ["deploy"]})
        bad (withGate ok {rawGateKinds = Just []})
        bad (withGate ok {rawGateClasses = Just []})
        bad (withGate ok {rawGateClasses = Just ["Not A Tag"]})
        bad (withGate ok {rawGatePathClasses = Just ["binaries"]})
        bad (raw "p" 1 [ok, ok])
        bad ((raw "p" 1 []) {rawSpecializations = [kindSpec "engineering" "p"]})
        bad ((raw "p" 1 []) {rawSpecializations = [RawSpecialization (Just "engineering") (Just "x") "q"]})
        bad ((raw "p" 1 []) {rawSpecializations = [RawSpecialization Nothing Nothing "q"]})
        bad ((raw "p" 1 []) {rawSpecializations = [kindSpec "engineering" "q", kindSpec "engineering" "r"]})
        bad ((raw "p" 1 []) {rawSpecializations = [kindSpec "deploy" "q"]})
        bad ((raw "p" 1 []) {rawInvariantExceptions = ["no-such-invariant"]})
    , testCase "an invariant exception is refused, including protected-frozen-tests" $ do
        refusedWith "weakens-universal-invariant" (mkProfileDefinition (raw "p" 1 []) {rawInvariantExceptions = ["independent-review"]})
        refusedWith "weakens-universal-invariant" (mkProfileDefinition (raw "p" 1 []) {rawInvariantExceptions = ["protected-frozen-tests"]})
    , testCase "a gate claiming an invariant id is refused" $
        refusedWith
          "weakens-universal-invariant"
          (mkProfileDefinition (raw "p" 1 [(rawGate "invariant-independent-review" "before-acceptance" ["review-record"] ["independent-review"] "human") {rawGateExceptionPath = True}]))
    , testCase "clarification 1: a before-execution gate cannot require execution-time evidence" $ do
        shape (mkProfileDefinition (raw "p" 1 [rawGate "v" "before-execution" ["verification-record"] ["deterministic-command"] "none"]))
          @?= (Just "gate-unsatisfiable-before-execution", ["v"])
        refusedWith "gate-unsatisfiable-before-execution" (mkProfileDefinition (raw "p" 1 [rawGate "t" "before-execution" ["reproduction", "frozen-tests"] ["digest-check"] "none"]))
        accepted (mkProfileDefinition (raw "p" 1 [rawGate "v" "before-acceptance" ["verification-record"] ["deterministic-command"] "none"]))
    , testCase "artifact kinds are split by when they can be produced" $ do
        fmap producibleBeforeExecution [RequirementsBasis, Reproduction, ImpactAssessment, ThreatModel, ArchitectureAssessment, ClassificationRationale, HumanApprovalRecord]
          @?= L.replicate 7 True
        fmap producibleBeforeExecution [FrozenTests, VerificationRecord, ReviewRecord, RegressionEvidence, IntegrationRecord, Documentation]
          @?= L.replicate 6 False
    , testCase "kind and path-class names" $ do
        fmap workOrderKindName [minBound .. maxBound]
          @?= ["engineering", "investigate", "pr-rework", "integrate", "plan", "publish-report", "skill-install"]
        fmap (parseWorkOrderKind . workOrderKindName) [minBound .. maxBound] @?= fmap Just [minBound .. maxBound]
        parseWorkOrderKind "Engineering" @?= Nothing
        fmap parsePathClass ["docs", "source", "tests", "build", "dependencies", "configuration", "Docs"]
          @?= [Just PathDocs, Just PathSource, Just PathTests, Just PathBuild, Just PathDependencies, Just PathConfiguration, Nothing]
    ]

-- Rendering ------------------------------------------------------------------

goldenRaw :: RawProfile
goldenRaw =
  RawProfile
    { rawProfileId = "team"
    , rawProfileVersion = 3
    , rawAllowsNonBehavioural = Just True
    , rawInvariantExceptions = []
    , rawGates =
        [ (rawGate "b" "before-completion" ["documentation"] ["independent-review"] "none") {rawGateClasses = Just ["security", "bug-fix"]}
        , (rawGate "a" "before-execution" ["reproduction", "impact-assessment"] ["human-inspection", "digest-check"] "human")
            { rawGateKinds = Just ["pr-rework", "engineering"]
            , rawGatePathClasses = Just ["source", "docs"]
            , rawGateExceptionPath = True
            }
        ]
    , rawSpecializations = [classSpec "security" "sec", kindSpec "investigate" "inv", kindSpec "engineering" "eng"]
    }

goldenPermutedRaw :: RawProfile
goldenPermutedRaw =
  goldenRaw
    { rawGates =
        [ (rawGate "a" "before-execution" ["impact-assessment", "reproduction"] ["digest-check", "human-inspection"] "human")
            { rawGateKinds = Just ["engineering", "pr-rework"]
            , rawGatePathClasses = Just ["docs", "source"]
            , rawGateExceptionPath = True
            }
        , (rawGate "b" "before-completion" ["documentation"] ["independent-review"] "none") {rawGateClasses = Just ["bug-fix", "security"]}
        ]
    , rawSpecializations = [kindSpec "engineering" "eng", classSpec "security" "sec", kindSpec "investigate" "inv"]
    }

renderingTests :: TestTree
renderingTests =
  testGroup
    "canonical rendering and digests (F11)"
    [ testCase "the golden rendering of a definition" $ do
        golden <- def goldenRaw
        renderProfileDefinition golden
          @?= T.unlines
            [ "lockstep-profile 1"
            , "id team"
            , "version 3"
            , "allows-non-behavioural true"
            , "gate a stage=before-execution artifacts=impact-assessment,reproduction kinds=engineering,pr-rework classes=* path-classes=docs,source verifiers=digest-check,human-inspection approval=human exception-path=true"
            , "gate b stage=before-completion artifacts=documentation kinds=* classes=bug-fix,security path-classes=* verifiers=independent-review approval=none exception-path=false"
            , "specialize kind=engineering profile=eng"
            , "specialize kind=investigate profile=inv"
            , "specialize class=security profile=sec"
            ]
    , testCase "an absent permission renders as inherit" $ do
        d <- def (raw "p" 1 [])
        T.lines (renderProfileDefinition d) @?= ["lockstep-profile 1", "id p", "version 1", "allows-non-behavioural inherit"]
    , testCase "a permuted equivalent definition has the same rendering and digest" $ do
        golden <- def goldenRaw
        permuted <- def goldenPermutedRaw
        renderProfileDefinition permuted @?= renderProfileDefinition golden
        profileRef h permuted @?= profileRef h golden
    , testCase "profileRef carries the hash of the rendering" $ do
        golden <- def goldenRaw
        let
          ref = profileRef h golden
        refDigest ref @?= hashOf (renderProfileDefinition golden)
        refVersion ref @?= 3
        profileIdText (refId ref) @?= "team"
    , testCase "sha256Hasher is SHA-256 in lowercase hex" $
        contentDigestText (hashOf "abc") @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    , testCase "content digests are 64 lowercase hex characters" $ do
        fmap contentDigestText (mkContentDigest (T.replicate 64 "a")) @?= Just (T.replicate 64 "a")
        fmap contentDigestText (mkContentDigest (T.replicate 64 "A")) @?= Nothing
        fmap contentDigestText (mkContentDigest (T.replicate 63 "a")) @?= Nothing
        fmap contentDigestText (mkContentDigest (T.replicate 64 "g")) @?= Nothing
    , testCase "the installation baseline" $ do
        profileIdText (definitionId installationBaseline) @?= "lockstep-baseline"
        definitionVersion installationBaseline @?= 1
        definitionGates installationBaseline @?= []
        renderProfileDefinition installationBaseline
          @?= T.unlines ["lockstep-profile 1", "id lockstep-baseline", "version 1", "allows-non-behavioural true"]
    ]

-- Precedence -----------------------------------------------------------------

-- | A specialization "eng" (selected for engineering) defining the given gates.
engWith :: [RawGate] -> IO ProfileDefinition
engWith gates =
  def (raw "eng" 1 gates)

-- | Resolves the default with a specialization "eng" that redefines impact with one change.
withImpact :: Base -> (RawGate -> RawGate) -> IO (Maybe T.Text, [T.Text])
withImpact Base {team, engineering} change = do
  d <- engWith [change impactGate]
  pure (shape (resolveWith team [d] [] engineering))

precedenceTests :: TestTree
precedenceTests =
  testGroup
    "precedence (F5, D-5.3a, clarification 2)"
    [ testCase "a specialization adds a gate and strengthens one on every axis" $
        withBase $ \Base {team, eng, sec, engineering} -> do
          eff <- resolved team [eng, sec] [] engineering
          hasLine "gate impact stage=before-execution artifacts=impact-assessment,reproduction kinds=* classes=* path-classes=* verifiers=digest-check,human-inspection approval=human exception-path=false" eff
          hasLine "gate threat stage=before-execution artifacts=threat-model kinds=* classes=* path-classes=* verifiers=human-inspection approval=human exception-path=false" eff
          hasLine "gate review stage=before-acceptance artifacts=review-record kinds=* classes=* path-classes=* verifiers=independent-review approval=human exception-path=false" eff
          gateIds (effectiveGates eff) @?= ["impact", "inv-only", "review", "threat"]
    , testCase "each single-axis weakening is weakens-gate naming the axis" $
        withBase $ \base@Base {team, engineering} -> do
          let
            weakened axis change = withImpact base change >>= (@?= (Just "weakens-gate", ["impact", axis]))
          weakened "applicability" (\g -> g {rawGateClasses = Just ["security"]})
          weakened "applicability" (\g -> g {rawGatePathClasses = Just ["source"]})
          weakened "applicability" (\g -> g {rawGateKinds = Just ["investigate"]})
          weakened "artifacts" (\g -> g {rawGateArtifacts = ["reproduction"]})
          weakened "verifiers" (\g -> g {rawGateVerifiers = ["digest-check"]})
          weakened "approval" (\g -> g {rawGateApproval = "none"})
          d <- engWith [reviewGate {rawGateExceptionPath = True}]
          shape (resolveWith team [d] [] engineering) @?= (Just "weakens-gate", ["review", "exception-path"])
    , testCase "a weakening is refused even when another axis is strengthened" $
        withBase $ \base ->
          withImpact base (\g -> g {rawGateApproval = "human", rawGateVerifiers = ["digest-check"]})
            >>= (@?= (Just "weakens-gate", ["impact", "verifiers"]))
    , testCase "a stage change cannot be proved stronger" $
        withBase $ \base ->
          withImpact base (\g -> g {rawGateStage = "before-acceptance"})
            >>= (@?= (Just "unprovable-strengthening", ["impact", "stage"]))
    , testCase "an identical redefinition is accepted" $
        withBase $ \base ->
          withImpact base id >>= (@?= (Nothing, []))
    , testCase "two matching specializations disagreeing on a gate conflict in every order" $
        withBase $ \Base {team} -> do
          engX <- def (raw "eng" 1 [rawGate "extra" "before-completion" ["documentation"] ["digest-check"] "none"])
          secX <- def (raw "sec" 1 [rawGate "extra" "before-completion" ["documentation"] ["digest-check"] "human"])
          securityWork <- facts Engineering ["security"] []
          reordered <- def teamRaw {rawSpecializations = [classSpec "security" "sec", kindSpec "engineering" "eng"]}
          let
            conflict = (Just "profile-conflict", ["extra"])
          shape (resolveWith team [engX, secX] [] securityWork) @?= conflict
          shape (resolveWith team [secX, engX] [] securityWork) @?= conflict
          shape (resolveWith reordered [engX, secX] [] securityWork) @?= conflict
          shape (resolveWith reordered [secX, engX] [] securityWork) @?= conflict
    , testCase "two overrides disagreeing on a gate conflict in both orders" $
        withBase $ \Base {team, eng, engineering} -> do
          o1 <- override [rawGate "extra2" "before-completion" ["documentation"] ["digest-check"] "human"]
          o2 <- override [rawGate "extra2" "before-completion" ["documentation", "integration-record"] ["digest-check"] "human"]
          shape (resolveWith team [eng] [o1, o2] engineering) @?= (Just "profile-conflict", ["extra2"])
          shape (resolveWith team [eng] [o2, o1] engineering) @?= (Just "profile-conflict", ["extra2"])
    , testCase "agreeing overrides and a stricter override are accepted" $
        withBase $ \Base {team, eng, engineering} -> do
          o1 <- override [reviewGate {rawGateVerifiers = ["independent-review", "deterministic-command"]}]
          eff <- resolved team [eng] [o1, o1] engineering
          hasLine "gate review stage=before-acceptance artifacts=review-record kinds=* classes=* path-classes=* verifiers=deterministic-command,independent-review approval=human exception-path=false" eff
          hasLine "override 1 approver=\"alice\" rationale=\"stricter for this order\" allows-non-behavioural=inherit" eff
          hasLine "override-gate 1 review stage=before-acceptance artifacts=review-record kinds=* classes=* path-classes=* verifiers=deterministic-command,independent-review approval=human exception-path=false" eff
          hasLine "override 2 approver=\"alice\" rationale=\"stricter for this order\" allows-non-behavioural=inherit" eff
    , testCase "an override weaker than the default is weakens-gate" $
        withBase $ \Base {team, eng, engineering} -> do
          o <- override [reviewGate {rawGateApproval = "supervisor"}]
          shape (resolveWith team [eng] [o] engineering) @?= (Just "weakens-gate", ["review", "approval"])
    , testCase "overrides are human-approved records" $ do
        shape (mkOverride Supervisor "alice" "r" Nothing []) @?= (Just "binding-not-authorized", ["Supervisor"])
        refusedWith "binding-not-authorized" (mkOverride Agent "alice" "r" Nothing [])
        refusedWith "invalid-record" (mkOverride Human "" "r" Nothing [])
        refusedWith "invalid-record" (mkOverride Human "alice" "line\nbreak" Nothing [])
        refusedWith "weakens-universal-invariant" (mkOverride Human "alice" "r" Nothing [rawGate "invariant-x" "before-acceptance" ["review-record"] ["independent-review"] "human"])
        refusedWith "gate-unsatisfiable-before-execution" (mkOverride Human "alice" "r" Nothing [rawGate "x" "before-execution" ["review-record"] ["independent-review"] "human"])
    , testCase "re-permitting the non-behavioural path is weakens-profile; forbidding it is accepted" $
        withBase $ \Base {engineering} -> do
          strict <- def teamRaw {rawAllowsNonBehavioural = Just False}
          permissive <- def (raw "eng" 1 []) {rawAllowsNonBehavioural = Just True}
          forbidding <- def (raw "eng" 1 []) {rawAllowsNonBehavioural = Just False}
          neutral <- def (raw "eng" 1 [])
          secNeutral <- def (raw "sec" 1 [])
          team' <- def teamRaw
          resolveWith strict [permissive, secNeutral] [] engineering @?= Left WeakensNonBehaviouralPolicy
          codeOf (resolveWith strict [permissive, secNeutral] [] engineering) @?= Just "weakens-profile"
          eff <- resolved team' [forbidding] [] engineering
          effectiveAllowsNonBehavioural eff @?= False
          eff' <- resolved strict [neutral] [] engineering
          effectiveAllowsNonBehavioural eff' @?= False
          eff'' <- resolved team' [neutral] [] engineering
          effectiveAllowsNonBehavioural eff'' @?= True
    , testCase "an override cannot re-permit the non-behavioural path" $
        withBase $ \Base {engineering} -> do
          strict <- def teamRaw {rawAllowsNonBehavioural = Just False}
          neutral <- def (raw "eng" 1 [])
          case mkOverride Human "alice" "r" (Just True) [] of
            Left refusal -> assertFailure (show refusal)
            Right o -> refusedWith "weakens-profile" (resolveWith strict [neutral] [o] engineering)
    , testCase "a declared specialization that is not registered is profile-unavailable" $
        withBase $ \Base {team, sec, engineering} ->
          shape (resolveWith team [sec] [] engineering) @?= (Just "profile-unavailable", ["eng"])
    , testCase "a specialization that declares specializations is invalid-profile" $
        withBase $ \Base {team, engineering} -> do
          nested <- def (raw "eng" 1 []) {rawSpecializations = [kindSpec "plan" "x"]}
          refusedWith "invalid-profile" (resolveWith team [nested] [] engineering)
    , testCase "a specialization that does not match the facts contributes nothing" $
        withBase $ \Base {team, eng, sec, investigating} -> do
          eff <- resolved team [eng, sec] [] investigating
          gateIds (effectiveGates eff) @?= ["impact", "inv-only", "review"]
          lacksPrefix "source specialization" eff
    , testCase "the latest registered version of a specialization is used" $
        withBase $ \Base {team, eng, sec, engineering} -> do
          eng2 <- def (raw "eng" 2 [rawGate "v2gate" "before-completion" ["documentation"] ["digest-check"] "none"])
          eff <- resolved team [eng, eng2, sec] [] engineering
          assertBool "v2gate missing" ("v2gate" `L.elem` gateIds (effectiveGates eff))
          L.lookup LayerSpecialization (effectiveSources eff) @?= Just (profileRef h eng2)
          eff' <- resolved team [eng2, eng, sec] [] engineering
          effectiveDigest eff' @?= effectiveDigest eff
    , testCase "every effective Profile has the nine invariants and the baseline first" $
        withBase $ \Base {team, eng, sec, engineering} -> do
          eff <- resolved team [eng, sec] [] engineering
          effectiveInvariants eff @?= [minBound .. maxBound]
          L.length (effectiveInvariants eff) @?= 9
          fmap fst (effectiveSources eff) @?= [LayerBaseline, LayerRepositoryDefault, LayerSpecialization]
          L.take 1 (effectiveSources eff) @?= [(LayerBaseline, profileRef h installationBaseline)]
          L.take 3 (renderedLines eff)
            @?= [ "lockstep-effective-profile 1"
                , "source baseline lockstep-baseline 1 " <> contentDigestText (refDigest (profileRef h installationBaseline))
                , "source repository-default team 1 " <> contentDigestText (refDigest (profileRef h team))
                ]
          hasLine ("source specialization eng 1 " <> contentDigestText (refDigest (profileRef h eng))) eff
          hasLine "invariants single-implementer,scope-and-authorization,durable-attempts,protected-frozen-tests,deterministic-verification,independent-review,bounded-retries,legitimate-commits,human-completion" eff
          hasLine "allows-non-behavioural true" eff
          hasLine "facts kind=engineering classes=- path-classes=- behaviour=behaviour-changing" eff
    , testCase "both matching specializations are sources, by id" $
        withBase $ \Base {team, eng, sec} -> do
          securityWork <- facts Engineering ["security"] [PathSource]
          eff <- resolved team [sec, eng] [] securityWork
          fmap (fmap (profileIdText . refId)) (effectiveSources eff)
            @?= [(LayerBaseline, "lockstep-baseline"), (LayerRepositoryDefault, "team"), (LayerSpecialization, "eng"), (LayerSpecialization, "sec")]
          hasLine "facts kind=engineering classes=security path-classes=source behaviour=behaviour-changing" eff
    , testCase "the effective digest is the hash of the rendering and is deterministic" $
        withBase $ \Base {team, eng, sec, engineering} -> do
          eff <- resolved team [eng, sec] [] engineering
          effectiveDigest eff @?= hashOf (renderEffectiveProfile eff)
          eff' <- resolved team [sec, eng] [] engineering
          effectiveDigest eff' @?= effectiveDigest eff
    ]

-- Facts ----------------------------------------------------------------------

docsOnly :: IO Behaviour
docsOnly =
  maybe (assertFailure "basis refused") (pure . NonBehavioural) (mkNonBehaviouralBasis "typo fix in the guide" "alice")

factsTests :: TestTree
factsTests =
  testGroup
    "facts, trusted origin and non-behavioural work (F6, F7, D-5.6, clarification 4)"
    [ testCase "only a human sets the work facts" $ do
        shape (mkWorkFacts Agent Engineering [] [] BehaviourChanging) @?= (Just "untrusted-classification", ["Agent"])
        refusedWith "untrusted-classification" (mkWorkFacts Supervisor Engineering [] [] BehaviourChanging)
        refusedWith "untrusted-classification" (mkWorkFacts Scheduler Engineering [] [] BehaviourChanging)
        refusedWith "untrusted-classification" (mkWorkFacts DeliveryAdapter Engineering [] [] BehaviourChanging)
        accepted (mkWorkFacts Human Engineering [] [] BehaviourChanging)
    , testCase "a non-behavioural basis needs a rationale and an approver" $ do
        fmap (const ()) (mkNonBehaviouralBasis "" "alice") @?= Nothing
        fmap (const ()) (mkNonBehaviouralBasis "why" "") @?= Nothing
        fmap (const ()) (mkNonBehaviouralBasis "a\tb" "alice") @?= Nothing
        fmap (const ()) (mkNonBehaviouralBasis "why" "alice") @?= Just ()
    , testCase "non-behavioural work must be declared docs-only" $ do
        nb <- docsOnly
        refusedWith "non-behavioural-refused" (mkWorkFacts Human Engineering [] [] nb)
        refusedWith "non-behavioural-refused" (mkWorkFacts Human Engineering [] [PathDocs, PathSource] nb)
        refusedWith "non-behavioural-refused" (mkWorkFacts Human Engineering [] [PathTests] nb)
        accepted (mkWorkFacts Human Engineering [] [PathDocs] nb)
    , testCase "a Profile that forbids the path refuses non-behavioural work" $
        withBase $ \Base {eng, sec} -> do
          nb <- docsOnly
          strict <- def teamRaw {rawAllowsNonBehavioural = Just False}
          case mkWorkFacts Human Engineering [] [PathDocs] nb of
            Left refusal -> assertFailure (show refusal)
            Right f -> refusedWith "non-behavioural-refused" (resolveWith strict [eng, sec] [] f)
    , testCase "permitted non-behavioural work does not require frozen tests, and is checked against observed paths" $
        withBase $ \Base {team, eng, sec} -> do
          nb <- docsOnly
          case mkWorkFacts Human Engineering [] [PathDocs] nb of
            Left refusal -> assertFailure (show refusal)
            Right f -> do
              eff <- resolved team [eng, sec] [] f
              hasLine "facts kind=engineering classes=- path-classes=docs behaviour=non-behavioural" eff
              hasLine "non-behavioural-basis rationale=\"typo fix in the guide\" approver=\"alice\"" eff
              b <- bound Human wo1 eff []
              requiresFrozenTests b @?= False
              checkObservedPaths b [PathDocs] @?= Right ()
              checkObservedPaths b [] @?= Right ()
              checkObservedPaths b [PathDocs, PathSource] @?= Left (NonBehaviouralViolated [PathSource])
              refusedWith "non-behavioural-violated" (checkObservedPaths b [PathTests])
    , testCase "behaviour-changing work requires frozen tests and has no path restriction" $
        withBase $ \Base {team, eng, sec, engineering} -> do
          eff <- resolved team [eng, sec] [] engineering
          b <- bound Human wo1 eff []
          requiresFrozenTests b @?= True
          checkObservedPaths b [PathSource, PathBuild] @?= Right ()
    , testCase "applicability by kind, class and path class" $ do
        d <-
          def $
            raw
              "p"
              1
              [ (rawGate "g" "before-completion" ["documentation"] ["digest-check"] "none")
                  { rawGateKinds = Just ["engineering"]
                  , rawGateClasses = Just ["security"]
                  , rawGatePathClasses = Just ["source"]
                  }
              ]
        g <- maybe (assertFailure "gate missing") pure (L.find ((== "g") . gateIdText . gateId) (definitionGates d))
        let
          applies kind tags paths = facts kind tags paths >>= \f -> pure (gateApplies f g)
        applies Engineering ["security"] [PathSource] >>= (@?= True)
        applies Engineering ["security", "bug-fix"] [PathDocs, PathSource] >>= (@?= True)
        applies Engineering ["security"] [] >>= (@?= True)
        applies Investigate ["security"] [PathSource] >>= (@?= False)
        applies Engineering [] [PathSource] >>= (@?= False)
        applies Engineering ["security"] [PathDocs] >>= (@?= False)
    ]

-- Exceptions -----------------------------------------------------------------

bound :: Principal -> WorkOrderId -> EffectiveProfile -> [ExceptionReceipt] -> IO ProfileBinding
bound principal wo eff receipts =
  either (\refusal -> assertFailure ("binding refused: " <> show refusal)) pure (bindProfile h principal wo "alice" eff receipts)

receipt :: ExceptionTarget -> T.Text -> ContentDigest -> IO ExceptionReceipt
receipt target gate digest = do
  g <- named mkGateId gate
  either (\refusal -> assertFailure ("receipt refused: " <> show refusal)) pure (mkExceptionReceipt Human target g "accepted risk" "alice" t0 digest)

unit :: WorkUnitId -> WorkOrderId -> AdmittedWorkUnit
unit u wo =
  AdmittedWorkUnit
    { admittedRequest =
        WorkUnitRequest
          { wuId = u
          , wuRepository = RepositoryId (uuidFromWords 9 1)
          , wuTicket = TicketId (uuidFromWords 9 2)
          , wuWorkOrder = wo
          , wuPlanRef = Nothing
          }
    , admittedEngineer = EngineerId (uuidFromWords 9 3)
    }

exceptionTests :: TestTree
exceptionTests =
  testGroup
    "exceptions (F8, D-5.4)"
    [ testCase "a human receipt for an applicable gate with an exception path excepts it" $
        withBase $ \Base {team, eng, sec, investigating} -> do
          eff <- resolved team [eng, sec] [] investigating
          r <- receipt (ForWorkOrder wo1) "inv-only" (effectiveDigest eff)
          b <- bound Human wo1 eff [r]
          bindingExceptions b @?= [r]
          g <- gateNamed b "inv-only"
          evaluateGate b [] g @?= GateExcepted r
    , testCase "a strengthened gate loses its exception path" $
        withBase $ \Base {team, eng, sec, engineering} -> do
          eff <- resolved team [eng, sec] [] engineering
          r <- receipt (ForWorkOrder wo1) "impact" (effectiveDigest eff)
          shape (bindProfile h Human wo1 "alice" eff [r]) @?= (Just "exception-not-permitted", ["impact"])
    , testCase "receipts come from a human with a rationale and an approver" $
        withBase $ \Base {otherDigest} -> do
          g <- named mkGateId "impact"
          mkExceptionReceipt Supervisor (ForWorkOrder wo1) g "r" "alice" t0 otherDigest @?= Left ExceptionNotHuman
          refusedWith "exception-not-human" (mkExceptionReceipt Agent (ForWorkOrder wo1) g "r" "alice" t0 otherDigest)
          refusedWith "invalid-record" (mkExceptionReceipt Human (ForWorkOrder wo1) g "" "alice" t0 otherDigest)
          refusedWith "invalid-record" (mkExceptionReceipt Human (ForWorkOrder wo1) g "r" "" t0 otherDigest)
    , testCase "scope, digest, gate, applicability and exception path are checked in that order" $
        withBase $ \Base {team, investigating, otherDigest} -> do
          eff <- resolved team [] [] investigating
          let
            d = effectiveDigest eff
            bindWith target gate digest = receipt target gate digest >>= \r -> pure (shape (bindProfile h Human wo1 "alice" eff [r]))
          bindWith (ForWorkOrder wo2) "nope" otherDigest >>= (@?= (Just "exception-out-of-scope", []))
          bindWith (ForWorkUnit (WorkUnitId (uuidFromWords 0 7))) "inv-only" d >>= (@?= (Just "exception-out-of-scope", []))
          bindWith (ForWorkOrder wo1) "nope" otherDigest >>= (@?= (Just "exception-profile-mismatch", []))
          bindWith (ForWorkOrder wo1) "nope" d >>= (@?= (Just "exception-unknown-gate", ["nope"]))
          bindWith (ForWorkOrder wo1) "impact" d >>= (@?= (Just "exception-not-applicable", ["impact"]))
          bindWith (ForWorkOrder wo1) "review" d >>= (@?= (Just "exception-not-permitted", ["review"]))
          bindWith (ForWorkOrder wo1) "inv-only" d >>= (@?= (Nothing, []))
    , testCase "two receipts for one gate are invalid-record" $
        withBase $ \Base {team, investigating} -> do
          eff <- resolved team [] [] investigating
          r <- receipt (ForWorkOrder wo1) "inv-only" (effectiveDigest eff)
          refusedWith "invalid-record" (bindProfile h Human wo1 "alice" eff [r, r])
    , testCase "a Work Unit receipt is admitted only for a unit of the bound order" $
        withBase $ \Base {team, investigating, otherDigest} -> do
          eff <- resolved team [] [] investigating
          b <- bound Human wo1 eff []
          let
            u1 = WorkUnitId (uuidFromWords 0 11)
            d = effectiveDigest eff
          r <- receipt (ForWorkUnit u1) "inv-only" d
          admitWorkUnitException b (unit u1 wo1) r @?= Right r
          admitWorkUnitException b (unit u1 wo2) r @?= Left ExceptionOutOfScope
          admitWorkUnitException b (unit (WorkUnitId (uuidFromWords 0 12)) wo1) r @?= Left ExceptionOutOfScope
          forOrder <- receipt (ForWorkOrder wo1) "inv-only" d
          admitWorkUnitException b (unit u1 wo1) forOrder @?= Left ExceptionOutOfScope
          noPath <- receipt (ForWorkUnit u1) "review" d
          shape (admitWorkUnitException b (unit u1 wo1) noPath) @?= (Just "exception-not-permitted", ["review"])
          stale <- receipt (ForWorkUnit u1) "inv-only" otherDigest
          admitWorkUnitException b (unit u1 wo1) stale @?= Left ExceptionProfileMismatch
    ]

-- Binding --------------------------------------------------------------------

bindingTests :: TestTree
bindingTests =
  testGroup
    "binding and provenance (F9, D-5.5)"
    [ testCase "a human or the Supervisor binds; the Agent and the Scheduler cannot" $
        withBase $ \Base {team, eng, sec, engineering} -> do
          eff <- resolved team [eng, sec] [] engineering
          accepted (bindProfile h Human wo1 "alice" eff [])
          accepted (bindProfile h Supervisor wo1 "policy" eff [])
          shape (bindProfile h Agent wo1 "alice" eff []) @?= (Just "binding-not-authorized", ["Agent"])
          refusedWith "binding-not-authorized" (bindProfile h Scheduler wo1 "alice" eff [])
          refusedWith "invalid-record" (bindProfile h Human wo1 "" eff [])
    , testCase "the binding records the order, the effective Profile and its digests" $
        withBase $ \Base {team, eng, sec, engineering} -> do
          eff <- resolved team [eng, sec] [] engineering
          b <- bound Human wo1 eff []
          bindingWorkOrder b @?= wo1
          bindingProfile b @?= eff
          bindingDigest b @?= hashOf (renderBinding b)
          T.lines (renderBinding b)
            @?= [ "lockstep-profile-binding 1"
                , "work-order " <> uuidText (uuidFromWords 0 1)
                , "effective-digest " <> contentDigestText (effectiveDigest eff)
                , "approver \"alice\""
                ]
    , testCase "receipts are rendered in the binding" $
        withBase $ \Base {team, investigating} -> do
          eff <- resolved team [] [] investigating
          r <- receipt (ForWorkOrder wo1) "inv-only" (effectiveDigest eff)
          b <- bound Human wo1 eff [r]
          L.drop 4 (T.lines (renderBinding b))
            @?= [ "exception gate=inv-only target=work-order:"
                    <> uuidText (uuidFromWords 0 1)
                    <> " approver=\"alice\" rationale=\"accepted risk\" granted-at=2026-10-18T01:00:00Z profile-digest="
                    <> contentDigestText (effectiveDigest eff)
                ]
    , testCase "provenance reproduces from the definitions and nothing else" $
        withBase $ \Base {team, eng, sec, engineering, otherDigest} -> do
          eff <- resolved team [eng, sec] [] engineering
          b <- bound Human wo1 eff []
          changedTeam <- def teamRaw {rawGates = [reviewGate]}
          verifyProvenance h [team, eng, sec] b @?= True
          verifyProvenance h [eng, team] b @?= True
          verifyProvenance h [changedTeam, eng] b @?= False
          verifyProvenance h [team] b @?= False
          verifyProvenance (Hasher (const otherDigest)) [team, eng] b @?= False
    , testCase "quoted text is escaped" $
        withBase $ \Base {team, eng, engineering} ->
          case mkOverride Human "o'brien \"ob\"" "back\\slash" Nothing [] of
            Left refusal -> assertFailure (show refusal)
            Right o -> do
              eff <- resolved team [eng] [o] engineering
              hasLine "override 1 approver=\"o'brien \\\"ob\\\"\" rationale=\"back\\\\slash\" allows-non-behavioural=inherit" eff
    ]

-- Freshness ------------------------------------------------------------------

boundTeam :: Base -> IO ProfileBinding
boundTeam Base {team, eng, sec, engineering} = do
  eff <- resolved team [eng, sec] [] engineering
  bound Human wo1 eff []

confirm :: ProfileBinding -> [ProfileRef] -> IO ProfileConfirmation
confirm b refs =
  either (assertFailure . show) pure (mkProfileConfirmation Human b refs "alice")

freshnessTests :: TestTree
freshnessTests =
  testGroup
    "mid-flight Profile change (F10, D-5.5)"
    [ testCase "unchanged sources are fresh" $
        withBase $ \base@Base {team, eng, sec} -> do
          b <- boundTeam base
          bindingFreshness b [] (profileRef h team) [profileRef h eng, profileRef h sec] @?= Fresh
    , testCase "a new default version, a new specialization version or another default is profile-changed" $
        withBase $ \base@Base {team, eng} -> do
          b <- boundTeam base
          team2 <- def teamRaw {rawProfileVersion = 2}
          eng2 <- def engRaw {rawProfileVersion = 2}
          other <- def (raw "other" 1 [])
          changed (bindingFreshness b [] (profileRef h team2) [profileRef h eng]) @?= Just ["team"]
          changed (bindingFreshness b [] (profileRef h team) [profileRef h eng2]) @?= Just ["eng"]
          changed (bindingFreshness b [] (profileRef h team2) [profileRef h eng2]) @?= Just ["eng", "team"]
          changed (bindingFreshness b [] (profileRef h other) [profileRef h eng]) @?= Just ["team"]
          changed (bindingFreshness b [] (profileRef h team) []) @?= Just ["eng"]
    , testCase "a human confirmation of exactly the current sources restores freshness" $
        withBase $ \base@Base {team, eng} -> do
          b <- boundTeam base
          team2 <- profileRef h <$> def teamRaw {rawProfileVersion = 2}
          c1 <- confirm b [team2, profileRef h eng]
          c2 <- confirm b [profileRef h eng, team2]
          c3 <- confirm b [profileRef h team, profileRef h eng]
          bindingFreshness b [c1] team2 [profileRef h eng] @?= Fresh
          bindingFreshness b [c2] team2 [profileRef h eng] @?= Fresh
          changed (bindingFreshness b [c3] team2 [profileRef h eng]) @?= Just ["team"]
    , testCase "a confirmation of another binding does not apply" $
        withBase $ \base@Base {team, eng, sec, engineering} -> do
          b <- boundTeam base
          eff <- resolved team [eng, sec] [] engineering
          b2 <- bound Human wo2 eff []
          team2 <- profileRef h <$> def teamRaw {rawProfileVersion = 2}
          other <- confirm b2 [team2, profileRef h eng]
          changed (bindingFreshness b [other] team2 [profileRef h eng]) @?= Just ["team"]
    , testCase "only a human confirms" $
        withBase $ \base -> do
          b <- boundTeam base
          refusedWith "binding-not-authorized" (mkProfileConfirmation Supervisor b [] "alice")
          refusedWith "binding-not-authorized" (mkProfileConfirmation Agent b [] "alice")
          refusedWith "invalid-record" (mkProfileConfirmation Human b [] "")
    , testCase "a frozen Work Unit Contract built from the old binding is unchanged" $
        withBase $ \base@Base {eng} -> do
          b <- boundTeam base
          team2 <- def teamRaw {rawProfileVersion = 2}
          let
            build = mkFrozenContract (ContractId (uuidFromWords 5 5)) (contentDigestText (bindingDigest b)) 2 (acceptanceGateIds b)
          case build of
            Nothing -> assertFailure "contract refused"
            Just fc -> do
              changed (bindingFreshness b [] (profileRef h team2) [profileRef h eng]) @?= Just ["team"]
              frozenGates fc @?= ["review"]
              frozenDigest fc @?= contentDigestText (bindingDigest b)
              build @?= Just fc
    ]

-- Gates ----------------------------------------------------------------------

d1, d2 :: ContentDigest
d1 = hashOf "evidence one"
d2 = hashOf "evidence two"

gateNamed :: ProfileBinding -> T.Text -> IO Gate
gateNamed b name =
  maybe (assertFailure ("no gate " <> T.unpack name)) pure (L.find ((== name) . gateIdText . gateId) (effectiveGates (bindingProfile b)))

gateTests :: TestTree
gateTests =
  testGroup
    "gate evaluation and execution prerequisites (F2, F3, clarification 1)"
    [ testCase "review: satisfied, missing, ambiguous, unverified, needs approval" $
        withBase $ \base -> do
          b <- boundTeam base
          g <- gateNamed b "review"
          let
            ev = GateEvidence ReviewRecord
          evaluateGate b [ev d1 [VerifyIndependentReview] ApprovalHuman] g @?= GateSatisfied
          evaluateGate b [ev d1 [VerifyIndependentReview] ApprovalHuman, ev d1 [VerifyIndependentReview] ApprovalHuman] g @?= GateSatisfied
          evaluateGate b [] g @?= GateBlocked (MissingArtifact ReviewRecord)
          evaluateGate b [GateEvidence Documentation d1 [VerifyIndependentReview] ApprovalHuman] g @?= GateBlocked (MissingArtifact ReviewRecord)
          evaluateGate b [ev d1 [VerifyIndependentReview] ApprovalHuman, ev d2 [VerifyIndependentReview] ApprovalHuman] g
            @?= GateBlocked (AmbiguousEvidence ReviewRecord)
          evaluateGate b [ev d1 [VerifyDigest] ApprovalHuman] g @?= GateBlocked (Unverified ReviewRecord [VerifyIndependentReview])
          evaluateGate b [ev d1 [VerifyIndependentReview] ApprovalSupervisor] g @?= GateBlocked (NeedsApproval ReviewRecord ApprovalHuman)
    , testCase "a gate needing two artifacts reports the first missing one" $
        withBase $ \base -> do
          b <- boundTeam base
          g <- gateNamed b "impact"
          evaluateGate b [GateEvidence ImpactAssessment d1 [VerifyDigest, VerifyHumanInspection] ApprovalHuman] g
            @?= GateBlocked (MissingArtifact Reproduction)
          evaluateGate
            b
            [ GateEvidence ImpactAssessment d1 [VerifyDigest, VerifyHumanInspection] ApprovalHuman
            , GateEvidence Reproduction d2 [VerifyHumanInspection, VerifyDigest] ApprovalHuman
            ]
            g
            @?= GateSatisfied
    , testCase "a gate that does not apply is not applicable" $
        withBase $ \base -> do
          b <- boundTeam base
          g <- gateNamed b "inv-only"
          evaluateGate b [] g @?= GateNotApplicable
    , testCase "execution prerequisites are the applicable before-execution gates only" $
        withBase $ \base -> do
          b <- boundTeam base
          gateIds (executionPrerequisites b) @?= ["impact", "threat"]
          L.all ((== BeforeExecution) . gateStage) (executionPrerequisites b) @?= True
          acceptanceGateIds b @?= ["review"]
    , testCase "an execution prerequisite never needs execution-time evidence" $
        withBase $ \base -> do
          b <- boundTeam base
          let
            preExecution = fmap (\k -> GateEvidence k d1 [minBound .. maxBound] ApprovalHuman) (L.filter producibleBeforeExecution [minBound .. maxBound])
          fmap (evaluateGate b preExecution) (executionPrerequisites b) @?= [GateSatisfied, GateSatisfied]
    ]
