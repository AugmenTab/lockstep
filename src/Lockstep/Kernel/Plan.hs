{- | The Master Plan (contract C-P6.4): a versioned graph of Work Units with
typed edges, citations to its sources and an authority envelope. Pure: the
document's validation (M2), its canonical rendering and digests (M3), the
reconciliation of a new revision with the effective one (M7) and the check of a
unit's just-in-time elaboration (M9). The plan is the owner's; nothing here
approves, dispatches or edits one.
-}
module Lockstep.Kernel.Plan
  ( -- * The document
    PlanDocument (..)
  , PlanSource (..)
  , Envelope (..)
  , PlanUnit (..)
  , PlanCriterion (..)
  , Uncertainty (..)
  , PlanEdge (..)
  , UnitKey
  , mkUnitKey
  , unitKeyText

    -- * Its vocabularies
  , PlanMode (..)
  , planModeCode
  , parsePlanMode
  , WorkKind (..)
  , workKindCode
  , parseWorkKind
  , EdgeKind (..)
  , edgeKindCode
  , parseEdgeKind
  , EffectClass (..)
  , effectClassCode
  , parseEffectClass
  , RiskClass (..)
  , riskClassCode
  , parseRiskClass

    -- * Validation (M2)
  , PlanContext (..)
  , PlanProblem (..)
  , planProblemCode
  , planProblemText
  , validatePlan
  , findCycle

    -- * Digests (M3)
  , canonicalPlanText
  , planDigestText
  , unitDigestText

    -- * Reconciliation (M7)
  , UnitOutcome (..)
  , unitOutcomeCode
  , reconcilePlan

    -- * Elaboration (M9)
  , Elaboration (..)
  , ElaborationProblem (..)
  , elaborationProblemCode
  , validateElaboration
  ) where

import Data.Char qualified as Char
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Enum (parseEnumText)
import Lockstep.Kernel.Profile (Hasher)
import Lockstep.Kernel.Task (Priority)

-- The document ----------------------------------------------------------------------

-- | A unit's stable key: 1–64 characters of lowercase letters, digits, @-@, @.@ and @_@, starting with a letter or digit.
newtype UnitKey
  = UnitKey T.Text
  deriving (Eq, Ord, Show)

mkUnitKey :: T.Text -> Maybe UnitKey
mkUnitKey text =
  case T.uncons text of
    Just (first, _)
      | T.length text <= 64
      , Char.isAsciiLower first || Char.isDigit first
      , T.all (\c -> Char.isAsciiLower c || Char.isDigit c || c == '-' || c == '.' || c == '_') text ->
          Just (UnitKey text)
    _ -> Nothing

unitKeyText :: UnitKey -> T.Text
unitKeyText (UnitKey t) =
  t

-- | A source the plan answers to: its name and the SHA-256 of its text.
data PlanSource
  = PlanSource
  { sourceName :: T.Text
  , sourceDigest :: T.Text
  }
  deriving (Eq, Show)

-- | What the plan may do: Phase 6 authorizes no external effect.
data Envelope
  = Envelope
  { envelopeExternalEffects :: Bool
  , envelopeMaxUnits :: Int
  , envelopeTokenBudget :: Maybe Integer
  }
  deriving (Eq, Show)

-- | An acceptance criterion and the sources it comes from.
data PlanCriterion
  = PlanCriterion
  { planCriterionText :: T.Text
  , planCriterionCites :: [T.Text]
  }
  deriving (Eq, Show)

-- | A question or contradiction the owner must see (M8); it never refuses a plan.
data Uncertainty
  = Uncertainty
  { uncertaintyText :: T.Text
  , uncertaintyCites :: [T.Text]
  }
  deriving (Eq, Show)

data PlanUnit
  = PlanUnit
  { unitKey :: UnitKey
  , unitTitle :: T.Text
  , unitPhase :: T.Text
  , unitSubphase :: T.Text
  , unitWorkKind :: T.Text
  , unitProfile :: T.Text
  , unitPriority :: Priority
  , unitEffect :: EffectClass
  , unitRisk :: RiskClass
  , unitProvisional :: Bool
  , unitOutputs :: [T.Text]
  , unitAcceptance :: [PlanCriterion]
  , unitNegative :: [T.Text]
  , unitChecks :: [T.Text]
  , unitPrerequisites :: [T.Text]
  , unitResources :: [T.Text]
  }
  deriving (Eq, Show)

-- | @dependent@ needs @prerequisite@, in the way its kind says.
data PlanEdge
  = PlanEdge
  { edgeDependent :: UnitKey
  , edgePrerequisite :: UnitKey
  , edgeKind :: EdgeKind
  }
  deriving (Eq, Show)

data PlanDocument
  = PlanDocument
  { planTitle :: T.Text
  , planMode :: PlanMode
  , planSources :: [PlanSource]
  , planEnvelope :: Envelope
  , planUnits :: [PlanUnit]
  , planEdges :: [PlanEdge]
  , planUncertainties :: [Uncertainty]
  }
  deriving (Eq, Show)

-- Vocabularies ----------------------------------------------------------------------

data PlanMode
  = Greenfield
  | Brownfield
  deriving (Eq, Show, Enum, Bounded)

planModeCode :: PlanMode -> T.Text
planModeCode m =
  T.pack $
    case m of
      Greenfield -> "greenfield"
      Brownfield -> "brownfield"

parsePlanMode :: T.Text -> Maybe PlanMode
parsePlanMode =
  parseEnumText planModeCode

-- | The kinds of engineering work a unit may be (P6.6 binds each to its checks).
data WorkKind
  = BugFix
  | Feature
  | GreenfieldBuild
  | Refactor
  | Documentation
  deriving (Eq, Show, Enum, Bounded)

workKindCode :: WorkKind -> T.Text
workKindCode k =
  T.pack $
    case k of
      BugFix -> "bug-fix"
      Feature -> "feature"
      GreenfieldBuild -> "greenfield"
      Refactor -> "refactor"
      Documentation -> "documentation"

parseWorkKind :: T.Text -> Maybe WorkKind
parseWorkKind =
  parseEnumText workKindCode

{- | How a dependent needs its prerequisite: @technical@ — its technical
completion (P6.7 may satisfy it provisionally); @human-acceptance@ — the
owner's Done; @external@ — something outside Lockstep, which only a person can
record.
-}
data EdgeKind
  = Technical
  | HumanAcceptance
  | External
  deriving (Eq, Ord, Show, Enum, Bounded)

edgeKindCode :: EdgeKind -> T.Text
edgeKindCode k =
  T.pack $
    case k of
      Technical -> "technical"
      HumanAcceptance -> "human-acceptance"
      External -> "external"

parseEdgeKind :: T.Text -> Maybe EdgeKind
parseEdgeKind =
  parseEnumText edgeKindCode

data EffectClass
  = LocalOnly
  | ExternalEffect
  deriving (Eq, Show, Enum, Bounded)

effectClassCode :: EffectClass -> T.Text
effectClassCode e =
  T.pack $
    case e of
      LocalOnly -> "local-only"
      ExternalEffect -> "external"

parseEffectClass :: T.Text -> Maybe EffectClass
parseEffectClass =
  parseEnumText effectClassCode

data RiskClass
  = RiskLow
  | RiskNormal
  | RiskHigh
  deriving (Eq, Show, Enum, Bounded)

riskClassCode :: RiskClass -> T.Text
riskClassCode r =
  T.pack $
    case r of
      RiskLow -> "low"
      RiskNormal -> "normal"
      RiskHigh -> "high"

parseRiskClass :: T.Text -> Maybe RiskClass
parseRiskClass =
  parseEnumText riskClassCode

-- Validation ------------------------------------------------------------------------

-- | What the validation needs from outside the document: the profiles the catalog has.
newtype PlanContext
  = PlanContext
  { contextProfiles :: [T.Text]
  }
  deriving (Eq, Show)

data PlanProblem
  = EmptyPlan
  | DuplicateUnit UnitKey
  | UnknownUnit UnitKey
  | SelfEdge UnitKey
  | DuplicateEdge UnitKey UnitKey
  | Cycle [(UnitKey, UnitKey)]
  | NoAcceptance UnitKey
  | UnknownCitation T.Text
  | NoSources
  | InvalidSourceDigest T.Text
  | DuplicateSource T.Text
  | ExternalEffectNotAuthorized (Maybe UnitKey)
  | TooManyUnits Int Int
  | InvalidEnvelope
  | UnknownWorkKind UnitKey T.Text
  | UnknownProfile UnitKey T.Text
  | IncompatibleMode UnitKey
  | InvalidTitle (Maybe UnitKey)
  deriving (Eq, Show)

planProblemCode :: PlanProblem -> T.Text
planProblemCode _ =
  T.empty

{- | The problem in words: its code, then what it concerns (a cycle as its
edges in order, "a needs b").
-}
planProblemText :: PlanProblem -> T.Text
planProblemText _ =
  T.empty

{- | Every problem of the document, or the document unchanged. Problems are
listed in a fixed order (sources, envelope, units, edges, cycle).
-}
validatePlan :: PlanContext -> PlanDocument -> Either [PlanProblem] PlanDocument
validatePlan _ =
  Right

{- | One cycle of the edges, as the edges that close it in order (each edge is
@(dependent, prerequisite)@ and the next edge starts at the previous one's
prerequisite), starting from the smallest key on it; nothing when acyclic.
-}
findCycle :: [(UnitKey, UnitKey)] -> Maybe [(UnitKey, UnitKey)]
findCycle _ =
  Nothing

-- Digests ---------------------------------------------------------------------------

-- | The canonical text of a document: the same for the same plan whatever the order of its units and edges.
canonicalPlanText :: PlanDocument -> T.Text
canonicalPlanText _ =
  T.empty

planDigestText :: Hasher -> PlanDocument -> T.Text
planDigestText _ _ =
  T.empty

-- | A unit's digest: its fields, its incoming edges and the digests of the sources it cites.
unitDigestText :: Hasher -> PlanDocument -> UnitKey -> Maybe T.Text
unitDigestText _ _ _ =
  Nothing

-- Reconciliation --------------------------------------------------------------------

data UnitOutcome
  = UnitAdded
  | UnitKept
  | UnitChanged
  | UnitInvalidated
  | UnitWithdrawn
  deriving (Eq, Show, Enum, Bounded)

unitOutcomeCode :: UnitOutcome -> T.Text
unitOutcomeCode o =
  T.pack $
    case o of
      UnitAdded -> "added"
      UnitKept -> "kept"
      UnitChanged -> "changed"
      UnitInvalidated -> "invalidated"
      UnitWithdrawn -> "withdrawn"

{- | Each unit of the new revision, and each withdrawn unit of the old, with its
outcome, sorted by key. A unit that depends transitively over technical edges
(of the new revision) on a changed unit is invalidated, unless it is itself
changed.
-}
reconcilePlan :: Hasher -> Maybe PlanDocument -> PlanDocument -> [(UnitKey, UnitOutcome)]
reconcilePlan _ _ _ =
  []

-- Elaboration -----------------------------------------------------------------------

-- | A unit's detailed Contract as far as the plan is concerned.
data Elaboration
  = Elaboration
  { elaborationPlanDigest :: T.Text
  , elaborationUnit :: UnitKey
  , elaborationAcceptance :: [T.Text]
  , elaborationNegative :: [T.Text]
  , elaborationChecks :: [T.Text]
  , elaborationEdges :: [(UnitKey, EdgeKind)]
  , elaborationEffect :: EffectClass
  , elaborationWorkKind :: T.Text
  , elaborationProfile :: T.Text
  , elaborationSteps :: [T.Text]
  }
  deriving (Eq, Show)

data ElaborationProblem
  = WrongRevision
  | ElaborationUnknownUnit
  | WeakenedAcceptance T.Text
  | RemovedNegative T.Text
  | RemovedCheck T.Text
  | ChangedEdges
  | ChangedEffect
  | ChangedWorkKind
  | ChangedProfile
  deriving (Eq, Show)

elaborationProblemCode :: ElaborationProblem -> T.Text
elaborationProblemCode _ =
  T.empty

{- | The elaboration's problems against the effective revision (its digest and
document); none means it stays inside the approved boundary.
-}
validateElaboration :: T.Text -> PlanDocument -> Elaboration -> [ElaborationProblem]
validateElaboration _ _ _ =
  []
