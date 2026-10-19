{-# LANGUAGE RoleAnnotations #-}

{- | SDLC Profile policy (contract C-P2.3, DG-05): declarative, versioned
Profile definitions over a fixed vocabulary; monotonic resolution of the
effective Profile; human exceptions; immutable, digest-carrying bindings;
staleness after a source change; and gate evaluation. Pure: the hash
function is a value supplied by the boundary.
-}
module Lockstep.Kernel.Profile
  ( -- * Digests
    ContentDigest
  , mkContentDigest
  , contentDigestText
  , Hasher (..)

    -- * Names and vocabulary
  , ProfileId
  , mkProfileId
  , profileIdText
  , GateId
  , mkGateId
  , gateIdText
  , ClassTag
  , mkClassTag
  , classTagText
  , UniversalInvariant (..)
  , universalInvariantName
  , GateStage (..)
  , ArtifactKind (..)
  , producibleBeforeExecution
  , VerifierKind (..)
  , Approval (..)
  , PathClass (..)
  , parsePathClass
  , pathClassName

    -- * Definitions
  , RawGate (..)
  , RawSpecialization (..)
  , RawProfile (..)
  , Gate
  , gateId
  , gateStage
  , gateApproval
  , gateExceptionPath
  , ProfileDefinition
  , mkProfileDefinition
  , definitionId
  , definitionVersion
  , definitionGates
  , installationBaseline
  , renderProfileDefinition
  , ProfileRef (..)
  , profileRef

    -- * Facts and resolution
  , Override
  , mkOverride
  , NonBehaviouralBasis
  , mkNonBehaviouralBasis
  , Behaviour (..)
  , WorkFacts
  , mkWorkFacts
  , gateApplies
  , ResolutionInput (..)
  , LayerLevel (..)
  , EffectiveProfile
  , resolveProfile
  , effectiveSources
  , effectiveGates
  , effectiveInvariants
  , effectiveAllowsNonBehavioural
  , effectiveDigest
  , renderEffectiveProfile

    -- * Exceptions and binding
  , ExceptionTarget (..)
  , ExceptionReceipt
  , mkExceptionReceipt
  , ProfileBinding
  , bindProfile
  , bindingWorkOrder
  , bindingProfile
  , bindingExceptions
  , bindingDigest
  , renderBinding
  , verifyProvenance
  , admitWorkUnitException
  , ProfileConfirmation
  , mkProfileConfirmation
  , Freshness (..)
  , bindingFreshness

    -- * Gates
  , GateEvidence (..)
  , GateBlock (..)
  , GateStatus (..)
  , evaluateGate
  , executionPrerequisites
  , acceptanceGateIds
  , requiresFrozenTests
  , checkObservedPaths

    -- * Refusals
  , ProfileRefusal (..)
  , profileRefusalCode
  , renderProfileRefusal
  ) where

import Control.Monad (foldM)
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Identity (WorkOrderId (..), WorkUnitId (..), uuidText)
import Lockstep.Kernel.Transition (Principal (..))
import Lockstep.Kernel.WorkOrder (WorkOrderKind, parseWorkOrderKind, workOrderKindName)
import Lockstep.Kernel.WorkUnit (AdmittedWorkUnit (..), WorkUnitRequest (..))

-- Digests ---------------------------------------------------------------------

-- | A SHA-256 digest as 64 lowercase hexadecimal characters.
newtype ContentDigest
  = ContentDigest T.Text
  deriving (Eq, Ord, Show)

mkContentDigest :: T.Text -> Maybe ContentDigest
mkContentDigest text =
  if T.length text == 64 && T.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) text
    then Just (ContentDigest text)
    else Nothing

contentDigestText :: ContentDigest -> T.Text
contentDigestText (ContentDigest text) =
  text

-- | The digest function, supplied by the boundary (C-P2.3 F11).
newtype Hasher
  = Hasher (T.Text -> ContentDigest)

hashWith :: Hasher -> T.Text -> ContentDigest
hashWith (Hasher f) =
  f

-- Names -----------------------------------------------------------------------

-- | @^[a-z][a-z0-9-]{0,63}$@.
validName :: T.Text -> Bool
validName text =
  case T.uncons text of
    Just (first, rest) ->
      Char.isAsciiLower first
        && T.length text <= 64
        && T.all (\c -> Char.isAsciiLower c || Char.isDigit c || c == '-') rest
    Nothing -> False

newtype ProfileId
  = ProfileId T.Text
  deriving (Eq, Ord, Show)

mkProfileId :: T.Text -> Maybe ProfileId
mkProfileId text =
  if validName text then Just (ProfileId text) else Nothing

profileIdText :: ProfileId -> T.Text
profileIdText (ProfileId text) =
  text

newtype GateId
  = GateId T.Text
  deriving (Eq, Ord, Show)

mkGateId :: T.Text -> Maybe GateId
mkGateId text =
  if validName text then Just (GateId text) else Nothing

gateIdText :: GateId -> T.Text
gateIdText (GateId text) =
  text

newtype ClassTag
  = ClassTag T.Text
  deriving (Eq, Ord, Show)

mkClassTag :: T.Text -> Maybe ClassTag
mkClassTag text =
  if validName text then Just (ClassTag text) else Nothing

classTagText :: ClassTag -> T.Text
classTagText (ClassTag text) =
  text

-- Vocabulary (F1, F4) ---------------------------------------------------------

data UniversalInvariant
  = SingleImplementer
  | ScopeAndAuthorization
  | DurableAttempts
  | ProtectedFrozenTests
  | DeterministicVerification
  | IndependentReview
  | BoundedRetries
  | LegitimateCommits
  | HumanCompletion
  deriving (Eq, Ord, Show, Enum, Bounded)

universalInvariantName :: UniversalInvariant -> T.Text
universalInvariantName invariant =
  T.pack $
    case invariant of
      SingleImplementer -> "single-implementer"
      ScopeAndAuthorization -> "scope-and-authorization"
      DurableAttempts -> "durable-attempts"
      ProtectedFrozenTests -> "protected-frozen-tests"
      DeterministicVerification -> "deterministic-verification"
      IndependentReview -> "independent-review"
      BoundedRetries -> "bounded-retries"
      LegitimateCommits -> "legitimate-commits"
      HumanCompletion -> "human-completion"

data GateStage
  = BeforeExecution
  | BeforeAcceptance
  | BeforeCompletion
  deriving (Eq, Ord, Show, Enum, Bounded)

stageName :: GateStage -> T.Text
stageName stage =
  T.pack $
    case stage of
      BeforeExecution -> "before-execution"
      BeforeAcceptance -> "before-acceptance"
      BeforeCompletion -> "before-completion"

data ArtifactKind
  = RequirementsBasis
  | Reproduction
  | ImpactAssessment
  | ThreatModel
  | ArchitectureAssessment
  | ClassificationRationale
  | HumanApprovalRecord
  | FrozenTests
  | VerificationRecord
  | ReviewRecord
  | RegressionEvidence
  | IntegrationRecord
  | Documentation
  deriving (Eq, Ord, Show, Enum, Bounded)

artifactName :: ArtifactKind -> T.Text
artifactName kind =
  T.pack $
    case kind of
      RequirementsBasis -> "requirements-basis"
      Reproduction -> "reproduction"
      ImpactAssessment -> "impact-assessment"
      ThreatModel -> "threat-model"
      ArchitectureAssessment -> "architecture-assessment"
      ClassificationRationale -> "classification-rationale"
      HumanApprovalRecord -> "human-approval"
      FrozenTests -> "frozen-tests"
      VerificationRecord -> "verification-record"
      ReviewRecord -> "review-record"
      RegressionEvidence -> "regression-evidence"
      IntegrationRecord -> "integration-record"
      Documentation -> "documentation"

-- | Clarification 1: only these can exist before execution starts.
producibleBeforeExecution :: ArtifactKind -> Bool
producibleBeforeExecution kind =
  kind
    `L.elem` [ RequirementsBasis
             , Reproduction
             , ImpactAssessment
             , ThreatModel
             , ArchitectureAssessment
             , ClassificationRationale
             , HumanApprovalRecord
             ]

data VerifierKind
  = VerifyDigest
  | VerifyCommand
  | VerifyIndependentReview
  | VerifyHumanInspection
  deriving (Eq, Ord, Show, Enum, Bounded)

verifierName :: VerifierKind -> T.Text
verifierName verifier =
  T.pack $
    case verifier of
      VerifyDigest -> "digest-check"
      VerifyCommand -> "deterministic-command"
      VerifyIndependentReview -> "independent-review"
      VerifyHumanInspection -> "human-inspection"

-- | Ordered: none < supervisor < human.
data Approval
  = ApprovalNone
  | ApprovalSupervisor
  | ApprovalHuman
  deriving (Eq, Ord, Show, Enum, Bounded)

approvalName :: Approval -> T.Text
approvalName approval =
  T.pack $
    case approval of
      ApprovalNone -> "none"
      ApprovalSupervisor -> "supervisor"
      ApprovalHuman -> "human"

data PathClass
  = PathDocs
  | PathSource
  | PathTests
  | PathBuild
  | PathDependencies
  | PathConfiguration
  deriving (Eq, Ord, Show, Enum, Bounded)

pathClassName :: PathClass -> T.Text
pathClassName path =
  T.pack $
    case path of
      PathDocs -> "docs"
      PathSource -> "source"
      PathTests -> "tests"
      PathBuild -> "build"
      PathDependencies -> "dependencies"
      PathConfiguration -> "configuration"

parsePathClass :: T.Text -> Maybe PathClass
parsePathClass =
  parseBy pathClassName

parseBy :: (Enum a, Bounded a) => (a -> T.Text) -> T.Text -> Maybe a
parseBy name text =
  L.find ((== text) . name) [minBound .. maxBound]

-- Raw documents ---------------------------------------------------------------

data RawGate
  = RawGate
  { rawGateId :: T.Text
  , rawGateStage :: T.Text
  , rawGateArtifacts :: [T.Text]
  , rawGateKinds :: Maybe [T.Text]
  , rawGateClasses :: Maybe [T.Text]
  , rawGatePathClasses :: Maybe [T.Text]
  , rawGateVerifiers :: [T.Text]
  , rawGateApproval :: T.Text
  , rawGateExceptionPath :: Bool
  }
  deriving (Eq, Show)

data RawSpecialization
  = RawSpecialization
  { rawWhenKind :: Maybe T.Text
  , rawWhenClass :: Maybe T.Text
  , rawSpecializationProfile :: T.Text
  }
  deriving (Eq, Show)

data RawProfile
  = RawProfile
  { rawProfileId :: T.Text
  , rawProfileVersion :: Integer
  , rawAllowsNonBehavioural :: Maybe Bool
  , rawInvariantExceptions :: [T.Text]
  , rawGates :: [RawGate]
  , rawSpecializations :: [RawSpecialization]
  }
  deriving (Eq, Show)

-- Gates (F2, F3) --------------------------------------------------------------

-- | Any value, or a non-empty set held sorted by name without duplicates.
type role Scope representational

data Scope a
  = AnyValue
  | OnlyValues [a]
  deriving (Eq, Show)

data Applicability
  = Applicability (Scope WorkOrderKind) (Scope ClassTag) (Scope PathClass)
  deriving (Eq, Show)

-- | A validated gate; built only by 'mkGate'. Sets are sorted by name.
data Gate
  = Gate GateId GateStage [ArtifactKind] Applicability [VerifierKind] Approval Bool
  deriving (Eq, Show)

gateId :: Gate -> GateId
gateId (Gate g _ _ _ _ _ _) =
  g

gateStage :: Gate -> GateStage
gateStage (Gate _ stage _ _ _ _ _) =
  stage

gateArtifacts :: Gate -> [ArtifactKind]
gateArtifacts (Gate _ _ artifacts _ _ _ _) =
  artifacts

gateApplicability :: Gate -> Applicability
gateApplicability (Gate _ _ _ applicability _ _ _) =
  applicability

gateVerifiers :: Gate -> [VerifierKind]
gateVerifiers (Gate _ _ _ _ verifiers _ _) =
  verifiers

gateApproval :: Gate -> Approval
gateApproval (Gate _ _ _ _ _ approval _) =
  approval

gateExceptionPath :: Gate -> Bool
gateExceptionPath (Gate _ _ _ _ _ _ exceptionPath) =
  exceptionPath

invalid :: String -> Either ProfileRefusal a
invalid =
  Left . InvalidProfile . T.pack

-- | Parses every element and keeps the set sorted by name.
setOf :: Eq a => String -> (a -> T.Text) -> (T.Text -> Maybe a) -> [T.Text] -> Either ProfileRefusal [a]
setOf what name parse texts =
  case traverse parse texts of
    Nothing -> invalid ("unknown " <> what <> " name")
    Just values -> Right (L.sortOn name (L.nub values))

nonEmptySetOf :: Eq a => String -> (a -> T.Text) -> (T.Text -> Maybe a) -> [T.Text] -> Either ProfileRefusal [a]
nonEmptySetOf what name parse texts =
  if L.null texts
    then invalid ("empty " <> what)
    else setOf what name parse texts

scopeOf :: Eq a => String -> (a -> T.Text) -> (T.Text -> Maybe a) -> Maybe [T.Text] -> Either ProfileRefusal (Scope a)
scopeOf what name parse =
  maybe (Right AnyValue) (fmap OnlyValues . nonEmptySetOf what name parse)

mkGate :: RawGate -> Either ProfileRefusal Gate
mkGate raw = do
  g <- maybe (invalid "gate id") Right (mkGateId (rawGateId raw))
  if T.pack "invariant-" `T.isPrefixOf` rawGateId raw
    then Left (WeakensUniversalInvariant (rawGateId raw))
    else Right ()
  stage <- maybe (invalid "unknown stage") Right (parseBy stageName (rawGateStage raw))
  artifacts <- nonEmptySetOf "artifact" artifactName (parseBy artifactName) (rawGateArtifacts raw)
  kinds <- scopeOf "kind" workOrderKindName parseWorkOrderKind (rawGateKinds raw)
  classes <- scopeOf "class" classTagText mkClassTag (rawGateClasses raw)
  paths <- scopeOf "path class" pathClassName parsePathClass (rawGatePathClasses raw)
  verifiers <- nonEmptySetOf "verifier" verifierName (parseBy verifierName) (rawGateVerifiers raw)
  approval <- maybe (invalid "unknown approval") Right (parseBy approvalName (rawGateApproval raw))
  if stage == BeforeExecution && not (L.all producibleBeforeExecution artifacts)
    then Left (GateUnsatisfiableBeforeExecution g)
    else Right (Gate g stage artifacts (Applicability kinds classes paths) verifiers approval (rawGateExceptionPath raw))

-- | Validated gates, unique by id, sorted by id.
mkGates :: [RawGate] -> Either ProfileRefusal [Gate]
mkGates raws = do
  gates <- traverse mkGate raws
  let
    ids = fmap gateId gates
  if L.nub ids /= ids
    then invalid "duplicate gate id"
    else Right (L.sortOn gateId gates)

-- Definitions (D-5.1a, D-5.2) -------------------------------------------------

data Specialization
  = SpecializeKind WorkOrderKind ProfileId
  | SpecializeClass ClassTag ProfileId
  deriving (Eq, Show)

specializationKey :: Specialization -> (Int, T.Text)
specializationKey specialization =
  case specialization of
    SpecializeKind kind _ -> (0, workOrderKindName kind)
    SpecializeClass tag _ -> (1, classTagText tag)

specializationTarget :: Specialization -> ProfileId
specializationTarget specialization =
  case specialization of
    SpecializeKind _ target -> target
    SpecializeClass _ target -> target

-- | A validated Profile definition: id, version, non-behavioural permission (Nothing = inherit), gates, specializations.
data ProfileDefinition
  = ProfileDefinition ProfileId Int (Maybe Bool) [Gate] [Specialization]
  deriving (Eq, Show)

definitionId :: ProfileDefinition -> ProfileId
definitionId (ProfileDefinition p _ _ _ _) =
  p

definitionVersion :: ProfileDefinition -> Int
definitionVersion (ProfileDefinition _ version _ _ _) =
  version

definitionAllows :: ProfileDefinition -> Maybe Bool
definitionAllows (ProfileDefinition _ _ allows _ _) =
  allows

definitionGates :: ProfileDefinition -> [Gate]
definitionGates (ProfileDefinition _ _ _ gates _) =
  gates

definitionSpecializations :: ProfileDefinition -> [Specialization]
definitionSpecializations (ProfileDefinition _ _ _ _ specializations) =
  specializations

mkProfileDefinition :: RawProfile -> Either ProfileRefusal ProfileDefinition
mkProfileDefinition raw = do
  p <- maybe (invalid "profile id") Right (mkProfileId (rawProfileId raw))
  version <-
    if rawProfileVersion raw >= 1 && rawProfileVersion raw <= 1000000
      then Right (fromInteger (rawProfileVersion raw))
      else invalid "version must be 1 to 1000000"
  traverse_ invariantException (rawInvariantExceptions raw)
  gates <- mkGates (rawGates raw)
  specializations <- traverse (mkSpecialization p) (rawSpecializations raw)
  let
    keys = fmap specializationKey specializations
  if L.nub keys /= keys
    then invalid "duplicate specialization selector"
    else Right (ProfileDefinition p version (rawAllowsNonBehavioural raw) gates (L.sortOn specializationKey specializations))

-- | Any listed invariant is a weakening; an unknown name is invalid.
invariantException :: T.Text -> Either ProfileRefusal ()
invariantException name =
  case parseBy universalInvariantName name of
    Just _ -> Left (WeakensUniversalInvariant name)
    Nothing -> invalid "unknown invariant name"

mkSpecialization :: ProfileId -> RawSpecialization -> Either ProfileRefusal Specialization
mkSpecialization own raw = do
  target <- maybe (invalid "specialization profile id") Right (mkProfileId (rawSpecializationProfile raw))
  if target == own
    then invalid "a profile cannot specialize itself"
    else Right ()
  case (rawWhenKind raw, rawWhenClass raw) of
    (Just kind, Nothing) -> maybe (invalid "unknown kind") (\k -> Right (SpecializeKind k target)) (parseWorkOrderKind kind)
    (Nothing, Just tag) -> maybe (invalid "invalid class tag") (\c -> Right (SpecializeClass c target)) (mkClassTag tag)
    _ -> invalid "a specialization has exactly one of when_kind and when_class"

-- | Layer 1 of F5: no gates; the non-behavioural path permitted.
installationBaseline :: ProfileDefinition
installationBaseline =
  ProfileDefinition (ProfileId (T.pack "lockstep-baseline")) 1 (Just True) [] []

-- Rendering (§3) --------------------------------------------------------------

showText :: Show a => a -> T.Text
showText =
  T.pack . show

joined :: (a -> T.Text) -> [a] -> T.Text
joined name =
  T.intercalate (T.pack ",") . fmap name

scopeText :: (a -> T.Text) -> Scope a -> T.Text
scopeText name scope =
  case scope of
    AnyValue -> T.pack "*"
    OnlyValues values -> joined name values

boolText :: Bool -> T.Text
boolText b =
  T.pack (if b then "true" else "false")

triText :: Maybe Bool -> T.Text
triText =
  maybe (T.pack "inherit") boolText

quoted :: T.Text -> T.Text
quoted text =
  T.pack "\"" <> T.replace (T.pack "\"") (T.pack "\\\"") (T.replace (T.pack "\\") (T.pack "\\\\") text) <> T.pack "\""

field :: String -> T.Text -> T.Text
field name value =
  T.pack name <> T.pack "=" <> value

renderGateFields :: Gate -> T.Text
renderGateFields (Gate g stage artifacts (Applicability kinds classes paths) verifiers approval exceptionPath) =
  T.unwords
    [ gateIdText g
    , field "stage" (stageName stage)
    , field "artifacts" (joined artifactName artifacts)
    , field "kinds" (scopeText workOrderKindName kinds)
    , field "classes" (scopeText classTagText classes)
    , field "path-classes" (scopeText pathClassName paths)
    , field "verifiers" (joined verifierName verifiers)
    , field "approval" (approvalName approval)
    , field "exception-path" (boolText exceptionPath)
    ]

renderSpecialization :: Specialization -> T.Text
renderSpecialization specialization =
  case specialization of
    SpecializeKind kind target -> T.unwords [T.pack "specialize", field "kind" (workOrderKindName kind), field "profile" (profileIdText target)]
    SpecializeClass tag target -> T.unwords [T.pack "specialize", field "class" (classTagText tag), field "profile" (profileIdText target)]

renderProfileDefinition :: ProfileDefinition -> T.Text
renderProfileDefinition (ProfileDefinition p version allows gates specializations) =
  T.unlines $
    [ T.pack "lockstep-profile 1"
    , T.pack "id " <> profileIdText p
    , T.pack "version " <> showText version
    , T.pack "allows-non-behavioural " <> triText allows
    ]
      <> fmap ((T.pack "gate " <>) . renderGateFields) gates
      <> fmap renderSpecialization specializations

data ProfileRef
  = ProfileRef
  { refId :: ProfileId
  , refVersion :: Int
  , refDigest :: ContentDigest
  }
  deriving (Eq, Ord, Show)

profileRef :: Hasher -> ProfileDefinition -> ProfileRef
profileRef hasher d =
  ProfileRef (definitionId d) (definitionVersion d) (hashWith hasher (renderProfileDefinition d))

-- Facts (F6, F7) --------------------------------------------------------------

-- | Free text recorded in evidence: 1-500 characters, no control characters.
validText :: T.Text -> Bool
validText text =
  not (T.null text) && T.length text <= 500 && not (T.any Char.isControl text)

-- | A human-approved stricter override (layer 4): approver, rationale, permission, gates.
data Override
  = Override T.Text T.Text (Maybe Bool) [Gate]
  deriving (Eq, Show)

mkOverride :: Principal -> T.Text -> T.Text -> Maybe Bool -> [RawGate] -> Either ProfileRefusal Override
mkOverride principal approver rationale allows raws
  | principal /= Human = Left (BindingNotAuthorized principal)
  | not (validText approver) = Left (InvalidRecord (T.pack "an override needs an approver"))
  | not (validText rationale) = Left (InvalidRecord (T.pack "an override needs a rationale"))
  | otherwise = Override approver rationale allows <$> mkGates raws

-- | Why work is non-behavioural, and the human who approved the classification.
data NonBehaviouralBasis
  = NonBehaviouralBasis T.Text T.Text
  deriving (Eq, Show)

mkNonBehaviouralBasis :: T.Text -> T.Text -> Maybe NonBehaviouralBasis
mkNonBehaviouralBasis rationale approver =
  if validText rationale && validText approver
    then Just (NonBehaviouralBasis rationale approver)
    else Nothing

data Behaviour
  = BehaviourChanging
  | NonBehavioural NonBehaviouralBasis
  deriving (Eq, Show)

-- | Kind, class tags and declared path classes (sorted), behaviour; set by a human.
data WorkFacts
  = WorkFacts WorkOrderKind [ClassTag] [PathClass] Behaviour
  deriving (Eq, Show)

factsBehaviour :: WorkFacts -> Behaviour
factsBehaviour (WorkFacts _ _ _ behaviour) =
  behaviour

mkWorkFacts :: Principal -> WorkOrderKind -> [ClassTag] -> [PathClass] -> Behaviour -> Either ProfileRefusal WorkFacts
mkWorkFacts principal kind classes paths behaviour
  | principal /= Human = Left (UntrustedClassification principal)
  | otherwise =
      case behaviour of
        NonBehavioural _
          | L.null paths || L.any (/= PathDocs) paths ->
              Left (NonBehaviouralRefused (T.pack "non-behavioural work must declare docs-only path classes"))
        _ -> Right (WorkFacts kind (L.sort (L.nub classes)) (L.sortOn pathClassName (L.nub paths)) behaviour)

{- | A kind set must contain the kind; a class set must meet the classes; a
path-class set must meet the declared path classes, and an empty declaration
applies it (unknown scope fails closed).
-}
gateApplies :: WorkFacts -> Gate -> Bool
gateApplies (WorkFacts kind classes paths _) gate =
  let
    Applicability kinds classScope pathScope = gateApplicability gate
    meets scope values =
      case scope of
        AnyValue -> True
        OnlyValues allowed -> L.any (`L.elem` allowed) values
  in
    meets kinds [kind]
      && meets classScope classes
      && (L.null paths || meets pathScope paths)

-- Resolution (F5) -------------------------------------------------------------

data ResolutionInput
  = ResolutionInput
  { resolutionDefault :: ProfileDefinition
  , resolutionCatalog :: [ProfileDefinition]
  , resolutionOverrides :: [Override]
  , resolutionFacts :: WorkFacts
  }

data LayerLevel
  = LayerBaseline
  | LayerRepositoryDefault
  | LayerSpecialization
  | LayerOverride
  deriving (Eq, Ord, Show, Enum, Bounded)

layerName :: LayerLevel -> T.Text
layerName level =
  T.pack $
    case level of
      LayerBaseline -> "baseline"
      LayerRepositoryDefault -> "repository-default"
      LayerSpecialization -> "specialization"
      LayerOverride -> "override"

-- | The resolved policy for one Work Order; built only by 'resolveProfile'.
data EffectiveProfile
  = EffectiveProfile
  { effSources :: [(LayerLevel, ProfileRef)]
  , effOverrides :: [Override]
  , effGates :: [Gate]
  , effAllows :: Bool
  , effFacts :: WorkFacts
  , effDigest :: ContentDigest
  }
  deriving (Eq, Show)

effectiveSources :: EffectiveProfile -> [(LayerLevel, ProfileRef)]
effectiveSources =
  effSources

effectiveGates :: EffectiveProfile -> [Gate]
effectiveGates =
  effGates

-- | Always all nine (F4): no definition can remove one.
effectiveInvariants :: EffectiveProfile -> [UniversalInvariant]
effectiveInvariants _ =
  [minBound .. maxBound]

effectiveAllowsNonBehavioural :: EffectiveProfile -> Bool
effectiveAllowsNonBehavioural =
  effAllows

effectiveDigest :: EffectiveProfile -> ContentDigest
effectiveDigest =
  effDigest

resolveProfile :: Hasher -> ResolutionInput -> Either ProfileRefusal EffectiveProfile
resolveProfile hasher input = do
  let
    d = resolutionDefault input
    facts@(WorkFacts kind classes _ behaviour) = resolutionFacts input
    matches specialization =
      case specialization of
        SpecializeKind k _ -> k == kind
        SpecializeClass c _ -> c `L.elem` classes
    targets = L.nub (fmap specializationTarget (L.filter matches (definitionSpecializations d)))
  specializations <- L.sortOn definitionId <$> traverse (latest (resolutionCatalog input)) targets
  let
    layer definition = (definitionGates definition, definitionAllows definition)
    overrideLayer (Override _ _ allows gates) = (gates, allows)
    levels =
      [ [layer installationBaseline]
      , [layer d]
      , fmap layer specializations
      , fmap overrideLayer (resolutionOverrides input)
      ]
  (gates, allows) <- foldM mergeLevel ([], True) levels
  case behaviour of
    NonBehavioural _
      | not allows ->
          Left (NonBehaviouralRefused (T.pack "the effective Profile does not permit non-behavioural work"))
    _ -> Right ()
  let
    sources =
      [(LayerBaseline, profileRef hasher installationBaseline), (LayerRepositoryDefault, profileRef hasher d)]
        <> fmap (\s -> (LayerSpecialization, profileRef hasher s)) specializations
    unhashed = EffectiveProfile sources (resolutionOverrides input) gates allows facts (ContentDigest T.empty)
  pure unhashed {effDigest = hashWith hasher (renderEffectiveProfile unhashed)}

-- | The latest registered version of a specialization, which must not specialize further.
latest :: [ProfileDefinition] -> ProfileId -> Either ProfileRefusal ProfileDefinition
latest catalog target =
  case L.sortOn (Down . definitionVersion) (L.filter ((== target) . definitionId) catalog) of
    [] -> Left (ProfileUnavailable target)
    newest : _
      | L.null (definitionSpecializations newest) -> Right newest
      | otherwise -> invalid "a specialization profile declares specializations"

-- | One level: same-level agreement, then monotonic strengthening over the earlier levels.
mergeLevel :: ([Gate], Bool) -> [([Gate], Maybe Bool)] -> Either ProfileRefusal ([Gate], Bool)
mergeLevel (accumulated, allows) contributions = do
  levelGates <- agreeing (L.sortOn gateId (L.concatMap fst contributions))
  levelAllows <-
    case L.nub (mapMaybe snd contributions) of
      [] -> Right Nothing
      [value] -> Right (Just value)
      _ -> Left (ProfileConflict (T.pack "allows-non-behavioural"))
  gates <- foldM strengthen accumulated levelGates
  allows' <-
    case levelAllows of
      Nothing -> Right allows
      Just True | not allows -> Left WeakensNonBehaviouralPolicy
      Just value -> Right value
  pure (gates, allows')

-- | Gates of one level, sorted by id; two different definitions of one id conflict.
agreeing :: [Gate] -> Either ProfileRefusal [Gate]
agreeing gates =
  case gates of
    a : b : rest
      | gateId a == gateId b ->
          if a == b then agreeing (a : rest) else Left (ProfileConflict (gateIdText (gateId a)))
      | otherwise -> (a :) <$> agreeing (b : rest)
    _ -> Right gates

strengthen :: [Gate] -> Gate -> Either ProfileRefusal [Gate]
strengthen accumulated new =
  case L.find ((== gateId new) . gateId) accumulated of
    Nothing -> Right (L.sortOn gateId (new : accumulated))
    Just old -> do
      checkStronger old new
      Right (fmap (\g -> if gateId g == gateId new then new else g) accumulated)

-- | Clarification 2: every axis at least as strong; a stage change cannot be proved.
checkStronger :: Gate -> Gate -> Either ProfileRefusal ()
checkStronger old new =
  let
    Applicability oldKinds oldClasses oldPaths = gateApplicability old
    Applicability newKinds newClasses newPaths = gateApplicability new
    axes =
      [ ("applicability", covers oldKinds newKinds && covers oldClasses newClasses && covers oldPaths newPaths)
      , ("artifacts", L.all (`L.elem` gateArtifacts new) (gateArtifacts old))
      , ("verifiers", L.all (`L.elem` gateVerifiers new) (gateVerifiers old))
      , ("approval", gateApproval new >= gateApproval old)
      , ("exception-path", not (gateExceptionPath new) || gateExceptionPath old)
      ]
  in
    case L.find (not . snd) axes of
      Just (axis, _) -> Left (WeakensGate (gateId new) (T.pack axis))
      Nothing
        | gateStage new /= gateStage old -> Left (UnprovableStrengthening (gateId new) (T.pack "stage"))
        | otherwise -> Right ()

-- | The new scope applies wherever the old one did.
covers :: Eq a => Scope a -> Scope a -> Bool
covers old new =
  case (old, new) of
    (_, AnyValue) -> True
    (AnyValue, OnlyValues _) -> False
    (OnlyValues olds, OnlyValues news) -> L.all (`L.elem` news) olds

renderEffectiveProfile :: EffectiveProfile -> T.Text
renderEffectiveProfile eff =
  let
    WorkFacts kind classes paths behaviour = effFacts eff
    orDash name values = if L.null values then T.pack "-" else joined name values
    source (level, ref) =
      T.unwords [T.pack "source", layerName level, profileIdText (refId ref), showText (refVersion ref), contentDigestText (refDigest ref)]
    override (i, Override approver rationale allows gates) =
      T.unwords
        [ T.pack "override"
        , showText i
        , field "approver" (quoted approver)
        , field "rationale" (quoted rationale)
        , field "allows-non-behavioural" (triText allows)
        ]
        : fmap (\g -> T.unwords [T.pack "override-gate", showText i, renderGateFields g]) gates
    factsLine =
      T.unwords
        [ T.pack "facts"
        , field "kind" (workOrderKindName kind)
        , field "classes" (orDash classTagText classes)
        , field "path-classes" (orDash pathClassName paths)
        , field "behaviour" (T.pack (case behaviour of BehaviourChanging -> "behaviour-changing"; NonBehavioural _ -> "non-behavioural"))
        ]
    basisLines =
      case behaviour of
        BehaviourChanging -> []
        NonBehavioural (NonBehaviouralBasis rationale approver) ->
          [T.unwords [T.pack "non-behavioural-basis", field "rationale" (quoted rationale), field "approver" (quoted approver)]]
  in
    T.unlines $
      [T.pack "lockstep-effective-profile 1"]
        <> fmap source (effSources eff)
        <> L.concatMap override (L.zip [1 :: Int ..] (effOverrides eff))
        <> [ T.pack "invariants " <> joined universalInvariantName (effectiveInvariants eff)
           , T.pack "allows-non-behavioural " <> boolText (effAllows eff)
           ]
        <> fmap ((T.pack "gate " <>) . renderGateFields) (effGates eff)
        <> [factsLine]
        <> basisLines

-- Exceptions and binding (F8, F9) ---------------------------------------------

data ExceptionTarget
  = ForWorkOrder WorkOrderId
  | ForWorkUnit WorkUnitId
  deriving (Eq, Show)

-- | A human's durable exception: target, gate, rationale, approver, time, the effective digest it was granted against.
data ExceptionReceipt
  = ExceptionReceipt ExceptionTarget GateId T.Text T.Text UTCTime ContentDigest
  deriving (Eq, Show)

receiptTarget :: ExceptionReceipt -> ExceptionTarget
receiptTarget (ExceptionReceipt target _ _ _ _ _) =
  target

receiptGate :: ExceptionReceipt -> GateId
receiptGate (ExceptionReceipt _ g _ _ _ _) =
  g

receiptDigest :: ExceptionReceipt -> ContentDigest
receiptDigest (ExceptionReceipt _ _ _ _ _ digest) =
  digest

mkExceptionReceipt :: Principal -> ExceptionTarget -> GateId -> T.Text -> T.Text -> UTCTime -> ContentDigest -> Either ProfileRefusal ExceptionReceipt
mkExceptionReceipt principal target g rationale approver grantedAt digest
  | principal /= Human = Left ExceptionNotHuman
  | not (validText rationale) = Left (InvalidRecord (T.pack "an exception needs a rationale"))
  | not (validText approver) = Left (InvalidRecord (T.pack "an exception needs an approver"))
  | otherwise = Right (ExceptionReceipt target g rationale approver grantedAt digest)

-- | Scope (given), digest, gate, applicability and exception path, in that order.
checkReceipt :: Bool -> EffectiveProfile -> ExceptionReceipt -> Either ProfileRefusal ()
checkReceipt inScope eff receipt
  | not inScope = Left ExceptionOutOfScope
  | receiptDigest receipt /= effDigest eff = Left ExceptionProfileMismatch
  | otherwise =
      case L.find ((== receiptGate receipt) . gateId) (effGates eff) of
        Nothing -> Left (ExceptionUnknownGate (receiptGate receipt))
        Just gate
          | not (gateApplies (effFacts eff) gate) -> Left (ExceptionNotApplicable (gateId gate))
          | not (gateExceptionPath gate) -> Left (ExceptionNotPermitted (gateId gate))
          | otherwise -> Right ()

-- | The immutable binding of an effective Profile to one Work Order (D-5.5).
data ProfileBinding
  = ProfileBinding
  { bWorkOrder :: WorkOrderId
  , bProfile :: EffectiveProfile
  , bExceptions :: [ExceptionReceipt]
  , bApprover :: T.Text
  , bDigest :: ContentDigest
  }
  deriving (Eq, Show)

bindingWorkOrder :: ProfileBinding -> WorkOrderId
bindingWorkOrder =
  bWorkOrder

bindingProfile :: ProfileBinding -> EffectiveProfile
bindingProfile =
  bProfile

bindingExceptions :: ProfileBinding -> [ExceptionReceipt]
bindingExceptions =
  bExceptions

bindingDigest :: ProfileBinding -> ContentDigest
bindingDigest =
  bDigest

bindProfile :: Hasher -> Principal -> WorkOrderId -> T.Text -> EffectiveProfile -> [ExceptionReceipt] -> Either ProfileRefusal ProfileBinding
bindProfile hasher principal workOrder approver eff receipts
  | principal `L.notElem` [Human, Supervisor] = Left (BindingNotAuthorized principal)
  | not (validText approver) = Left (InvalidRecord (T.pack "a binding needs an approver"))
  | otherwise = do
      traverse_ (\r -> checkReceipt (receiptTarget r == ForWorkOrder workOrder) eff r) receipts
      let
        gates = fmap receiptGate receipts
      if L.nub gates /= gates
        then Left (InvalidRecord (T.pack "two exceptions for one gate"))
        else Right ()
      let
        unhashed = ProfileBinding workOrder eff (L.sortOn receiptGate receipts) approver (ContentDigest T.empty)
      pure unhashed {bDigest = hashWith hasher (renderBinding unhashed)}

renderBinding :: ProfileBinding -> T.Text
renderBinding b =
  let
    WorkOrderId workOrder = bWorkOrder b
    target t =
      case t of
        ForWorkOrder (WorkOrderId u) -> T.pack "work-order:" <> uuidText u
        ForWorkUnit (WorkUnitId u) -> T.pack "work-unit:" <> uuidText u
    receiptLine (ExceptionReceipt t g rationale approver grantedAt digest) =
      T.unwords
        [ T.pack "exception"
        , field "gate" (gateIdText g)
        , field "target" (target t)
        , field "approver" (quoted approver)
        , field "rationale" (quoted rationale)
        , field "granted-at" (T.pack (iso8601Show grantedAt))
        , field "profile-digest" (contentDigestText digest)
        ]
  in
    T.unlines $
      [ T.pack "lockstep-profile-binding 1"
      , T.pack "work-order " <> uuidText workOrder
      , T.pack "effective-digest " <> contentDigestText (effDigest (bProfile b))
      , T.pack "approver " <> quoted (bApprover b)
      ]
        <> fmap receiptLine (bExceptions b)

{- | Every source digest is recomputed from the given definitions, the
resolution is repeated from them with the bound overrides and facts, and both
digests are recomputed.
-}
verifyProvenance :: Hasher -> [ProfileDefinition] -> ProfileBinding -> Bool
verifyProvenance hasher definitions b =
  let
    eff = bProfile b
    definitionFor ref = L.find ((== ref) . profileRef hasher) definitions
    defaults = [ref | (LayerRepositoryDefault, ref) <- effSources eff]
    specializations = [ref | (LayerSpecialization, ref) <- effSources eff]
    baselineOk = L.all (== profileRef hasher installationBaseline) [ref | (LayerBaseline, ref) <- effSources eff]
  in
    case (defaults, traverse definitionFor defaults, traverse definitionFor specializations) of
      ([_], Just [d], Just specs) ->
        baselineOk
          && resolveProfile hasher (ResolutionInput d specs (effOverrides eff) (effFacts eff)) == Right eff
          && effDigest eff == hashWith hasher (renderEffectiveProfile eff)
          && bDigest b == hashWith hasher (renderBinding b)
      _ -> False

-- | A Work Unit receipt for a unit of the bound Work Order, checked like a binding receipt.
admitWorkUnitException :: ProfileBinding -> AdmittedWorkUnit -> ExceptionReceipt -> Either ProfileRefusal ExceptionReceipt
admitWorkUnitException b unit receipt =
  let
    request = admittedRequest unit
    inScope = receiptTarget receipt == ForWorkUnit (wuId request) && wuWorkOrder request == bWorkOrder b
  in
    receipt <$ checkReceipt inScope (bProfile b) receipt

-- Mid-flight change (F10) -----------------------------------------------------

-- | A human's decision that a binding stands against these current sources.
data ProfileConfirmation
  = ProfileConfirmation ContentDigest [ProfileRef] T.Text
  deriving (Eq, Show)

mkProfileConfirmation :: Principal -> ProfileBinding -> [ProfileRef] -> T.Text -> Either ProfileRefusal ProfileConfirmation
mkProfileConfirmation principal b refs approver
  | principal /= Human = Left (BindingNotAuthorized principal)
  | not (validText approver) = Left (InvalidRecord (T.pack "a confirmation needs an approver"))
  | otherwise = Right (ProfileConfirmation (bDigest b) (L.sort (L.nub refs)) approver)

data Freshness
  = Fresh
  | ProfileChanged [ProfileId]
  deriving (Eq, Show)

bindingFreshness :: ProfileBinding -> [ProfileConfirmation] -> ProfileRef -> [ProfileRef] -> Freshness
bindingFreshness b confirmations currentDefault catalog =
  let
    sources = effSources (bProfile b)
    boundDefaults = [ref | (LayerRepositoryDefault, ref) <- sources]
    boundSpecializations = [ref | (LayerSpecialization, ref) <- sources]
    current ref = L.find ((== refId ref) . refId) (L.sortOn (Down . refVersion) catalog)
    changedIds =
      [refId ref | ref <- boundDefaults, ref /= currentDefault]
        <> [refId ref | ref <- boundSpecializations, current ref /= Just ref]
    currentSources = L.sort (L.nub (currentDefault : mapMaybe current boundSpecializations))
    confirmed (ProfileConfirmation digest refs _) = digest == bDigest b && refs == currentSources
  in
    if L.null changedIds || L.any confirmed confirmations
      then Fresh
      else ProfileChanged (L.sort (L.nub changedIds))

-- Gates (F2, F3, F7) ----------------------------------------------------------

-- | A validated observation of one artifact (the boundary checks its provenance and digest).
data GateEvidence
  = GateEvidence
  { evidenceArtifact :: ArtifactKind
  , evidenceDigest :: ContentDigest
  , evidenceVerifiedBy :: [VerifierKind]
  , evidenceApproval :: Approval
  }
  deriving (Eq, Show)

data GateBlock
  = MissingArtifact ArtifactKind
  | AmbiguousEvidence ArtifactKind
  | Unverified ArtifactKind [VerifierKind]
  | NeedsApproval ArtifactKind Approval
  deriving (Eq, Show)

data GateStatus
  = GateNotApplicable
  | GateSatisfied
  | GateExcepted ExceptionReceipt
  | GateBlocked GateBlock
  deriving (Eq, Show)

evaluateGate :: ProfileBinding -> [GateEvidence] -> Gate -> GateStatus
evaluateGate b evidence gate
  | not (gateApplies (effFacts (bProfile b)) gate) = GateNotApplicable
  | Just receipt <- L.find ((== gateId gate) . receiptGate) (bExceptions b) = GateExcepted receipt
  | otherwise =
      case mapMaybe artifactBlock (gateArtifacts gate) of
        block : _ -> GateBlocked block
        [] -> GateSatisfied
 where
  artifactBlock kind =
    let
      matching = L.filter ((== kind) . evidenceArtifact) evidence
      verified = L.concatMap evidenceVerifiedBy matching
      missing = L.filter (`L.notElem` verified) (gateVerifiers gate)
    in
      case L.nub (fmap evidenceDigest matching) of
        [] -> Just (MissingArtifact kind)
        [_]
          | not (L.null missing) -> Just (Unverified kind missing)
          | L.all ((< gateApproval gate) . evidenceApproval) matching -> Just (NeedsApproval kind (gateApproval gate))
          | otherwise -> Nothing
        _ -> Just (AmbiguousEvidence kind)

appliedAt :: GateStage -> ProfileBinding -> [Gate]
appliedAt stage b =
  L.filter
    (\g -> gateStage g == stage && gateApplies (effFacts (bProfile b)) g)
    (effGates (bProfile b))

-- | What the scheduler may require before execution (clarification 1).
executionPrerequisites :: ProfileBinding -> [Gate]
executionPrerequisites =
  appliedAt BeforeExecution

-- | The Work Unit's frozen post-verification gates.
acceptanceGateIds :: ProfileBinding -> [T.Text]
acceptanceGateIds =
  fmap (gateIdText . gateId) . appliedAt BeforeAcceptance

requiresFrozenTests :: ProfileBinding -> Bool
requiresFrozenTests b =
  case factsBehaviour (effFacts (bProfile b)) of
    BehaviourChanging -> True
    NonBehavioural _ -> False

-- | A non-behavioural binding may change only docs.
checkObservedPaths :: ProfileBinding -> [PathClass] -> Either ProfileRefusal ()
checkObservedPaths b observed =
  case factsBehaviour (effFacts (bProfile b)) of
    BehaviourChanging -> Right ()
    NonBehavioural _ ->
      case L.sortOn pathClassName (L.nub (L.filter (/= PathDocs) observed)) of
        [] -> Right ()
        outside -> Left (NonBehaviouralViolated outside)

-- Refusals --------------------------------------------------------------------

data ProfileRefusal
  = InvalidProfile T.Text
  | WeakensUniversalInvariant T.Text
  | GateUnsatisfiableBeforeExecution GateId
  | WeakensGate GateId T.Text
  | UnprovableStrengthening GateId T.Text
  | ProfileConflict T.Text
  | WeakensNonBehaviouralPolicy
  | ProfileUnavailable ProfileId
  | UntrustedClassification Principal
  | NonBehaviouralRefused T.Text
  | NonBehaviouralViolated [PathClass]
  | ExceptionNotHuman
  | ExceptionUnknownGate GateId
  | ExceptionNotApplicable GateId
  | ExceptionNotPermitted GateId
  | ExceptionOutOfScope
  | ExceptionProfileMismatch
  | BindingNotAuthorized Principal
  | InvalidRecord T.Text
  | InvalidFacts T.Text
  deriving (Eq, Show)

profileRefusalCode :: ProfileRefusal -> T.Text
profileRefusalCode refusal =
  T.pack $
    case refusal of
      InvalidProfile _ -> "invalid-profile"
      WeakensUniversalInvariant _ -> "weakens-universal-invariant"
      GateUnsatisfiableBeforeExecution _ -> "gate-unsatisfiable-before-execution"
      WeakensGate _ _ -> "weakens-gate"
      UnprovableStrengthening _ _ -> "unprovable-strengthening"
      ProfileConflict _ -> "profile-conflict"
      WeakensNonBehaviouralPolicy -> "weakens-profile"
      ProfileUnavailable _ -> "profile-unavailable"
      UntrustedClassification _ -> "untrusted-classification"
      NonBehaviouralRefused _ -> "non-behavioural-refused"
      NonBehaviouralViolated _ -> "non-behavioural-violated"
      ExceptionNotHuman -> "exception-not-human"
      ExceptionUnknownGate _ -> "exception-unknown-gate"
      ExceptionNotApplicable _ -> "exception-not-applicable"
      ExceptionNotPermitted _ -> "exception-not-permitted"
      ExceptionOutOfScope -> "exception-out-of-scope"
      ExceptionProfileMismatch -> "exception-profile-mismatch"
      BindingNotAuthorized _ -> "binding-not-authorized"
      InvalidRecord _ -> "invalid-record"
      InvalidFacts _ -> "invalid-facts"

renderProfileRefusal :: ProfileRefusal -> T.Text
renderProfileRefusal refusal =
  case refusal of
    InvalidProfile reason -> T.pack "the profile is invalid: " <> reason
    WeakensUniversalInvariant name -> T.pack "a profile cannot waive or redefine a universal invariant: " <> name
    GateUnsatisfiableBeforeExecution g -> T.pack "gate " <> gateIdText g <> T.pack " requires evidence that exists only after execution starts"
    WeakensGate g axis -> T.pack "gate " <> gateIdText g <> T.pack " would be weakened (" <> axis <> T.pack ")"
    UnprovableStrengthening g axis -> T.pack "gate " <> gateIdText g <> T.pack " changes " <> axis <> T.pack ", which cannot be proved stronger"
    ProfileConflict subject -> T.pack "two sources at one level disagree on " <> subject
    WeakensNonBehaviouralPolicy -> T.pack "a later layer cannot permit non-behavioural work again"
    ProfileUnavailable p -> T.pack "the specialization profile " <> profileIdText p <> T.pack " is not registered"
    UntrustedClassification p -> T.pack "only a human may classify work, not " <> showText p
    NonBehaviouralRefused reason -> reason
    NonBehaviouralViolated paths -> T.pack "non-behavioural work changed " <> joined pathClassName paths
    ExceptionNotHuman -> T.pack "only a human may grant an exception"
    ExceptionUnknownGate g -> T.pack "the effective profile has no gate " <> gateIdText g
    ExceptionNotApplicable g -> T.pack "gate " <> gateIdText g <> T.pack " does not apply to this work"
    ExceptionNotPermitted g -> T.pack "gate " <> gateIdText g <> T.pack " has no exception path"
    ExceptionOutOfScope -> T.pack "the exception is for other work"
    ExceptionProfileMismatch -> T.pack "the exception was granted against another effective profile"
    BindingNotAuthorized p -> T.pack "not authorized: " <> showText p
    InvalidRecord reason -> reason
    InvalidFacts reason -> T.pack "invalid work facts: " <> reason
