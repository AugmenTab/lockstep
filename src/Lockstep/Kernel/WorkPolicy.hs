{- | The work policy of each kind of engineering work (contract C-P6.6 G1–G3,
G5): its class tag, its legitimate test-first rule, whether a reproduction is
expected, whether it is non-behavioural, its budgets, the checks every Profile
for it must hold (its floor), the built-in Profile that holds every floor, and
the classification of a changed path. Pure.
-}
module Lockstep.Kernel.WorkPolicy
  ( TestFirst (..)
  , testFirstCode
  , WorkPolicy (..)
  , workPolicy
  , kindClass
  , kindFloor
  , engineeringProfileId
  , engineeringRaw
  , engineeringDefinition
  , missingChecks
  , floorStandings
  , pathClassOf
  , documentationOnly
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Execution (bugClass, bugFixRaw)
import Lockstep.Kernel.Plan (WorkKind (..), workKindCode)
import Lockstep.Kernel.Profile (Gate, PathClass (..), ProfileDefinition, ProfileRefusal (WeakensGate), RawGate (..), RawProfile (..), checkStronger, definitionGates, gateId, gateIdText, mkProfileDefinition)
import Lockstep.Kernel.Transaction (maxAttempts, maxCorrections)

-- | The legitimate test-first behaviour of a kind.
data TestFirst
  = -- | At least one frozen test fails at the basis for its stated reason: what is asked is not there yet.
    RedFirst
  | -- | Every frozen test passes at the basis and must still pass: behaviour is kept.
    GreenOnly
  deriving (Eq, Show, Enum, Bounded)

testFirstCode :: TestFirst -> T.Text
testFirstCode t =
  T.pack $
    case t of
      RedFirst -> "red-first"
      GreenOnly -> "green-only"

data WorkPolicy
  = WorkPolicy
  { policyKind :: WorkKind
  , policyClass :: T.Text
  , policyTestFirst :: TestFirst
  , policyReproduction :: Bool
  -- ^ Whether the discovery may name a reproduction.
  , policyNonBehavioural :: Bool
  , policyCorrections :: Int
  , policyAttempts :: Int
  }
  deriving (Eq, Show)

-- | G1. The budgets are the engine's own, for every kind.
workPolicy :: WorkKind -> WorkPolicy
workPolicy k =
  WorkPolicy
    { policyKind = k
    , policyClass = kindClass k
    , policyTestFirst = rule
    , policyReproduction = rule == RedFirst
    , policyNonBehavioural = k == Documentation
    , policyCorrections = maxCorrections
    , policyAttempts = maxAttempts
    }
 where
  rule = if k `L.elem` [Refactor, Documentation] then GreenOnly else RedFirst

kindClass :: WorkKind -> T.Text
kindClass k =
  case k of
    BugFix -> bugClass
    Feature -> T.pack "feature"
    GreenfieldBuild -> T.pack "greenfield"
    Refactor -> T.pack "refactor"
    Documentation -> T.pack "documentation"

-- | One floor check: engineering work of the kind's class, before acceptance, never excepted.
check :: WorkKind -> String -> [String] -> [String] -> String -> RawGate
check k name artifacts verifiers approval =
  RawGate
    { rawGateId = T.pack name
    , rawGateStage = T.pack "before-acceptance"
    , rawGateArtifacts = fmap T.pack artifacts
    , rawGateKinds = Just [T.pack "engineering"]
    , rawGateClasses = Just [kindClass k]
    , rawGatePathClasses = Nothing
    , rawGateVerifiers = fmap T.pack verifiers
    , rawGateApproval = T.pack approval
    , rawGateExceptionPath = False
    }

-- | G2: the checks every Profile used for this kind must hold unchanged.
kindFloor :: WorkKind -> [RawGate]
kindFloor k =
  case k of
    BugFix -> rawGates bugFixRaw
    Feature ->
      [ check k "feature-requirements" ["requirements-basis"] ["digest-check"] supervisor
      , check k "feature-tests" ["frozen-tests"] ["deterministic-command", "digest-check"] supervisor
      , check k "feature-verification" ["verification-record"] ["deterministic-command"] supervisor
      , check k "feature-review" ["review-record"] ["independent-review"] supervisor
      ]
    GreenfieldBuild ->
      [ check k "greenfield-requirements" ["requirements-basis", "architecture-assessment"] ["digest-check"] supervisor
      , check k "greenfield-tests" ["frozen-tests"] ["deterministic-command", "digest-check"] supervisor
      , check k "greenfield-verification" ["verification-record"] ["deterministic-command"] supervisor
      , check k "greenfield-review" ["review-record"] ["independent-review"] supervisor
      ]
    Refactor ->
      [ check k "refactor-authorization" ["human-approval"] ["digest-check"] "human"
      , check k "refactor-characterization" ["frozen-tests"] ["deterministic-command", "digest-check"] supervisor
      , check k "refactor-verification" ["regression-evidence", "verification-record"] ["deterministic-command"] supervisor
      , check k "refactor-review" ["review-record"] ["independent-review"] supervisor
      ]
    Documentation ->
      [ check k "documentation-classification" ["classification-rationale"] ["digest-check"] supervisor
      , check k "documentation-verification" ["verification-record"] ["deterministic-command"] supervisor
      , check k "documentation-review" ["review-record"] ["independent-review"] supervisor
      ]
 where
  supervisor = "supervisor"

engineeringProfileId :: T.Text
engineeringProfileId =
  T.pack "lockstep-engineering"

-- | G3: the built-in Profile that holds every kind's floor, allowing non-behavioural work.
engineeringRaw :: RawProfile
engineeringRaw =
  RawProfile
    { rawProfileId = engineeringProfileId
    , rawProfileVersion = 1
    , rawAllowsNonBehavioural = Just True
    , rawInvariantExceptions = []
    , rawGates = L.concatMap kindFloor [minBound .. maxBound]
    , rawSpecializations = []
    }

engineeringDefinition :: Either ProfileRefusal ProfileDefinition
engineeringDefinition =
  mkProfileDefinition engineeringRaw

{- | G4, Update 2 R6.4: the kind's floor checks these gates do not hold,
sorted by id ('floorStandings': only @as-required@ and @stronger@ hold).
-}
missingChecks :: WorkKind -> [Gate] -> [T.Text]
missingChecks k gates =
  [gate | (gate, standing) <- floorStandings k gates, standing `L.notElem` fmap T.pack ["as-required", "stronger"]]

{- | Update 2 R6.4: how these gates hold each floor check of the kind, by
value, sorted by id: @as-required@ (the same check), @stronger@ (the same id
and stage, every axis at least as strong, no exception path: the Profile
kernel's own comparison), @weaker@, @incomparable@ (another stage: a stage
change cannot be proved stronger) or @missing@. A floor that cannot be read
holds nothing.
-}
floorStandings :: WorkKind -> [Gate] -> [(T.Text, T.Text)]
floorStandings k gates =
  case mkProfileDefinition floorProfile of
    Left _ -> L.sort [(rawGateId g, T.pack "missing") | g <- kindFloor k]
    Right floorDefinition -> L.sortOn fst [(gateIdText (gateId g), standing g) | g <- definitionGates floorDefinition]
 where
  floorProfile = engineeringRaw {rawProfileId = T.pack "lockstep-floor-" <> workKindCode k, rawGates = kindFloor k}
  standing required =
    T.pack $
      case L.find ((== gateId required) . gateId) gates of
        Nothing -> "missing"
        Just g
          | g == required -> "as-required"
          | otherwise ->
              case checkStronger required g of
                Right () -> "stronger"
                Left (WeakensGate _ _) -> "weaker"
                Left _ -> "incomparable"

{- | G5 c (R-P6.6-2, R-P6.6-3): the class of a changed path, by its name,
conservatively. Dependency pins, build files, instructions for model roles and
agents, tests, and anything under a source folder come first; then only a
documentation extension, or a documentation name without one (the whole
name), is documentation.
-}
pathClassOf :: T.Text -> PathClass
pathClassOf path
  | name `L.elem` dependencyNames || extension == T.pack "lock" || pinned = PathDependencies
  | name `L.elem` buildNames || extension == T.pack "cabal" = PathBuild
  | name `L.elem` agentNames || L.any (`L.elem` agentDirectories) directories = PathConfiguration
  | L.any (`L.elem` testDirectories) directories || T.pack "test_" `T.isPrefixOf` name || L.any (`T.isInfixOf` base) [T.pack "_test", T.pack "test."] = PathTests
  | L.any (`L.elem` sourceDirectories) directories = PathSource
  | extension `L.elem` docExtensions = PathDocs
  | T.null extension && name `L.elem` docNames = PathDocs
  | extension `L.elem` configExtensions = PathConfiguration
  | otherwise = PathSource
 where
  lower = T.toLower path
  segments = T.splitOn (T.pack "/") lower
  directories = L.take (L.length segments - 1) segments
  name =
    case L.reverse segments of
      n : _ -> n
      [] -> lower
  (base, extension) =
    case T.breakOnEnd (T.pack ".") name of
      (prefix, ext)
        | T.length prefix > 1 -> (T.dropEnd 1 prefix, ext)
        | otherwise -> (name, T.empty)
  docExtensions = fmap T.pack ["md", "markdown", "rst", "adoc", "txt"]
  docNames = fmap T.pack ["readme", "changelog", "license", "notice", "authors", "contributing", "copying"]
  dependencyNames = fmap T.pack ["stack.yaml.lock", "package-lock.json", "yarn.lock", "cargo.lock", "poetry.lock", "requirements.txt", "go.sum", "gemfile.lock"]
  buildNames = fmap T.pack ["makefile", "dockerfile", "package.yaml", "stack.yaml", "cabal.project", "setup.py", "pyproject.toml", "build.gradle", "pom.xml", "cmakelists.txt"]
  testDirectories = fmap T.pack ["test", "tests", "spec"]
  -- Pinned requirements and constraints, in a file or a folder of them.
  pinned =
    (L.any ((`T.isPrefixOf` name) . T.pack) ["requirements", "constraints"] && extension `L.elem` fmap T.pack ["txt", "in"])
      || name == T.pack "runtime.txt"
      || L.any (`L.elem` fmap T.pack ["requirements", "constraints"]) directories
  -- Instructions later model roles or assistants read: never documentation.
  agentNames = fmap T.pack ["claude.md", "agents.md", "gemini.md", "copilot-instructions.md", ".cursorrules", ".windsurfrules"]
  agentDirectories = fmap T.pack [".claude", ".github", ".cursor"]
  sourceDirectories = fmap T.pack ["src", "lib"]
  configExtensions = fmap T.pack ["yaml", "yml", "toml", "json", "ini", "cfg", "conf"]

-- | Whether every path is documentation.
documentationOnly :: [T.Text] -> Bool
documentationOnly =
  L.all ((== PathDocs) . pathClassOf)
