{-# LANGUAGE OverloadedStrings #-}

{- | The pure Master Plan rules (contract C-P6.4 M2, M3, M7, M9): validation
with every problem listed, the cycle's exact edges, digests that depend on the
plan and not on its order, the reconciliation of a new revision, and the
bounded elaboration of a unit.
-}
module Lockstep.Kernel.PlanTest
  ( tests
  , realisticPlan
  , key
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Plan
  ( EdgeKind (..)
  , EffectClass (..)
  , Elaboration (..)
  , ElaborationProblem (..)
  , Envelope (..)
  , PlanContext (..)
  , PlanCriterion (..)
  , PlanDocument (..)
  , PlanEdge (..)
  , PlanMode (..)
  , PlanProblem (..)
  , PlanSource (..)
  , PlanUnit (..)
  , RiskClass (..)
  , Uncertainty (..)
  , UnitKey
  , canonicalPlanText
  , elaborationProblemCode
  , findCycle
  , mkUnitKey
  , planDigestText
  , planProblemCode
  , planProblemText
  , reconcilePlan
  , unitDigestText
  , unitKeyText
  , unitOutcomeCode
  , validateElaboration
  , validatePlan
  )
import Lockstep.Kernel.Task (Priority (..))

-- | A key the test knows is valid; an invalid spelling becomes a key no test uses.
key :: T.Text -> UnitKey
key text =
  fromMaybe (fallback text) (mkUnitKey text)
 where
  fallback _ =
    case mkUnitKey "invalid-key-in-test" of
      Just k -> k
      Nothing -> fallback "x"

prd, arch :: T.Text
prd = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
arch = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

unit :: T.Text -> T.Text -> PlanUnit
unit k kind =
  PlanUnit
    { unitKey = key k
    , unitTitle = "Unit " <> k
    , unitPhase = "P1"
    , unitSubphase = "P1." <> k
    , unitWorkKind = kind
    , unitProfile = "lockstep-feature"
    , unitPriority = Normal
    , unitEffect = LocalOnly
    , unitRisk = RiskNormal
    , unitProvisional = True
    , unitOutputs = ["src/" <> k]
    , unitAcceptance = [PlanCriterion ("The " <> k <> " part does what the PRD says.") ["prd"]]
    , unitNegative = ["A malformed " <> k <> " input is refused."]
    , unitChecks = ["unit tests for " <> k]
    , unitPrerequisites = []
    , unitResources = []
    }

edge :: T.Text -> T.Text -> EdgeKind -> PlanEdge
edge d p =
  PlanEdge (key d) (key p)

-- | A Caesura-shaped greenfield plan: five units, technical and human-acceptance edges.
realisticPlan :: PlanDocument
realisticPlan =
  PlanDocument
    { planTitle = "Caesura: a poem-meter checker"
    , planMode = Greenfield
    , planSources = [PlanSource "prd" prd, PlanSource "architecture" arch]
    , planEnvelope = Envelope False 10 Nothing
    , planUnits =
        [ (unit "core" "greenfield") {unitPriority = High}
        , unit "cli" "feature"
        , unit "render" "feature"
        , unit "docs" "documentation"
        , unit "suite" "feature"
        ]
    , planEdges =
        [ edge "cli" "core" Technical
        , edge "render" "core" Technical
        , edge "docs" "cli" HumanAcceptance
        , edge "suite" "cli" Technical
        , edge "suite" "render" Technical
        ]
    , planUncertainties = [Uncertainty "The PRD says both 'syllables' and 'stresses' decide the meter." ["prd"]]
    }

context :: PlanContext
context =
  PlanContext ["lockstep-feature", "lockstep-bug-fix"]

codes :: Either [PlanProblem] PlanDocument -> [T.Text]
codes result =
  case result of
    Left problems -> L.sort (fmap planProblemCode problems)
    Right _ -> []

refusedWith :: [T.Text] -> PlanDocument -> IO ()
refusedWith expected plan =
  codes (validatePlan context plan) @?= L.sort expected

withUnits :: ([PlanUnit] -> [PlanUnit]) -> PlanDocument -> PlanDocument
withUnits f p =
  p {planUnits = f (planUnits p)}

onUnit :: T.Text -> (PlanUnit -> PlanUnit) -> PlanDocument -> PlanDocument
onUnit k f =
  withUnits (fmap (\u -> if unitKey u == key k then f u else u))

digest :: PlanDocument -> T.Text
digest =
  planDigestText sha256Hasher

unitDigest :: PlanDocument -> T.Text -> Maybe T.Text
unitDigest p k =
  unitDigestText sha256Hasher p (key k)

outcomes :: Maybe PlanDocument -> PlanDocument -> [(T.Text, T.Text)]
outcomes old new =
  [(unitKeyText k, unitOutcomeCode o) | (k, o) <- reconcilePlan sha256Hasher old new]

elaboration :: Elaboration
elaboration =
  Elaboration
    { elaborationPlanDigest = digest realisticPlan
    , elaborationUnit = key "suite"
    , elaborationAcceptance = ["The suite part does what the PRD says.", "It also handles an empty poem."]
    , elaborationNegative = ["A malformed suite input is refused."]
    , elaborationChecks = ["unit tests for suite", "property tests"]
    , elaborationEdges = [(key "cli", Technical), (key "render", Technical)]
    , elaborationEffect = LocalOnly
    , elaborationWorkKind = "feature"
    , elaborationProfile = "lockstep-feature"
    , elaborationSteps = ["write the tests", "write the code"]
    }

elaborationCodes :: Elaboration -> [T.Text]
elaborationCodes e =
  L.sort (fmap elaborationProblemCode (validateElaboration (digest realisticPlan) realisticPlan e))

tests :: TestTree
tests =
  testGroup
    "C-P6.4 the Master Plan (pure)"
    [ testGroup
        "validation (M2)"
        [ testCase "a realistic five-unit plan is valid and comes back unchanged" $
            validatePlan context realisticPlan @?= Right realisticPlan
        , testCase "a cycle is refused with the exact edges that close it, from the smallest key" $ do
            let
              cyclic =
                realisticPlan
                  { planEdges =
                      planEdges realisticPlan
                        <> [edge "core" "suite" Technical]
                  }
            -- core -> suite -> cli -> core (each edge: dependent needs prerequisite).
            validatePlan context cyclic @?= Left [Cycle [(key "cli", key "core"), (key "core", key "suite"), (key "suite", key "cli")]]
        , testCase "findCycle: none in an acyclic graph; a two-unit loop; a self-loop" $ do
            findCycle [(key "b", key "a"), (key "c", key "b")] @?= Nothing
            findCycle [(key "b", key "a"), (key "a", key "b")] @?= Just [(key "a", key "b"), (key "b", key "a")]
            findCycle [(key "z", key "z")] @?= Just [(key "z", key "z")]
        , testCase "an edge to a unit the plan does not have is unknown-unit (a missing dependency)" $
            refusedWith ["unknown-unit"] realisticPlan {planEdges = planEdges realisticPlan <> [edge "suite" "parser" Technical]}
        , testCase "every structural problem is listed, not only the first" $
            refusedWith
              ["duplicate-unit", "self-edge", "duplicate-edge", "no-acceptance", "unknown-citation"]
              ( onUnit "docs" (\u -> u {unitAcceptance = []})
                  . onUnit "render" (\u -> u {unitAcceptance = [PlanCriterion "Renders." ["the-wiki"]]})
                  $ realisticPlan
                    { planUnits = planUnits realisticPlan <> [unit "cli" "feature"]
                    , planEdges = planEdges realisticPlan <> [edge "cli" "cli" Technical, edge "cli" "core" HumanAcceptance]
                    }
              )
        , testCase "sources: none, a malformed digest, a name twice" $ do
            -- Each unknown name is one problem, however often it is cited.
            refusedWith ["no-sources", "unknown-citation"] realisticPlan {planSources = []}
            refusedWith ["invalid-source-digest"] realisticPlan {planSources = [PlanSource "prd" "ABC", PlanSource "architecture" arch]}
            refusedWith ["duplicate-source"] realisticPlan {planSources = planSources realisticPlan <> [PlanSource "prd" arch]}
        , testCase "an uncertainty citing an unknown source is unknown-citation; uncertainties never refuse otherwise" $ do
            refusedWith ["unknown-citation"] realisticPlan {planUncertainties = [Uncertainty "Which meter?" ["chat"]]}
            validatePlan context realisticPlan {planUncertainties = [Uncertainty "a" [], Uncertainty "b" ["prd", "architecture"]]}
              @?= Right realisticPlan {planUncertainties = [Uncertainty "a" [], Uncertainty "b" ["prd", "architecture"]]}
        , testCase "Phase 6 authorizes no external effect: in the envelope or on a unit" $ do
            refusedWith ["external-effect-not-authorized"] realisticPlan {planEnvelope = Envelope True 10 Nothing}
            refusedWith ["external-effect-not-authorized"] (onUnit "cli" (\u -> u {unitEffect = ExternalEffect}) realisticPlan)
        , testCase "the envelope bounds the plan: too many units, a nonsensical envelope" $ do
            refusedWith ["too-many-units"] realisticPlan {planEnvelope = Envelope False 4 Nothing}
            refusedWith ["invalid-envelope"] realisticPlan {planEnvelope = Envelope False 0 Nothing}
            refusedWith ["invalid-envelope"] realisticPlan {planEnvelope = Envelope False 10 (Just 0)}
        , testCase "an unknown work kind or profile, and an empty plan" $ do
            refusedWith ["unknown-work-kind"] (onUnit "cli" (\u -> u {unitWorkKind = "magic"}) realisticPlan)
            refusedWith ["unknown-profile"] (onUnit "cli" (\u -> u {unitProfile = "lockstep-anything-goes"}) realisticPlan)
            refusedWith ["empty-plan"] realisticPlan {planUnits = [], planEdges = []}
        , testCase "a greenfield plan cannot hold a bug fix; a brownfield plan cannot hold a greenfield build" $ do
            refusedWith ["incompatible-mode"] (onUnit "cli" (\u -> u {unitWorkKind = "bug-fix"}) realisticPlan)
            refusedWith ["incompatible-mode"] realisticPlan {planMode = Brownfield}
            validatePlan context (onUnit "core" (\u -> u {unitWorkKind = "feature"}) realisticPlan {planMode = Brownfield})
              @?= Right (onUnit "core" (\u -> u {unitWorkKind = "feature"}) realisticPlan {planMode = Brownfield})
        , testCase "titles: an empty plan title or unit title is refused" $ do
            refusedWith ["invalid-title"] realisticPlan {planTitle = "  "}
            refusedWith ["invalid-title"] (onUnit "cli" (\u -> u {unitTitle = ""}) realisticPlan)
        , testCase "a problem in words names what it concerns; a cycle by its edges in order" $ do
            planProblemText (Cycle [(key "cli", key "core"), (key "core", key "suite"), (key "suite", key "cli")])
              @?= "cycle: cli needs core, core needs suite, suite needs cli"
            planProblemText (UnknownUnit (key "parser")) @?= "unknown-unit: parser"
            planProblemText (UnknownCitation "the-wiki") @?= "unknown-citation: the-wiki"
            planProblemText (TooManyUnits 5 4) @?= "too-many-units: 5 units, at most 4"
            planProblemText EmptyPlan @?= "empty-plan"
        , testCase "every problem has its contract code" $
            fmap
              planProblemCode
              [ EmptyPlan
              , DuplicateUnit (key "a")
              , UnknownUnit (key "a")
              , SelfEdge (key "a")
              , DuplicateEdge (key "a") (key "b")
              , Cycle []
              , NoAcceptance (key "a")
              , UnknownCitation "x"
              , NoSources
              , InvalidSourceDigest "x"
              , DuplicateSource "x"
              , ExternalEffectNotAuthorized Nothing
              , TooManyUnits 2 1
              , InvalidEnvelope
              , UnknownWorkKind (key "a") "x"
              , UnknownProfile (key "a") "x"
              , IncompatibleMode (key "a")
              , InvalidTitle Nothing
              ]
              @?= [ "empty-plan"
                  , "duplicate-unit"
                  , "unknown-unit"
                  , "self-edge"
                  , "duplicate-edge"
                  , "cycle"
                  , "no-acceptance"
                  , "unknown-citation"
                  , "no-sources"
                  , "invalid-source-digest"
                  , "duplicate-source"
                  , "external-effect-not-authorized"
                  , "too-many-units"
                  , "invalid-envelope"
                  , "unknown-work-kind"
                  , "unknown-profile"
                  , "incompatible-mode"
                  , "invalid-title"
                  ]
        ]
    , testGroup
        "digests (M3)"
        [ testCase "the digest is 64 hex characters, and the same for the same plan in any order" $ do
            T.length (digest realisticPlan) @?= 64
            assertBool "not hex" (T.all (`L.elem` ("0123456789abcdef" :: [Char])) (digest realisticPlan))
            digest realisticPlan {planUnits = L.reverse (planUnits realisticPlan), planEdges = L.reverse (planEdges realisticPlan)} @?= digest realisticPlan
            canonicalPlanText realisticPlan {planUnits = L.reverse (planUnits realisticPlan)} @?= canonicalPlanText realisticPlan
        , testCase "every frozen field changes the digest (DG-08 §1.1)" $ do
            let
              changes =
                [ ("title", realisticPlan {planTitle = "Caesura 2"})
                , ("source digest", realisticPlan {planSources = [PlanSource "prd" arch, PlanSource "architecture" arch]})
                , ("envelope", realisticPlan {planEnvelope = Envelope False 9 Nothing})
                , ("token budget", realisticPlan {planEnvelope = Envelope False 10 (Just 5000)})
                , ("unit title", onUnit "cli" (\u -> u {unitTitle = "Command line"}) realisticPlan)
                , ("phase", onUnit "cli" (\u -> u {unitPhase = "P2"}) realisticPlan)
                , ("acceptance", onUnit "cli" (\u -> u {unitAcceptance = [PlanCriterion "Other." ["prd"]]}) realisticPlan)
                , ("citation", onUnit "cli" (\u -> u {unitAcceptance = [PlanCriterion "The cli part does what the PRD says." ["architecture"]]}) realisticPlan)
                , ("negative", onUnit "cli" (\u -> u {unitNegative = []}) realisticPlan)
                , ("checks", onUnit "cli" (\u -> u {unitChecks = []}) realisticPlan)
                , ("priority", onUnit "cli" (\u -> u {unitPriority = Low}) realisticPlan)
                , ("profile", onUnit "cli" (\u -> u {unitProfile = "lockstep-bug-fix"}) realisticPlan)
                , ("work kind", onUnit "cli" (\u -> u {unitWorkKind = "refactor"}) realisticPlan)
                , ("risk", onUnit "cli" (\u -> u {unitRisk = RiskHigh}) realisticPlan)
                , ("provisional", onUnit "cli" (\u -> u {unitProvisional = False}) realisticPlan)
                , ("outputs", onUnit "cli" (\u -> u {unitOutputs = []}) realisticPlan)
                , ("edge kind", realisticPlan {planEdges = edge "cli" "core" HumanAcceptance : L.drop 1 (planEdges realisticPlan)})
                , ("uncertainty", realisticPlan {planUncertainties = []})
                ]
            traverse_ (\(name, p) -> assertBool ("unchanged digest after a change of " <> name) (digest p /= digest realisticPlan)) changes
        , testCase "a unit's digest covers its fields, its incoming edges and its cited sources, not other units" $ do
            assertBool "no digest for a unit of the plan" (isJust (unitDigest realisticPlan "cli"))
            unitDigest realisticPlan "parser" @?= Nothing
            unitDigest (onUnit "render" (\u -> u {unitTitle = "Draw"}) realisticPlan) "cli" @?= unitDigest realisticPlan "cli"
            assertBool "edge kind" (unitDigest realisticPlan {planEdges = edge "cli" "core" HumanAcceptance : L.drop 1 (planEdges realisticPlan)} "cli" /= unitDigest realisticPlan "cli")
            assertBool "cited source" (unitDigest realisticPlan {planSources = [PlanSource "prd" arch, PlanSource "architecture" arch]} "cli" /= unitDigest realisticPlan "cli")
            -- No unit cites the architecture: a new architecture digest changes no unit.
            unitDigest realisticPlan {planSources = [PlanSource "prd" prd, PlanSource "architecture" prd]} "cli" @?= unitDigest realisticPlan "cli"
        ]
    , testGroup
        "reconciliation (M7)"
        [ testCase "a first revision: every unit is added" $
            outcomes Nothing realisticPlan @?= [("cli", "added"), ("core", "added"), ("docs", "added"), ("render", "added"), ("suite", "added")]
        , testCase "the same plan again: every unit is kept" $
            outcomes (Just realisticPlan) realisticPlan @?= [("cli", "kept"), ("core", "kept"), ("docs", "kept"), ("render", "kept"), ("suite", "kept")]
        , testCase "a changed unit invalidates its technical descendants only; a removed unit is withdrawn; a new one added" $ do
            let
              old = realisticPlan {planUnits = planUnits realisticPlan <> [unit "legacy" "feature"]}
              new =
                onUnit "cli" (\u -> u {unitTitle = "Command line"}) $
                  realisticPlan {planUnits = planUnits realisticPlan <> [unit "lint" "feature"]}
            -- docs needs cli only for the owner's acceptance: kept. suite needs cli technically: invalidated.
            outcomes (Just old) new @?= [("cli", "changed"), ("core", "kept"), ("docs", "kept"), ("legacy", "withdrawn"), ("lint", "added"), ("render", "kept"), ("suite", "invalidated")]
        , testCase "a unit whose own incoming edges change is changed, not merely invalidated" $
            outcomes (Just realisticPlan) realisticPlan {planEdges = [e | e <- planEdges realisticPlan, edgePrerequisite e /= key "render"]}
              @?= [("cli", "kept"), ("core", "kept"), ("docs", "kept"), ("render", "kept"), ("suite", "changed")]
        , testCase "a new PRD digest changes every unit citing it, and so invalidates nothing else twice" $
            outcomes (Just realisticPlan) realisticPlan {planSources = [PlanSource "prd" arch, PlanSource "architecture" arch]}
              @?= [("cli", "changed"), ("core", "changed"), ("docs", "changed"), ("render", "changed"), ("suite", "changed")]
        , testCase "an outcome's code" $
            fmap unitOutcomeCode [minBound .. maxBound] @?= ["added", "kept", "changed", "invalidated", "withdrawn"]
        ]
    , testGroup
        "bounded elaboration (M9)"
        [ testCase "an elaboration that adds criteria, checks and steps is inside the boundary" $
            elaborationCodes elaboration @?= []
        , testCase "each change of an approved field is refused with its code" $ do
            elaborationCodes elaboration {elaborationPlanDigest = digest realisticPlan {planTitle = "x"}} @?= ["wrong-revision"]
            elaborationCodes elaboration {elaborationUnit = key "parser"} @?= ["unknown-unit"]
            elaborationCodes elaboration {elaborationAcceptance = ["It also handles an empty poem."]} @?= ["weakened-acceptance"]
            elaborationCodes elaboration {elaborationAcceptance = ["The suite part does roughly what the PRD says."]} @?= ["weakened-acceptance"]
            elaborationCodes elaboration {elaborationNegative = []} @?= ["removed-negative"]
            elaborationCodes elaboration {elaborationChecks = ["property tests"]} @?= ["removed-check"]
            elaborationCodes elaboration {elaborationEdges = [(key "cli", Technical)]} @?= ["changed-edges"]
            elaborationCodes elaboration {elaborationEdges = [(key "cli", Technical), (key "render", HumanAcceptance)]} @?= ["changed-edges"]
            elaborationCodes elaboration {elaborationEffect = ExternalEffect} @?= ["changed-effect"]
            elaborationCodes elaboration {elaborationWorkKind = "refactor"} @?= ["changed-work-kind"]
            elaborationCodes elaboration {elaborationProfile = "lockstep-bug-fix"} @?= ["changed-profile"]
        , testCase "several violations are all listed" $
            elaborationCodes elaboration {elaborationNegative = [], elaborationEffect = ExternalEffect, elaborationProfile = "x"}
              @?= ["changed-effect", "changed-profile", "removed-negative"]
        , testCase "every elaboration problem has its contract code" $
            fmap elaborationProblemCode [WrongRevision, ElaborationUnknownUnit, WeakenedAcceptance "x", RemovedNegative "x", RemovedCheck "x", ChangedEdges, ChangedEffect, ChangedWorkKind, ChangedProfile]
              @?= ["wrong-revision", "unknown-unit", "weakened-acceptance", "removed-negative", "removed-check", "changed-edges", "changed-effect", "changed-work-kind", "changed-profile"]
        ]
    ]
