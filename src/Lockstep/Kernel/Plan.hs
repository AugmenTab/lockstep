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

import Control.Applicative ((<|>))
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Enum (parseEnumText)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Task (Priority, priorityCode)

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
planProblemCode p =
  T.pack $
    case p of
      EmptyPlan -> "empty-plan"
      DuplicateUnit _ -> "duplicate-unit"
      UnknownUnit _ -> "unknown-unit"
      SelfEdge _ -> "self-edge"
      DuplicateEdge _ _ -> "duplicate-edge"
      Cycle _ -> "cycle"
      NoAcceptance _ -> "no-acceptance"
      UnknownCitation _ -> "unknown-citation"
      NoSources -> "no-sources"
      InvalidSourceDigest _ -> "invalid-source-digest"
      DuplicateSource _ -> "duplicate-source"
      ExternalEffectNotAuthorized _ -> "external-effect-not-authorized"
      TooManyUnits _ _ -> "too-many-units"
      InvalidEnvelope -> "invalid-envelope"
      UnknownWorkKind _ _ -> "unknown-work-kind"
      UnknownProfile _ _ -> "unknown-profile"
      IncompatibleMode _ -> "incompatible-mode"
      InvalidTitle _ -> "invalid-title"

{- | The problem in words: its code, then what it concerns (a cycle as its
edges in order, "a needs b").
-}
planProblemText :: PlanProblem -> T.Text
planProblemText p =
  case detail of
    Nothing -> planProblemCode p
    Just d -> planProblemCode p <> T.pack ": " <> d
 where
  needs (a, b) = unitKeyText a <> T.pack " needs " <> unitKeyText b
  detail =
    case p of
      EmptyPlan -> Nothing
      DuplicateUnit u -> Just (unitKeyText u)
      UnknownUnit u -> Just (unitKeyText u)
      SelfEdge u -> Just (unitKeyText u)
      DuplicateEdge a b -> Just (needs (a, b))
      Cycle edges -> Just (T.intercalate (T.pack ", ") (fmap needs edges))
      NoAcceptance u -> Just (unitKeyText u)
      UnknownCitation name -> Just name
      NoSources -> Nothing
      InvalidSourceDigest name -> Just name
      DuplicateSource name -> Just name
      ExternalEffectNotAuthorized u -> fmap unitKeyText u
      TooManyUnits n m -> Just (T.pack (show n) <> T.pack " units, at most " <> T.pack (show m))
      InvalidEnvelope -> Nothing
      UnknownWorkKind u kind -> Just (unitKeyText u <> T.pack " (" <> kind <> T.pack ")")
      UnknownProfile u profile -> Just (unitKeyText u <> T.pack " (" <> profile <> T.pack ")")
      IncompatibleMode u -> Just (unitKeyText u)
      InvalidTitle u -> fmap unitKeyText u

{- | Every problem of the document, or the document unchanged. Problems are
listed in a fixed order (title, sources, envelope, units, citations, edges,
cycle).
-}
validatePlan :: PlanContext -> PlanDocument -> Either [PlanProblem] PlanDocument
validatePlan context document =
  case problems of
    [] -> Right document
    _ -> Left problems
 where
  units = planUnits document
  keys = fmap unitKey units
  sourceNames = fmap sourceName (planSources document)
  envelope = planEnvelope document
  problems =
    titleProblems
      <> sourceProblems
      <> envelopeProblems
      <> unitProblems
      <> citationProblems
      <> edgeProblems
      <> cycleProblems
  titleProblems =
    [InvalidTitle Nothing | not (titleValid (planTitle document))]
  sourceProblems =
    [NoSources | L.null (planSources document)]
      <> [InvalidSourceDigest (sourceName s) | s <- planSources document, not (digestValid (sourceDigest s))]
      <> fmap DuplicateSource (duplicates sourceNames)
  envelopeProblems =
    [ExternalEffectNotAuthorized Nothing | envelopeExternalEffects envelope]
      <> [InvalidEnvelope | envelopeMaxUnits envelope < 1 || envelopeMaxUnits envelope > 200 || maybe False (< 1) (envelopeTokenBudget envelope)]
  unitProblems =
    [EmptyPlan | L.null units]
      <> [TooManyUnits (L.length units) (envelopeMaxUnits envelope) | envelopeMaxUnits envelope >= 1, envelopeMaxUnits envelope <= 200, L.length units > envelopeMaxUnits envelope]
      <> fmap DuplicateUnit (duplicates keys)
      <> L.concatMap unitProblemsOf units
  unitProblemsOf u =
    [InvalidTitle (Just (unitKey u)) | not (titleValid (unitTitle u))]
      <> case parseWorkKind (unitWorkKind u) of
        Nothing -> [UnknownWorkKind (unitKey u) (unitWorkKind u)]
        Just kind -> [IncompatibleMode (unitKey u) | not (compatible (planMode document) kind)]
      <> [UnknownProfile (unitKey u) (unitProfile u) | unitProfile u `L.notElem` contextProfiles context]
      <> [ExternalEffectNotAuthorized (Just (unitKey u)) | unitEffect u == ExternalEffect]
      <> [NoAcceptance (unitKey u) | L.all (T.null . T.strip . planCriterionText) (unitAcceptance u)]
  citations =
    L.concatMap (L.concatMap planCriterionCites . unitAcceptance) units
      <> L.concatMap uncertaintyCites (planUncertainties document)
  citationProblems =
    fmap UnknownCitation (L.nub [c | c <- citations, c `L.notElem` sourceNames])
  pairs = [(edgeDependent e, edgePrerequisite e) | e <- planEdges document]
  edgeProblems =
    fmap UnknownUnit (L.nub [u | (a, b) <- pairs, u <- [a, b], u `L.notElem` keys])
      <> fmap SelfEdge (L.nub [a | (a, b) <- pairs, a == b])
      <> fmap (uncurry DuplicateEdge) (duplicates pairs)
  cycleProblems =
    case findCycle (L.nub [(a, b) | (a, b) <- pairs, a /= b, a `L.elem` keys, b `L.elem` keys]) of
      Just edges -> [Cycle edges]
      Nothing -> []

-- | A Greenfield plan builds something new: it has no bug to fix. A Brownfield plan changes something that exists.
compatible :: PlanMode -> WorkKind -> Bool
compatible mode kind =
  case (mode, kind) of
    (Greenfield, BugFix) -> False
    (Brownfield, GreenfieldBuild) -> False
    _ -> True

titleValid :: T.Text -> Bool
titleValid raw =
  let
    t = T.strip raw
  in
    not (T.null t) && T.length t <= 200 && not (T.any Char.isControl t)

digestValid :: T.Text -> Bool
digestValid d =
  T.length d == 64 && T.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) d

-- | Each value that occurs more than once, once, in order of its second occurrence.
duplicates :: Eq a => [a] -> [a]
duplicates =
  go [] []
 where
  go _ found [] = L.reverse found
  go seen found (x : rest)
    | x `L.elem` seen && x `L.notElem` found = go seen (x : found) rest
    | otherwise = go (x : seen) found rest

{- | One cycle of the edges, as the edges that close it in order (each edge is
@(dependent, prerequisite)@ and the next edge starts at the previous one's
prerequisite), starting from the smallest key on it; nothing when acyclic.
-}
findCycle :: [(UnitKey, UnitKey)] -> Maybe [(UnitKey, UnitKey)]
findCycle edges =
  L.foldr (\start found -> fromFirst start <|> found) Nothing nodes
 where
  nodes = L.sort (L.nub (L.concatMap (\(a, b) -> [a, b]) edges))
  next u = L.sort (L.nub [b | (a, b) <- edges, a == u])
  fromFirst start = fst (search start [] [start] start)
  -- Depth first from @u@, the path so far reversed; a node already searched without success is not searched again.
  search start path visited u =
    L.foldl
      ( \(found, seen) v ->
          case found of
            Just _ -> (found, seen)
            Nothing
              | v == start -> (Just (L.reverse ((u, v) : path)), seen)
              | v `L.elem` seen -> (Nothing, seen)
              | otherwise -> search start ((u, v) : path) (v : seen) v
      )
      (Nothing, visited)
      (next u)

-- Digests ---------------------------------------------------------------------------

quoted :: T.Text -> T.Text
quoted =
  T.pack . show

field :: String -> T.Text -> T.Text
field name value =
  T.pack name <> T.pack " " <> value <> T.pack "\n"

listField :: String -> [T.Text] -> T.Text
listField name values =
  field name (T.pack (show (L.length values))) <> T.concat (fmap (field "-") values)

criterionText' :: PlanCriterion -> T.Text
criterionText' c =
  quoted (planCriterionText c) <> T.pack " cites " <> T.unwords (fmap quoted (planCriterionCites c))

unitText :: PlanUnit -> T.Text
unitText u =
  T.concat
    [ field "unit" (quoted (unitKeyText (unitKey u)))
    , field "title" (quoted (unitTitle u))
    , field "phase" (quoted (unitPhase u))
    , field "subphase" (quoted (unitSubphase u))
    , field "work-kind" (quoted (unitWorkKind u))
    , field "profile" (quoted (unitProfile u))
    , field "priority" (priorityCode (unitPriority u))
    , field "effect" (effectClassCode (unitEffect u))
    , field "risk" (riskClassCode (unitRisk u))
    , field "provisional" (if unitProvisional u then T.pack "yes" else T.pack "no")
    , listField "outputs" (fmap quoted (unitOutputs u))
    , listField "acceptance" (fmap criterionText' (unitAcceptance u))
    , listField "negative" (fmap quoted (unitNegative u))
    , listField "checks" (fmap quoted (unitChecks u))
    , listField "prerequisites" (fmap quoted (unitPrerequisites u))
    , listField "resources" (fmap quoted (unitResources u))
    ]

edgeText :: PlanEdge -> T.Text
edgeText e =
  quoted (unitKeyText (edgeDependent e)) <> T.pack " needs " <> quoted (unitKeyText (edgePrerequisite e)) <> T.pack " " <> edgeKindCode (edgeKind e)

-- | The canonical text of a document: the same for the same plan whatever the order of its units and edges.
canonicalPlanText :: PlanDocument -> T.Text
canonicalPlanText d =
  let
    envelope = planEnvelope d
  in
    T.concat
      [ field "lockstep-plan" (T.pack "1")
      , field "title" (quoted (planTitle d))
      , field "mode" (planModeCode (planMode d))
      , listField "sources" [quoted (sourceName s) <> T.pack " " <> sourceDigest s | s <- L.sortOn sourceName (planSources d)]
      , field "external-effects" (if envelopeExternalEffects envelope then T.pack "yes" else T.pack "no")
      , field "max-units" (T.pack (show (envelopeMaxUnits envelope)))
      , field "token-budget" (maybe (T.pack "none") (T.pack . show) (envelopeTokenBudget envelope))
      , listField "units" (fmap unitText (L.sortOn unitKey (planUnits d)))
      , listField "edges" (fmap edgeText (L.sortOn (\e -> (edgeDependent e, edgePrerequisite e, edgeKind e)) (planEdges d)))
      , listField "uncertainties" [quoted (uncertaintyText u) <> T.pack " cites " <> T.unwords (fmap quoted (uncertaintyCites u)) | u <- planUncertainties d]
      ]

digestOf :: Hasher -> T.Text -> T.Text
digestOf (Hasher f) =
  contentDigestText . f

planDigestText :: Hasher -> PlanDocument -> T.Text
planDigestText hasher =
  digestOf hasher . canonicalPlanText

-- | A unit's digest: its fields, its incoming edges and the digests of the sources it cites.
unitDigestText :: Hasher -> PlanDocument -> UnitKey -> Maybe T.Text
unitDigestText hasher d k =
  case L.find ((== k) . unitKey) (planUnits d) of
    Nothing -> Nothing
    Just u ->
      let
        incoming = L.sortOn (\e -> (edgePrerequisite e, edgeKind e)) [e | e <- planEdges d, edgeDependent e == k]
        cited = L.sort (L.nub (L.concatMap planCriterionCites (unitAcceptance u)))
        sourceLine name = quoted name <> T.pack " " <> maybe (T.pack "unknown") sourceDigest (L.find ((== name) . sourceName) (planSources d))
      in
        Just . digestOf hasher $
          unitText u
            <> listField "needs" (fmap edgeText incoming)
            <> listField "cited" (fmap sourceLine cited)

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
reconcilePlan hasher previous new =
  L.sortOn fst (fmap settle newKeys <> withdrawn)
 where
  newKeys = L.nub (fmap unitKey (planUnits new))
  oldKeys = maybe [] (L.nub . fmap unitKey . planUnits) previous
  direct u =
    case previous of
      Nothing -> UnitAdded
      Just old
        | u `L.notElem` oldKeys -> UnitAdded
        | unitDigestText hasher old u == unitDigestText hasher new u -> UnitKept
        | otherwise -> UnitChanged
  changed = [u | u <- newKeys, direct u == UnitChanged]
  technical = [(edgeDependent e, edgePrerequisite e) | e <- planEdges new, edgeKind e == Technical]
  -- Every unit that reaches a changed unit over technical edges.
  affected = grow changed
  grow found =
    let
      more = L.nub [d | (d, p) <- technical, p `L.elem` found, d `L.notElem` found]
    in
      if L.null more then found else grow (found <> more)
  settle u =
    case direct u of
      UnitKept | u `L.elem` affected -> (u, UnitInvalidated)
      outcome -> (u, outcome)
  withdrawn = [(u, UnitWithdrawn) | u <- oldKeys, u `L.notElem` newKeys]

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
elaborationProblemCode p =
  T.pack $
    case p of
      WrongRevision -> "wrong-revision"
      ElaborationUnknownUnit -> "unknown-unit"
      WeakenedAcceptance _ -> "weakened-acceptance"
      RemovedNegative _ -> "removed-negative"
      RemovedCheck _ -> "removed-check"
      ChangedEdges -> "changed-edges"
      ChangedEffect -> "changed-effect"
      ChangedWorkKind -> "changed-work-kind"
      ChangedProfile -> "changed-profile"

{- | The elaboration's problems against the effective revision (its digest and
document); none means it stays inside the approved boundary.
-}
validateElaboration :: T.Text -> PlanDocument -> Elaboration -> [ElaborationProblem]
validateElaboration digest document e =
  [WrongRevision | elaborationPlanDigest e /= digest]
    <> case L.find ((== elaborationUnit e) . unitKey) (planUnits document) of
      Nothing -> [ElaborationUnknownUnit]
      Just u ->
        [WeakenedAcceptance c | c <- fmap planCriterionText (unitAcceptance u), c `L.notElem` elaborationAcceptance e]
          <> [RemovedNegative n | n <- unitNegative u, n `L.notElem` elaborationNegative e]
          <> [RemovedCheck c | c <- unitChecks u, c `L.notElem` elaborationChecks e]
          <> [ChangedEdges | L.sort approvedEdges /= L.sort (elaborationEdges e)]
          <> [ChangedEffect | unitEffect u /= elaborationEffect e]
          <> [ChangedWorkKind | unitWorkKind u /= elaborationWorkKind e]
          <> [ChangedProfile | unitProfile u /= elaborationProfile e]
 where
  approvedEdges = [(edgePrerequisite x, edgeKind x) | x <- planEdges document, edgeDependent x == elaborationUnit e]
