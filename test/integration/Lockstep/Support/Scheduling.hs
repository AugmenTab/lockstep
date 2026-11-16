{-# LANGUAGE OverloadedStrings #-}

{- | Shared fixtures for scheduling, engine and plan scenarios against real
PostgreSQL, Git and processes with scripted roles (Phase 6 update 2 and Gate
D). Modelled on the C-P6.5 and C-P6.6 suites' fixtures: a fresh database and
temporary folders per scenario; projects with real Git folders; approved plans;
scripted role answers chosen by the unit title the invocation's context names;
and engine worker passes until a condition holds.
-}
module Lockstep.Support.Scheduling
  ( -- * Scenarios
    Scenario (..)
  , withScenario
  , folders
  , accepted
  , ready
  , refusedWith
  , idemWith
  , gitIn
  , count
  , truth
  , headOf

    -- * Projects and plans
  , k
  , projectWith
  , useEngineering
  , unitOf
  , planOf
  , proposeIn
  , approveIn
  , tasksOf
  , taskOfUnit
  , markReady

    -- * Scripted roles
  , js
  , jsList
  , result
  , discovery
  , TestSpec (..)
  , candidate
  , fixes
  , fixesAll
  , review
  , noFindings
  , Scripts (..)
  , scriptsOf
  , valueTest
  , valueTitle
  , valueScripts
  , valueUnit
  , valueFiles
  , engineFor
  , passesUntil
  , stateOf
  , acceptedCount
  , fixOfTask
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory, createDirectoryIfMissing)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty.HUnit (assertBool, assertFailure, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Engine (Engine (..), TransactionView (..), transactionForWorkOrder, transactionView)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (Admission (..), enableExecution, findAdmission)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanDecision (..), ProposalRefusal, RevisionView (..), decidePlan, proposePlan)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), ExpectedChecks (..), chooseChecks)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (TaskDecision (..), TaskView (..), decideTask, listTasks)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter (..), Workspace (..), directRunner, scriptedAdapter)
import Lockstep.Kernel.Plan
  ( EffectClass (..)
  , Envelope (..)
  , PlanCriterion (..)
  , PlanDocument (..)
  , PlanEdge
  , PlanMode
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
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryBool, queryInts, requireAdmin, withFreshDatabase, withRuntime)

-- Scenarios ---------------------------------------------------------------------------------------

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  }

-- | A fresh, migrated database and temporary project and work folders.
withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-sched" $ \tmp -> do
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

-- | The action is refused with exactly this code.
refusedWith :: Show a => T.Text -> IO (Either T.Text a) -> IO ()
refusedWith code action =
  action >>= either (@?= code) (\a -> assertFailure ("expected " <> T.unpack code <> ", accepted: " <> show a))

-- | An idempotency key with a suite's prefix.
idemWith :: T.Text -> T.Text -> IO IdempotencyKey
idemWith prefix text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey (prefix <> text))

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

-- | @SELECT count(*) FROM <query>@.
count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

-- | @SELECT (<expression>) AS v@, a truth value.
truth :: Scenario -> String -> IO Bool
truth sc expression =
  queryBool (scAdmin sc) (scDb sc) ("SELECT (" <> expression <> ") AS v")

-- | The commit a ref names in the folder.
headOf :: FilePath -> String -> IO String
headOf folder ref =
  L.filter (/= '\n') <$> gitIn folder ["rev-parse", ref]

-- Projects and plans ------------------------------------------------------------------------------

k :: T.Text -> UnitKey
k text =
  case mkUnitKey text of
    Just u -> u
    Nothing -> k "invalid-key-in-test"

{- | A project whose folder holds these files in one commit on @main@,
allowed to run (with the Bug Profile) when asked; its view and folder.
-}
projectWith :: Scenario -> T.Text -> T.Text -> [(FilePath, String)] -> Bool -> IO (ProjectView, FilePath)
projectWith sc prefix name files enable = do
  pk <- idemWith prefix ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  traverse_ (\(path, content) -> createDirectoryIfMissing True (parentOf (folder <> "/" <> path)) >> writeFile (folder <> "/" <> path) content) files
  _ <- gitIn folder ("add" : fmap fst files)
  _ <- gitIn folder ["commit", "-q", "-m", "start"]
  when enable $ do
    ek <- idemWith prefix ("enable-" <> name)
    void (accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing)))
  pure (view, folder)

-- | The folder a path is in.
parentOf :: FilePath -> FilePath
parentOf path =
  L.reverse (L.drop 1 (L.dropWhile (/= '/') (L.reverse path)))

-- | The owner chooses Lockstep's engineering checks for the project (from the Bug Profile enabling set).
useEngineering :: Scenario -> ProjectView -> IO ()
useEngineering sc view =
  accepted (ready (chooseChecks (scRuntime sc) (projectId view) "lockstep-bug-fix" "lockstep-engineering" False)) >>= (@?= ChecksChosen)

-- | A local, provisional, low-risk unit: key, title, kind, Profile, one criterion, outputs.
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

planOf :: T.Text -> PlanMode -> [PlanUnit] -> [PlanEdge] -> PlanDocument
planOf title mode units edges =
  PlanDocument
    { planTitle = title
    , planMode = mode
    , planSources = [PlanSource "prd" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
    , planEnvelope = Envelope False 10 Nothing
    , planUnits = units
    , planEdges = edges
    , planUncertainties = []
    }

proposeIn :: Scenario -> T.Text -> ProjectView -> T.Text -> PlanDocument -> IO (Either ProposalRefusal RevisionView)
proposeIn sc prefix view name p = do
  ik <- idemWith prefix ("plan-" <> name)
  ready (proposePlan (scRuntime sc) ik (projectId view) "owner-session" (LBS.fromStrict (TE.encodeUtf8 (encodePlanDocument p))))

-- | Proposes and approves (once, by the owner) a plan; the approved revision.
approveIn :: Scenario -> T.Text -> ProjectView -> T.Text -> PlanDocument -> IO RevisionView
approveIn sc prefix view name p = do
  r <- proposeIn sc prefix view name p >>= either (\e -> assertFailure ("proposal refused: " <> show e)) pure
  accepted (ready (decidePlan (scRuntime sc) "owner-session" (projectId view) (revisionNumber r) (revisionDigest r) ApprovePlan))

tasksOf :: Scenario -> ProjectView -> IO [TaskView]
tasksOf sc view =
  ready (listTasks (scRuntime sc) (projectId view))

taskOfUnit :: Scenario -> ProjectView -> RevisionView -> T.Text -> IO TaskView
taskOfUnit sc view r name = do
  ts <- tasksOf sc view
  case L.lookup name (revisionTasks r) >>= \tid -> L.find ((== tid) . taskId) ts of
    Just t -> pure t
    Nothing -> assertFailure ("no task for unit " <> T.unpack name)

-- | A person marks a new task ready to work; the task as it then is.
markReady :: Scenario -> TaskView -> IO TaskView
markReady sc t =
  accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))

-- Scripted roles ----------------------------------------------------------------------------------

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
  T.replace "/" "." (fromMaybe path (T.stripSuffix ".py" path))

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

-- | The Implementer writes one file, then answers.
fixes :: T.Text -> T.Text -> T.Text
fixes path content =
  fixesAll [(path, content)]

-- | The Implementer writes these files, then answers.
fixesAll :: [(T.Text, T.Text)] -> T.Text
fixesAll files =
  T.concat ["{\"write\":{\"path\":" <> js path <> ",\"content\":" <> js content <> "}}," | (path, content) <- files]
    <> result "{\"kind\":\"implementation\",\"summary\":\"done as asked\"}"

review :: [T.Text] -> T.Text
review inspected =
  result ("{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"read it\"],\"inspected\":" <> jsList inspected <> "}")

noFindings :: T.Text
noFindings =
  result "{\"kind\":\"challenge\",\"findings\":[]}"

-- | A unit's scripts: the Planner's answers in order, the Implementer's change and the Reviewer's answer.
data Scripts
  = Scripts
  { scriptsPlanner :: [T.Text]
  , scriptsFix :: T.Text
  , scriptsReview :: T.Text
  }

scriptsOf :: Scripts -> Role -> [T.Text]
scriptsOf s role =
  case role of
    Planner -> scriptsPlanner s
    Challenger -> [noFindings, noFindings]
    Implementer -> [scriptsFix s]
    Reviewer -> [scriptsReview s]

-- | A unittest module asserting @module.value() == value@, failing with the message.
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

-- | The title of value unit @fN@.
valueTitle :: Int -> T.Text
valueTitle n =
  "Make f" <> T.pack (show n) <> " return " <> T.pack (show n)

{- | The happy scripts of value unit @fN@ (make @fN.value()@ return N), a
red-first bug fix: its title and scripts.
-}
valueScripts :: Int -> (T.Text, Scripts)
valueScripts n =
  ( valueTitle n
  , Scripts
      { scriptsPlanner =
          [ discovery file (Just ("import " <> f <> "; assert " <> f <> ".value() == " <> v <> ", '" <> wrong <> "'", wrong)) [file]
          , candidate criterion file [file] [TestSpec testFile (valueTest f v wrong) (Just wrong)]
          ]
      , scriptsFix = fixes file ("def value():\n    return " <> v <> "\n")
      , scriptsReview = review [file, testFile]
      }
  )
 where
  v = T.pack (show n)
  f = "f" <> v
  file = f <> ".py"
  testFile = "test_" <> file
  wrong = f <> " is wrong"
  criterion = f <> ".value() is " <> v <> "."

-- | Value unit @fN@ of a plan: a bug fix under the Bug Profile.
valueUnit :: Int -> PlanUnit
valueUnit n =
  unitOf ("f" <> v) (valueTitle n) "bug-fix" "lockstep-bug-fix" ("f" <> v <> ".value() is " <> v <> ".") ["f" <> v <> ".py"]
 where
  v = T.pack (show n)

-- | @f1.py@ to @fN.py@, each @value()@ returning 0.
valueFiles :: Int -> [(FilePath, String)]
valueFiles n =
  [("f" <> show i <> ".py", "def value():\n    return 0\n") | i <- [1 .. n]]

{- | An engine whose adapter reads the invocation's context and runs the n-th
script of the unit whose title it names (none: the role fails, as with no
helper).
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

-- | Engine worker passes (dispatch, start, advance) until the condition holds; at most @limit@ passes.
passesUntil :: Scenario -> Engine -> Int -> IO Bool -> IO ()
passesUntil sc engine limit done = do
  finished <- done
  case (finished, limit) of
    (True, _) -> pure ()
    (False, 0) -> do
      lastPass <- engineOnceWith (scRuntime sc) engine (folders sc)
      views <- traverse (\(i, _) -> transactionView (scRuntime sc) i) lastPass
      assertFailure
        ( "the condition did not hold within the passes allowed; the last pass: "
            <> show lastPass
            <> show [fmap (fmap (\v -> (viewStage v, viewHalt v, L.drop (L.length (viewRecords v) - 3) (viewRecords v)))) x | x <- views]
        )
    (False, _) -> do
      _ <- engineOnceWith (scRuntime sc) engine (folders sc)
      passesUntil sc engine (limit - 1) done

stateOf :: Scenario -> T.Text -> IO (Maybe T.Text)
stateOf sc workOrder =
  fmap viewState <$> ready (transactionForWorkOrder (scRuntime sc) workOrder)

acceptedCount :: Scenario -> IO Int
acceptedCount sc =
  count sc "lockstep_transactions WHERE state = 'accepted'"

-- | The latest fix of a task, once it was handed over and started.
fixOfTask :: Scenario -> T.Text -> IO TransactionView
fixOfTask sc task = do
  admission <- ready (findAdmission (scRuntime sc) task) >>= maybe (assertFailure "not handed over") pure
  ready (transactionForWorkOrder (scRuntime sc) (admissionWorkOrder admission)) >>= maybe (assertFailure "no fix") pure
