{-# LANGUAGE OverloadedStrings #-}

{- | The independent review of C-P6.6 (R-P6.6) against real PostgreSQL, Git
and processes with scripted roles: a documentation change cannot bring
behaviour in through its frozen tests; a red-first kind never goes on with
only green tests; the repository's checks must hold a unit's own Profile; a
bug fix naming a weak Profile is refused; documentation names no
reproduction; and the built-in engineering checks cannot be replaced by a
document of the same name.
-}
module Lockstep.ProfileParityReviewTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Dispatch (DispatchReport (..), dispatchOnce)
import Lockstep.Application.Engine (Engine (..))
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (enableExecution)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), ProposalRefusal (..), RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.ProfileDocument (encodeRawProfile)
import Lockstep.Application.Profiles (ProfileFailure (..), addProfile)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), ExpectedChecks (..), chooseChecks)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter (..), Workspace (..), directRunner, scriptedAdapter)
import Lockstep.Kernel.Execution (bugFixRaw)
import Lockstep.Kernel.Plan (EffectClass (..), Envelope (..), PlanCriterion (..), PlanDocument (..), PlanMode (..), PlanSource (..), PlanUnit (..), RiskClass (..), UnitKey, WorkKind (Feature), mkUnitKey)
import Lockstep.Kernel.Profile (RawGate (..), RawProfile (..))
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Kernel.WorkPolicy (engineeringRaw, kindFloor)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "R-P6.6 review of Profile parity (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a documentation change whose frozen test sits at a source path is corrected and never accepted (R-P6.6-1)" docsTestAtSource
    , testCase "a feature whose candidate tests are all green is corrected until exhausted, never accepted (R-P6.6-4)" featureAllGreen
    , testCase "a unit's own Profile with a check the repository's lacks is refused profile-checks-missing (G4 c)" profileChecksMissing
    , testCase "a bug fix naming a Profile without the bug checks is refused profile-too-weak (G4 b)" weakBugProfile
    , testCase "a documentation discovery that names a reproduction halts reproduction-not-expected (G5 a)" docsReproduction
    , testCase "a document named lockstep-engineering that is not Lockstep's own is refused, and the owner's choice still gets the built-in checks (R-P6.6-7)" reservedEngineering
    ]

-- Fixtures ---------------------------------------------------------------------------------------

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p66" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/work")
        action (Scenario admin db runtime tmp)

folders :: Scenario -> ProjectFolders
folders sc =
  ProjectFolders (Just (scTmp sc <> "/projects")) []

accepted :: Show e => IO (Either e a) -> IO a
accepted action =
  action >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

idem :: T.Text -> IO IdempotencyKey
idem text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-profile-parity-" <> text))

gitIn :: FilePath -> [String] -> IO String
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  finished <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case finished of
    Nothing -> assertFailure ("git " <> show args <> " did not finish within 30 s")
    Just (code, out, err) -> do
      assertBool ("git " <> show args <> " failed: " <> out <> err) (code == ExitSuccess)
      pure out

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

k :: T.Text -> UnitKey
k text =
  case mkUnitKey text of
    Just u -> u
    Nothing -> k "invalid-key-in-test"

{- | A project whose folder holds f1.py (@value()@ returns 0) and README.md, allowed
to run; with the engineering checks chosen when asked.
-}
project :: Scenario -> T.Text -> Bool -> IO ProjectView
project sc name engineeringChecks = do
  pk <- idem ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/f1.py") "def value():\n    return 0\n"
  writeFile (folder <> "/README.md") "# Values\n"
  _ <- gitIn folder ["add", "f1.py", "README.md"]
  _ <- gitIn folder ["commit", "-q", "-m", "start"]
  ek <- idem ("enable-" <> name)
  void (accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing)))
  when engineeringChecks (useEngineering sc view)
  pure view

-- | The owner chooses Lockstep's engineering checks for the project (from the Bug Profile enabling set).
useEngineering :: Scenario -> ProjectView -> IO ()
useEngineering sc view =
  accepted (ready (chooseChecks (scRuntime sc) (projectId view) "lockstep-bug-fix" "lockstep-engineering" False)) >>= (@?= ChecksChosen)

unitOf :: T.Text -> T.Text -> T.Text -> T.Text -> T.Text -> [T.Text] -> PlanUnit
unitOf key title kind profile criterion outputs =
  PlanUnit
    { unitKey = k key
    , unitTitle = title
    , unitPhase = "P1"
    , unitSubphase = "P1.1"
    , unitWorkKind = kind
    , unitProfile = profile
    , unitPriority = Normal
    , unitEffect = LocalOnly
    , unitRisk = RiskLow
    , unitProvisional = True
    , unitOutputs = outputs
    , unitAcceptance = [PlanCriterion criterion ["prd"]]
    , unitNegative = []
    , unitChecks = []
    , unitPrerequisites = []
    , unitResources = []
    }

plan :: PlanMode -> [PlanUnit] -> PlanDocument
plan mode units =
  PlanDocument
    { planTitle = "Values"
    , planMode = mode
    , planSources = [PlanSource "prd" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
    , planEnvelope = Envelope False 10 Nothing
    , planUnits = units
    , planEdges = []
    , planUncertainties = []
    }

propose :: Scenario -> ProjectView -> T.Text -> PlanDocument -> IO (Either ProposalRefusal RevisionView)
propose sc view name p = do
  ik <- idem ("plan-" <> name)
  ready (proposePlan (scRuntime sc) ik (projectId view) "owner-session" (LBS.fromStrict (TE.encodeUtf8 (encodePlanDocument p))))

approved :: Scenario -> ProjectView -> T.Text -> PlanDocument -> IO RevisionView
approved sc view name p = do
  r <- propose sc view name p >>= either (\e -> assertFailure ("proposal refused: " <> show e)) pure
  accepted (ready (decidePlan (scRuntime sc) "owner-session" (projectId view) (revisionNumber r) (revisionDigest r) ApprovePlan))

-- Scripts ----------------------------------------------------------------------------------------

js :: T.Text -> T.Text
js text =
  "\"" <> T.concatMap escape text <> "\""
 where
  escape c =
    case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      _ -> T.singleton c

jsList :: [T.Text] -> T.Text
jsList xs =
  "[" <> T.intercalate "," (fmap js xs) <> "]"

result :: T.Text -> T.Text
result roleAnswer =
  "{\"result\":" <> roleAnswer <> "}"

stem :: T.Text -> T.Text
stem path =
  fromMaybe path (T.stripSuffix ".py" path)

-- | The Planner's discovery: a citation of line 1 of a file, an optional reproduction (command, signature), the allowed paths.
discovery :: T.Text -> Maybe (T.Text, T.Text) -> [T.Text] -> T.Text
discovery cite repro allowed =
  result
    ( "{\"kind\":\"discovery\",\"summary\":\"what is there\",\"hypothesis\":\"it needs the change\",\"citations\":[{\"path\":"
        <> js cite
        <> ",\"first\":1,\"last\":1}],"
        <> maybe "" (\(check, signature) -> "\"reproduction\":{\"argv\":[\"python3\",\"-c\"," <> js check <> "],\"signature\":" <> js signature <> "},") repro
        <> "\"allowed_paths\":"
        <> jsList allowed
        <> "}"
    )

data TestSpec
  = TestSpec
  { specPath :: T.Text
  , specContent :: T.Text
  , specRed :: Maybe T.Text
  -- ^ The signature of a test expected to fail at the basis; Nothing for one expected to pass.
  }

-- | The Planner's candidate: one criterion quoting the task, citing line 1 of a file; its tests.
candidate :: T.Text -> T.Text -> [T.Text] -> [TestSpec] -> T.Text
candidate quote cite allowed specs =
  result
    ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"c\",\"text\":"
        <> js quote
        <> ",\"ticket_quote\":"
        <> js quote
        <> ",\"citations\":[{\"path\":"
        <> js cite
        <> ",\"first\":1,\"last\":1}]}],\"allowed_paths\":"
        <> jsList allowed
        <> ",\"verification\":["
        <> T.intercalate "," ["[\"python3\",\"-m\",\"unittest\"," <> js (stem (specPath s)) <> "]" | s <- specs]
        <> "],\"tests\":["
        <> T.intercalate "," (fmap testJson specs)
        <> "]}"
    )
 where
  testJson s =
    "{\"path\":"
      <> js (specPath s)
      <> ",\"content\":"
      <> js (specContent s)
      <> ",\"expect\":"
      <> js (maybe "green" (const "red") (specRed s))
      <> ",\"argv\":[\"python3\",\"-m\",\"unittest\","
      <> js (stem (specPath s))
      <> "]"
      <> maybe "" (\signature -> ",\"signature\":" <> js signature) (specRed s)
      <> "}"

fixes :: T.Text -> T.Text -> T.Text
fixes path content =
  "{\"write\":{\"path\":" <> js path <> ",\"content\":" <> js content <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"done as asked\"}"

review :: [T.Text] -> T.Text
review inspected =
  result ("{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"read it\"],\"inspected\":" <> jsList inspected <> "}")

noFindings :: T.Text
noFindings =
  result "{\"kind\":\"challenge\",\"findings\":[]}"

-- | A unit's scripts: the Planner's answers in order, the Implementer's change and what the Reviewer read.
data Scripts
  = Scripts
  { scriptsPlanner :: [T.Text]
  , scriptsFix :: T.Text
  , scriptsInspected :: [T.Text]
  }

scriptsOf :: Scripts -> Role -> [T.Text]
scriptsOf s role =
  case role of
    Planner -> scriptsPlanner s
    Challenger -> [noFindings, noFindings]
    Implementer -> [scriptsFix s]
    Reviewer -> [review (scriptsInspected s)]

{- | An engine whose adapter reads the invocation's context and runs the n-th
script of the unit whose title it names (none: the role fails).
-}
engineFor :: Scenario -> [(T.Text, Scripts)] -> IO Engine
engineFor sc table = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    adapter role n =
      Adapter
        { adapterName = "scripted-by-title"
        , adapterPrepare = \workspace -> do
            context <- TE.decodeUtf8 <$> BS.readFile (workspaceInput workspace <> "/context.json")
            let
              chosen = L.find ((`T.isInfixOf` context) . fst) table >>= \(_, s) -> L.lookup n (L.zip [0 ..] (scriptsOf s role))
            adapterPrepare (scriptedAdapter "scripts/runner/scripted-role" (TE.encodeUtf8 ("{\"steps\":[" <> fromMaybe "" chosen <> "]}"))) workspace
        }
  pure (Engine runner (\role n -> Just (adapter role n)))

-- | Engine worker passes until the condition holds; at most @limit@ passes.
passesUntil :: Scenario -> Engine -> Int -> IO Bool -> IO ()
passesUntil sc engine limit done = do
  finished <- done
  case (finished, limit) of
    (True, _) -> pure ()
    (False, 0) -> do
      lastPass <- engineOnceWith (scRuntime sc) engine (folders sc)
      assertFailure ("the condition did not hold within the passes allowed; the last pass: " <> show lastPass)
    (False, _) -> do
      _ <- engineOnceWith (scRuntime sc) engine (folders sc)
      passesUntil sc engine (limit - 1) done

acceptedCount :: Scenario -> IO Int
acceptedCount sc =
  count sc "lockstep_transactions WHERE state = 'accepted'"

haltedWith :: Scenario -> String -> IO Int
haltedWith sc code =
  count sc ("lockstep_transactions WHERE state = 'halted' AND halt_code = '" <> code <> "'")

-- The units -------------------------------------------------------------------------------------

featureUnit :: PlanUnit
featureUnit =
  unitOf "f1" "Make f1 return 1" "feature" "lockstep-engineering" "f1.value() is 1." ["f1.py"]

featureScripts :: Scripts
featureScripts =
  Scripts
    { scriptsPlanner =
        [ discovery "f1.py" (Just ("import f1; assert f1.value() == 1, 'f1 is wrong'", "f1 is wrong")) ["f1.py"]
        , candidate "f1.value() is 1." "f1.py" ["f1.py"] [TestSpec "test_f1.py" (valueTest "f1" "1" "f1 is wrong") (Just "f1 is wrong")]
        ]
    , scriptsFix = fixes "f1.py" "def value():\n    return 1\n"
    , scriptsInspected = ["f1.py", "test_f1.py"]
    }

valueTest :: T.Text -> T.Text -> T.Text -> T.Text
valueTest module' value message =
  "import unittest\n\n\nclass TestValue(unittest.TestCase):\n    def test_value(self):\n        import "
    <> module'
    <> "\n        self.assertEqual("
    <> module'
    <> ".value(), "
    <> value
    <> ", '"
    <> message
    <> "')\n"

-- | A catalog Profile document, through the Profile document schema.
register :: Scenario -> RawProfile -> IO (Either ProfileFailure ())
register sc raw =
  fmap (const ()) <$> ready (addProfile (scRuntime sc) (LBS.fromStrict (TE.encodeUtf8 (encodeRawProfile raw))))

-- Cases ------------------------------------------------------------------------------------------

docsTestAtSource :: Assertion
docsTestAtSource =
  withScenario $ \sc -> do
    view <- project sc "docs-source" True
    let
      docs = unitOf "readme" "Describe the values" "documentation" "lockstep-engineering" "README.md says what each file returns." ["README.md"]
      -- A "test" that is a new module of the program: frozen, it would be behaviour no one asked for.
      sneaky = TestSpec "values.py" "import unittest\n\n\ndef value():\n    return 5\n\n\nclass TestNothing(unittest.TestCase):\n    def test_nothing(self):\n        self.assertTrue(True)\n" Nothing
      bad = candidate "README.md says what each file returns." "README.md" ["README.md"] [sneaky]
      scripts =
        Scripts
          { scriptsPlanner = [discovery "README.md" Nothing ["README.md"], bad, bad, bad]
          , scriptsFix = fixes "README.md" "# Values\n\nEach file returns its number.\n"
          , scriptsInspected = ["README.md", "values.py"]
          }
    _ <- approved sc view "docs-source" (plan Brownfield [docs])
    engine <- engineFor sc [("Describe the values", scripts)]
    passesUntil sc engine 40 ((== 1) <$> count sc "lockstep_transactions WHERE state IN ('halted', 'accepted')")
    acceptedCount sc >>= (@?= 0)
    haltedWith sc "candidates-exhausted" >>= (@?= 1)

featureAllGreen :: Assertion
featureAllGreen =
  withScenario $ \sc -> do
    view <- project sc "all-green" True
    let
      green = candidate "f1.value() is 1." "f1.py" ["f1.py"] [TestSpec "test_f1.py" (valueTest "f1" "0" "f1 changed") Nothing]
      scripts = featureScripts {scriptsPlanner = L.take 1 (scriptsPlanner featureScripts) <> [green, green, green]}
    _ <- approved sc view "all-green" (plan Brownfield [featureUnit])
    engine <- engineFor sc [("Make f1 return 1", scripts)]
    passesUntil sc engine 40 ((== 1) <$> count sc "lockstep_transactions WHERE state IN ('halted', 'accepted')")
    acceptedCount sc >>= (@?= 0)
    haltedWith sc "candidates-exhausted" >>= (@?= 1)

profileChecksMissing :: Assertion
profileChecksMissing =
  withScenario $ \sc -> do
    -- A team's bug checks: the Bug Profile's and one more.
    let
      audit =
        RawGate
          { rawGateId = "team-bug-audit"
          , rawGateStage = "before-acceptance"
          , rawGateArtifacts = ["review-record"]
          , rawGateKinds = Just ["engineering"]
          , rawGateClasses = Just ["bug"]
          , rawGatePathClasses = Nothing
          , rawGateVerifiers = ["human-inspection"]
          , rawGateApproval = "human"
          , rawGateExceptionPath = False
          }
    register sc bugFixRaw {rawProfileId = "team-bug", rawGates = rawGates bugFixRaw <> [audit]} >>= either (const (assertFailure "team-bug was refused")) pure
    -- The repository keeps the Bug Profile, which lacks the audit.
    view <- project sc "team" False
    _ <- approved sc view "team" (plan Brownfield [unitOf "f1" "Make f1 return 1" "bug-fix" "team-bug" "f1.value() is 1." ["f1.py"]])
    reports <- ready (dispatchOnce (scRuntime sc) (folders sc))
    fmap (\r -> (reportUnit r, reportResult r)) reports @?= [("f1", Left "profile-checks-missing")]
    count sc "lockstep_bug_admissions" >>= (@?= 0)

weakBugProfile :: Assertion
weakBugProfile =
  withScenario $ \sc -> do
    view <- project sc "basic" False
    _ <- approved sc view "basic" (plan Brownfield [unitOf "f1" "Make f1 return 1" "bug-fix" "lockstep-basic" "f1.value() is 1." ["f1.py"]])
    reports <- ready (dispatchOnce (scRuntime sc) (folders sc))
    fmap (\r -> (reportUnit r, reportResult r)) reports @?= [("f1", Left "profile-too-weak")]
    count sc "lockstep_bug_admissions" >>= (@?= 0)

docsReproduction :: Assertion
docsReproduction =
  withScenario $ \sc -> do
    view <- project sc "docs-repro" True
    let
      docs = unitOf "readme" "Describe the values" "documentation" "lockstep-engineering" "README.md says what each file returns." ["README.md"]
      scripts =
        Scripts
          { scriptsPlanner = [discovery "README.md" (Just ("import f1; assert f1.value() == 1, 'f1 is wrong'", "f1 is wrong")) ["README.md"]]
          , scriptsFix = fixes "README.md" "# Values\n"
          , scriptsInspected = ["README.md"]
          }
    _ <- approved sc view "docs-repro" (plan Brownfield [docs])
    engine <- engineFor sc [("Describe the values", scripts)]
    passesUntil sc engine 10 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    haltedWith sc "role-failed reproduction-not-expected" >>= (@?= 1)

reservedEngineering :: Assertion
reservedEngineering =
  withScenario $ \sc -> do
    -- A document claiming Lockstep's name with only a feature's checks.
    claimed <- register sc engineeringRaw {rawGates = kindFloor Feature}
    case claimed of
      Left (ProfileRefused code _ _) -> code @?= "profile-reserved"
      Left (ProfileIntegrity message) -> assertFailure ("integrity: " <> T.unpack message)
      Right () -> assertFailure "a document named lockstep-engineering that is not Lockstep's own was registered"
    count sc "lockstep_profiles WHERE profile_id = 'lockstep-engineering'" >>= (@?= 0)
    -- The owner's choice registers Lockstep's own, with every kind's checks.
    view <- project sc "reserved" False
    useEngineering sc view
    count sc "lockstep_profiles WHERE profile_id = 'lockstep-engineering' AND document LIKE '%documentation-review%' AND document LIKE '%refactor-authorization%'" >>= (@?= 1)
