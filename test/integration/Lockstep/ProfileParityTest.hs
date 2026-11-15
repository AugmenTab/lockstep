{-# LANGUAGE OverloadedStrings #-}

{- | Greenfield and brownfield Profile parity against real PostgreSQL, Git and
processes with scripted roles (contract C-P6.6): a feature, a greenfield
build, a refactor and a documentation change each run through the same engine
under the built-in engineering Profile, each by its own test-first rule; the
checks a kind needs are refused when the repository's or the unit's Profile
lacks them; a documentation change that touches behaviour, a reproduction for
a refactor and a greenfield unit in a brownfield plan are refused.
-}
module Lockstep.ProfileParityTest
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
import Lockstep.Application.Dispatch (DispatchReport (..), DispatchView (..), dispatchOnce, dispatchView)
import Lockstep.Application.Engine (Engine (..))
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (enableExecution)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), ProposalRefusal (..), RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), ExpectedChecks (..), chooseChecks)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter (..), Workspace (..), directRunner, scriptedAdapter)
import Lockstep.Kernel.Plan
  ( EffectClass (..)
  , Envelope (..)
  , PlanCriterion (..)
  , PlanDocument (..)
  , PlanMode (..)
  , PlanSource (..)
  , PlanUnit (..)
  , RiskClass (..)
  , UnitKey
  , mkUnitKey
  )
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P6.6 Profile parity (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a feature runs red-first under lockstep-engineering: classed feature, bound to the repository's Profile, accepted (G1, G3, G4)" featureRuns
    , testCase "a greenfield build creates its file red-first in a greenfield plan, through the same engine (G1, G5)" greenfieldRuns
    , testCase "a refactor is green-only: a red candidate is corrected, never accepted; the green one is (G1, G5 b)" refactorRuns
    , testCase "a documentation change is non-behavioural and green-only, accepted when it changes documentation only (G1, G5 c)" documentationRuns
    , testCase "classification: documentation that changes behaviour, a reproduction for a refactor, a greenfield unit in a brownfield plan are refused (G5, G6)" classification
    , testCase "a unit whose own Profile lacks its kind's checks is refused profile-too-weak, recorded and shown (G4 b)" namedProfileTooWeak
    , testCase "a repository whose Profile lacks a kind's checks refuses that kind kind-checks-missing; the plan page's choice makes it run (G3, G4 a)" repositoryLacksKind
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

-- Cases ------------------------------------------------------------------------------------------

featureRuns :: Assertion
featureRuns =
  withScenario $ \sc -> do
    view <- project sc "feature" True
    _ <- approved sc view "feature" (plan Brownfield [featureUnit])
    engine <- engineFor sc [("Make f1 return 1", featureScripts)]
    passesUntil sc engine 40 ((== 1) <$> acceptedCount sc)
    count sc "lockstep_bug_admissions WHERE work_kind = 'feature' AND actor = 'scheduler'" >>= (@?= 1)
    count sc "lockstep_work_orders WHERE classes = 'feature' AND non_behavioural_rationale IS NULL" >>= (@?= 1)
    -- Bound to the repository's Profile (lockstep-engineering), with the admission's digest.
    count sc "lockstep_work_order_profile_sources WHERE level = 'repository-default' AND profile_id = 'lockstep-engineering'" >>= (@?= 1)
    count sc "lockstep_bug_admissions a JOIN lockstep_work_orders w ON w.id = a.work_order_id WHERE a.effective_digest = w.effective_digest" >>= (@?= 1)

greenfieldRuns :: Assertion
greenfieldRuns =
  withScenario $ \sc -> do
    view <- project sc "greenfield" True
    let
      greenfield = unitOf "g" "Build g that returns 7" "greenfield" "lockstep-engineering" "g.value() is 7." ["g.py"]
      scripts =
        Scripts
          { scriptsPlanner =
              [ discovery "README.md" (Just ("import g", "No module named")) ["g.py"]
              , candidate "g.value() is 7." "README.md" ["g.py"] [TestSpec "test_g.py" (valueTest "g" "7" "g is wrong") (Just "No module named")]
              ]
          , scriptsFix = fixes "g.py" "def value():\n    return 7\n"
          , scriptsInspected = ["g.py", "test_g.py"]
          }
    _ <- approved sc view "greenfield" (plan Greenfield [greenfield])
    engine <- engineFor sc [("Build g that returns 7", scripts)]
    passesUntil sc engine 40 ((== 1) <$> acceptedCount sc)
    count sc "lockstep_bug_admissions WHERE work_kind = 'greenfield'" >>= (@?= 1)
    count sc "lockstep_work_orders WHERE classes = 'greenfield'" >>= (@?= 1)

refactorRuns :: Assertion
refactorRuns =
  withScenario $ \sc -> do
    view <- project sc "refactor" True
    let
      refactor = unitOf "f1" "Tidy f1" "refactor" "lockstep-engineering" "f1.value() stays 0." ["f1.py"]
      scripts =
        Scripts
          { scriptsPlanner =
              [ discovery "f1.py" Nothing ["f1.py"]
              , -- A test made to fail is not a refactor's: corrected.
                candidate "f1.value() stays 0." "f1.py" ["f1.py"] [TestSpec "test_f1.py" (valueTest "f1" "1" "f1 is wrong") (Just "f1 is wrong")]
              , candidate "f1.value() stays 0." "f1.py" ["f1.py"] [TestSpec "test_f1.py" (valueTest "f1" "0" "f1 changed") Nothing]
              ]
          , scriptsFix = fixes "f1.py" "def value():\n    return 1 - 1\n"
          , scriptsInspected = ["f1.py", "test_f1.py"]
          }
    _ <- approved sc view "refactor" (plan Brownfield [refactor])
    engine <- engineFor sc [("Tidy f1", scripts)]
    passesUntil sc engine 40 ((== 1) <$> acceptedCount sc)
    count sc "lockstep_transactions WHERE candidates_made = 2" >>= (@?= 1)
    count sc "lockstep_bug_admissions WHERE work_kind = 'refactor'" >>= (@?= 1)
    count sc "lockstep_work_orders WHERE classes = 'refactor'" >>= (@?= 1)

documentationRuns :: Assertion
documentationRuns =
  withScenario $ \sc -> do
    view <- project sc "docs" True
    let
      docs = unitOf "readme" "Describe the values" "documentation" "lockstep-engineering" "README.md says what each file returns." ["README.md"]
      scripts =
        Scripts
          { scriptsPlanner =
              [ discovery "README.md" Nothing ["README.md"]
              , candidate
                  "README.md says what each file returns."
                  "README.md"
                  ["README.md"]
                  [TestSpec "test_readme.py" "import unittest\n\n\nclass TestReadme(unittest.TestCase):\n    def test_title(self):\n        with open('README.md') as f:\n            self.assertIn('Values', f.read())\n" Nothing]
              ]
          , scriptsFix = fixes "README.md" "# Values\n\nEach file returns its number.\n"
          , scriptsInspected = ["README.md", "test_readme.py"]
          }
    _ <- approved sc view "docs" (plan Brownfield [docs])
    engine <- engineFor sc [("Describe the values", scripts)]
    passesUntil sc engine 40 ((== 1) <$> acceptedCount sc)
    count sc "lockstep_bug_admissions WHERE work_kind = 'documentation'" >>= (@?= 1)
    count sc "lockstep_work_orders WHERE classes = 'documentation' AND path_classes = 'docs' AND non_behavioural_rationale IS NOT NULL" >>= (@?= 1)

classification :: Assertion
classification =
  withScenario $ \sc -> do
    -- Documentation whose implementation changes code: never accepted.
    code <- project sc "code-as-docs" True
    let
      codeDocs = unitOf "doc" "Describe f1 in its code" "documentation" "lockstep-engineering" "f1.py explains itself." ["f1.py"]
      codeScripts =
        Scripts
          { scriptsPlanner =
              [ discovery "f1.py" Nothing ["f1.py"]
              , candidate "f1.py explains itself." "f1.py" ["f1.py"] [TestSpec "test_f1doc.py" (valueTest "f1" "0" "f1 changed") Nothing]
              ]
          , scriptsFix = fixes "f1.py" "# value returns zero\ndef value():\n    return 0\n"
          , scriptsInspected = ["f1.py", "test_f1doc.py"]
          }
    _ <- approved sc code "code-as-docs" (plan Brownfield [codeDocs])
    -- A refactor whose discovery names a reproduction: nothing is broken, so it halts.
    repro <- project sc "repro-refactor" True
    let
      reproRefactor = unitOf "f1" "Tidy with a check" "refactor" "lockstep-engineering" "f1.value() stays 0." ["f1.py"]
      reproScripts =
        Scripts
          { scriptsPlanner = [discovery "f1.py" (Just ("import f1; assert f1.value() == 1, 'f1 is wrong'", "f1 is wrong")) ["f1.py"]]
          , scriptsFix = fixes "f1.py" "def value():\n    return 0\n"
          , scriptsInspected = ["f1.py"]
          }
    _ <- approved sc repro "repro-refactor" (plan Brownfield [reproRefactor])
    engine <- engineFor sc [("Describe f1 in its code", codeScripts), ("Tidy with a check", reproScripts)]
    passesUntil sc engine 40 ((== 2) <$> count sc "lockstep_transactions WHERE state = 'halted'")
    haltedWith sc "supervisor-failed behaviour-in-documentation" >>= (@?= 1)
    haltedWith sc "role-failed reproduction-not-expected" >>= (@?= 1)
    acceptedCount sc >>= (@?= 0)
    -- A greenfield build in a brownfield plan is refused when it is proposed.
    brown <- project sc "brown" True
    refused <- propose sc brown "brown" (plan Brownfield [unitOf "g" "Build g" "greenfield" "lockstep-engineering" "g exists." ["g.py"]])
    either proposalRefusalCode (const "proposed") refused @?= "invalid-plan"

namedProfileTooWeak :: Assertion
namedProfileTooWeak =
  withScenario $ \sc -> do
    view <- project sc "weak" True
    -- A feature that names the Bug Profile, which holds none of a feature's checks.
    _ <- approved sc view "weak" (plan Brownfield [featureUnit {unitProfile = "lockstep-bug-fix"}])
    reports <- ready (dispatchOnce (scRuntime sc) (folders sc))
    fmap (\r -> (reportUnit r, reportResult r)) reports @?= [("f1", Left "profile-too-weak")]
    count sc "lockstep_bug_admissions" >>= (@?= 0)
    v <- accepted (ready (dispatchView (scRuntime sc) (projectId view)))
    dispatchViewWaiting v @?= [("f1", "refused")]

repositoryLacksKind :: Assertion
repositoryLacksKind =
  withScenario $ \sc -> do
    -- Enabled with the Bug Profile only.
    view <- project sc "lacking" False
    _ <- approved sc view "lacking" (plan Brownfield [featureUnit])
    reports <- ready (dispatchOnce (scRuntime sc) (folders sc))
    fmap (\r -> (reportUnit r, reportResult r)) reports @?= [("f1", Left "kind-checks-missing")]
    count sc "lockstep_bug_admissions" >>= (@?= 0)
    -- The owner chooses the engineering checks; the feature is then handed over and runs.
    useEngineering sc view
    engine <- engineFor sc [("Make f1 return 1", featureScripts)]
    passesUntil sc engine 40 ((== 1) <$> acceptedCount sc)
    count sc "lockstep_bug_admissions WHERE work_kind = 'feature'" >>= (@?= 1)
