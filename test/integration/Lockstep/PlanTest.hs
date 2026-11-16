{-# LANGUAGE OverloadedStrings #-}

{- | The Master Plan against real PostgreSQL, Git and processes, with a
scripted Planner (contract C-P6.4 and the handoff §9 list): a realistic PRD
becomes a proposed multi-unit plan; invalid plans are refused with their
problems and store nothing; only the owner's digest-bound approval makes a
revision effective and turns its units into canonical tasks; revisions are
immutable and durable; a new PRD revision is reconciled.
-}
module Lockstep.PlanTest
  ( tests
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (isJust, isNothing)
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
import Lockstep.Application.Engine (Engine (..))
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans
  ( DraftOutcome (..)
  , DraftReport (..)
  , DraftView (..)
  , PlanDecision (..)
  , PlanView (..)
  , ProposalRefusal (..)
  , RevisionView (..)
  , decidePlan
  , draftPlans
  , planView
  , proposePlan
  , requestDraft
  )
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), ExpectedChecks (..), chooseChecks)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask, listTasks)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, directRunner, scriptedAdapter)
import Lockstep.Kernel.Plan
  ( EdgeKind (..)
  , EffectClass (..)
  , Envelope (..)
  , PlanCriterion (..)
  , PlanDocument (..)
  , PlanEdge (..)
  , PlanMode (..)
  , PlanSource (..)
  , PlanUnit (..)
  , RiskClass (..)
  , Uncertainty (..)
  , UnitKey
  , mkUnitKey
  , planDigestText
  , unitKeyText
  )
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..), TaskReadiness (..), priorityValue)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P6.4 the Master Plan (real PostgreSQL, Git, processes; scripted Planner)"
    [ testCase "a realistic PRD becomes one proposed five-unit plan by the Planner, with typed edges, citations and its uncertainty; nothing is a task yet (M1, M10, handoff: coherent DAG, unapproved cannot dispatch)" realisticDraft
    , testCase "a Planner plan whose sources are not the supplied documents, or that has a cycle, is refused with its problems and proposes nothing (M2, M10)" refusedDrafts
    , testCase "a person's proposal: a cycle and a missing dependency are refused with exact problems; nothing is stored (M2)" refusedProposals
    , testCase "proposals are idempotent: a replay returns the same revision, other content under a key is key-conflict, the same plan again is already-proposed (M4)" idempotentProposals
    , testCase "only a digest-bound approval by a person makes a revision effective; it turns each unit into a ready canonical task with the plan's dependencies (M5, M6)" approval
    , testCase "unauthorized edits create no effective plan: no person, wrong digest, decided, superseded, rejected; stored rows refuse changes (M4, M5, handoff)" unauthorized
    , testCase "an approved revision and its digest are stable across a restart (M3, M11)" durable
    , testCase "a new PRD revision is reconciled: units citing it change, technical descendants are invalidated, tasks are kept, uncertainties stay visible (M7, M8)" reconciliation
    , testCase "a plan-derived task is a task like any other: same view, readiness and hand-over as a ticket-derived one (M6, handoff: canonical parity)" parity
    , testCase "drafting is bounded: one attempt per draft, no helper invents nothing, an unfinished draft is never rerun (M10)" draftingBounded
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
    withSystemTempDirectory "lockstep-p64" $ \tmp -> do
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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-plan-key-" <> text))

gitIn :: FilePath -> [String] -> IO ()
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
    Just (code, out, err) -> assertBool ("git " <> show args <> " failed: " <> out <> err) (code == ExitSuccess)

-- | A project with one committed file (so it can be handed over).
project :: Scenario -> T.Text -> IO (ProjectView, FilePath)
project sc name = do
  pk <- idem ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/README.md") "Caesura\n"
  gitIn folder ["add", "README.md"]
  gitIn folder ["commit", "-q", "-m", "start"]
  pure (view, folder)

sha :: T.Text -> T.Text
sha text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

k :: T.Text -> UnitKey
k text =
  case mkUnitKey text of
    Just u -> u
    Nothing -> k "invalid-key-in-test"

prdText, prdText2, archText :: T.Text
prdText = "# Caesura\n\nCaesura checks the meter of a poem.\n\n1. Parse a poem into lines and syllables.\n2. A command line reads a file.\n3. Render a report.\n"
prdText2 = prdText <> "4. The report is also available as JSON.\n"
archText = "# Architecture\n\nA pure core, a thin CLI, a renderer.\n"

unit :: T.Text -> T.Text -> PlanUnit
unit name kind =
  PlanUnit
    { unitKey = k name
    , unitTitle = "Build the " <> name
    , unitPhase = "P1"
    , unitSubphase = "P1." <> name
    , unitWorkKind = kind
    , unitProfile = "lockstep-bug-fix"
    , unitPriority = Normal
    , unitEffect = LocalOnly
    , unitRisk = RiskNormal
    , unitProvisional = True
    , unitOutputs = ["src/" <> name]
    , unitAcceptance = [PlanCriterion ("The " <> name <> " does what the PRD says.") ["prd"]]
    , unitNegative = ["A malformed input to the " <> name <> " is refused."]
    , unitChecks = ["tests of the " <> name]
    , unitPrerequisites = []
    , unitResources = []
    }

-- | The Caesura-shaped plan for these PRD and architecture texts: five units; only "core" cites the architecture.
caesura :: T.Text -> PlanDocument
caesura prd =
  PlanDocument
    { planTitle = "Caesura"
    , planMode = Greenfield
    , planSources = [PlanSource "prd" (sha prd), PlanSource "architecture" (sha archText)]
    , planEnvelope = Envelope False 10 Nothing
    , planUnits =
        [ (unit "core" "greenfield") {unitPriority = High, unitAcceptance = [PlanCriterion "Lines and syllables are parsed." ["prd", "architecture"]]}
        , unit "cli" "feature"
        , unit "render" "feature"
        , unit "docs" "documentation"
        , unit "suite" "feature"
        ]
    , planEdges =
        [ PlanEdge (k "cli") (k "core") Technical
        , PlanEdge (k "render") (k "core") Technical
        , PlanEdge (k "docs") (k "cli") HumanAcceptance
        , PlanEdge (k "suite") (k "cli") Technical
        , PlanEdge (k "suite") (k "render") Technical
        ]
    , planUncertainties = [Uncertainty "The PRD names syllables but not stress; the meter rule is unclear." ["prd"]]
    }

planJson :: PlanDocument -> T.Text
planJson =
  encodePlanDocument

bytesOf :: PlanDocument -> LBS.ByteString
bytesOf =
  LBS.fromStrict . TE.encodeUtf8 . planJson

-- | A scripted Planner answer carrying a plan.
planAnswer :: PlanDocument -> T.Text
planAnswer p =
  "{\"result\":{\"kind\":\"plan\",\"plan\":" <> planJson p <> "}}"

-- | An engine whose Planner answers, at its n-th invocation, the n-th script (none: no helper).
engineWith :: Scenario -> [T.Text] -> IO Engine
engineWith sc plannerAnswers = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    pick n = scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] plannerAnswers)
    adapter :: Role -> Int -> Maybe Adapter
    adapter role n =
      case role of
        Planner -> pick n
        _ -> Nothing
  pure (Engine runner adapter)

script :: T.Text -> BS.ByteString
script steps' =
  TE.encodeUtf8 ("{\"steps\":[" <> steps' <> "]}")

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

refusedSql :: Scenario -> String -> Assertion
refusedSql sc statement = do
  result <- try (adminExecute (scAdmin sc) (T.unpack (scDb sc)) statement) :: IO (Either SomeException ())
  assertBool ("the database accepted: " <> statement) (either (const True) (const False) result)

viewOf :: Scenario -> ProjectView -> IO PlanView
viewOf sc view =
  accepted (ready (planView (scRuntime sc) (projectId view)))

revision :: PlanView -> Int -> IO RevisionView
revision pv n =
  case L.filter ((== n) . revisionNumber) (planViewRevisions pv) of
    [r] -> pure r
    _ -> assertFailure ("no revision " <> show n)

propose :: Scenario -> ProjectView -> T.Text -> PlanDocument -> IO (Either ProposalRefusal RevisionView)
propose sc view name p = do
  ik <- idem name
  ready (proposePlan (scRuntime sc) ik (projectId view) "owner-session" (bytesOf p))

approve :: Scenario -> ProjectView -> RevisionView -> IO (Either T.Text RevisionView)
approve sc view r =
  ready (decidePlan (scRuntime sc) "owner-session" (projectId view) (revisionNumber r) (revisionDigest r) ApprovePlan)

tasksOf :: Scenario -> ProjectView -> IO [TaskView]
tasksOf sc view =
  ready (listTasks (scRuntime sc) (projectId view))

taskFor :: RevisionView -> [TaskView] -> T.Text -> IO TaskView
taskFor r ts name =
  case L.lookup name (revisionTasks r) of
    Nothing -> assertFailure ("no task for unit " <> T.unpack name)
    Just tid -> maybe (assertFailure "task not listed") pure (L.find ((== tid) . taskId) ts)

draft :: Scenario -> ProjectView -> T.Text -> T.Text -> IO DraftView
draft sc view name prd = do
  ik <- idem ("draft-" <> name)
  accepted (ready (requestDraft (scRuntime sc) ik (projectId view) "owner-session" prd (Just archText)))

drafting :: Scenario -> Engine -> IO [DraftReport]
drafting sc engine =
  ready (draftPlans (scRuntime sc) engine)

-- Cases ------------------------------------------------------------------------------------------

realisticDraft :: Assertion
realisticDraft =
  withScenario $ \sc -> do
    (view, _) <- project sc "caesura"
    d <- draft sc view "first" prdText
    draftPrdDigest d @?= sha prdText
    engine <- engineWith sc [planAnswer (caesura prdText)]
    reports <- drafting sc engine
    fmap reportOutcome reports @?= [DraftProposed 1]
    pv <- viewOf sc view
    r <- revision pv 1
    revisionState r @?= "proposed"
    revisionProposedBy r @?= "Planner"
    revisionDigest r @?= planDigestText sha256Hasher (caesura prdText)
    L.sort (fmap (unitKeyText . unitKey) (planUnits (revisionDocument r))) @?= ["cli", "core", "docs", "render", "suite"]
    L.length (planEdges (revisionDocument r)) @?= 5
    assertBool "the human-acceptance edge is kept typed" (PlanEdge (k "docs") (k "cli") HumanAcceptance `L.elem` planEdges (revisionDocument r))
    fmap uncertaintyText (planUncertainties (revisionDocument r)) @?= ["The PRD names syllables but not stress; the meter rule is unclear."]
    assertBool "a proposal is effective" (isNothing (planViewEffective pv))
    -- Unapproved: no task exists, so nothing can be handed over or run.
    count sc "lockstep_project_tasks" >>= (@?= 0)
    count sc "lockstep_plan_units" >>= (@?= 0)
    count sc "lockstep_work_orders" >>= (@?= 0)
    -- The draft is finished once, with its outcome.
    fmap draftOutcome (planViewDrafts pv) @?= [Just "proposed"]
    drafting sc engine >>= (@?= [])

refusedDrafts :: Assertion
refusedDrafts =
  withScenario $ \sc -> do
    (view, _) <- project sc "caesura"
    _ <- draft sc view "forged" prdText
    _ <- draft sc view "cyclic" prdText2
    let
      forged = (caesura prdText) {planSources = [PlanSource "prd" (sha "another PRD"), PlanSource "architecture" (sha archText)]}
      cyclic = (caesura prdText2) {planEdges = planEdges (caesura prdText2) <> [PlanEdge (k "core") (k "suite") Technical]}
    engine <- engineWith sc [planAnswer forged, planAnswer cyclic]
    reports <- drafting sc engine
    fmap reportOutcome reports
      @?= [ DraftRefused ["source-digest-mismatch: prd"]
          , DraftRefused ["cycle: cli needs core, core needs suite, suite needs cli"]
          ]
    count sc "lockstep_plan_revisions" >>= (@?= 0)
    pv <- viewOf sc view
    fmap draftOutcome (planViewDrafts pv) @?= [Just "refused", Just "refused"]
    assertBool "the refusal's problems are kept" (L.all (isJust . draftCode) (planViewDrafts pv))

refusedProposals :: Assertion
refusedProposals =
  withScenario $ \sc -> do
    (view, _) <- project sc "caesura"
    let
      base = caesura prdText
      cyclic = base {planEdges = planEdges base <> [PlanEdge (k "core") (k "suite") Technical]}
      missing = base {planEdges = planEdges base <> [PlanEdge (k "suite") (k "parser") Technical]}
    propose sc view "cyclic" cyclic >>= (@?= Left (ProposalRefusal "invalid-plan" ["cycle: cli needs core, core needs suite, suite needs cli"]))
    propose sc view "missing" missing >>= (@?= Left (ProposalRefusal "invalid-plan" ["unknown-unit: parser"]))
    ik <- idem "garbage"
    ready (proposePlan (scRuntime sc) ik (projectId view) "owner-session" "{\"format\":\"lockstep-plan\",\"version\":1,\"approved\":true}")
      >>= \r -> fmap proposalRefusalCode (either Just (const Nothing) r) @?= Just "malformed"
    ready (proposePlan (scRuntime sc) ik "00000000-0000-4000-8000-000000000000" "owner-session" (bytesOf base))
      >>= \r -> fmap proposalRefusalCode (either Just (const Nothing) r) @?= Just "unknown-project"
    count sc "lockstep_plan_revisions" >>= (@?= 0)
    count sc "lockstep_plans" >>= (@?= 0)

idempotentProposals :: Assertion
idempotentProposals =
  withScenario $ \sc -> do
    (view, _) <- project sc "caesura"
    first <- accepted (propose sc view "one" (caesura prdText))
    revisionNumber first @?= 1
    revisionProposedBy first @?= "Human"
    again <- accepted (propose sc view "one" (caesura prdText))
    (revisionNumber again, revisionDigest again) @?= (1, revisionDigest first)
    propose sc view "one" (caesura prdText2) >>= (@?= Left (ProposalRefusal "key-conflict" []))
    propose sc view "two" (caesura prdText) >>= (@?= Left (ProposalRefusal "already-proposed" []))
    second <- accepted (propose sc view "three" (caesura prdText2))
    revisionNumber second @?= 2
    count sc "lockstep_plan_revisions" >>= (@?= 2)

approval :: Assertion
approval =
  withScenario $ \sc -> do
    (view, _) <- project sc "caesura"
    r <- accepted (propose sc view "one" (caesura prdText))
    ready (decidePlan (scRuntime sc) "owner-session" (projectId view) 1 (sha "not the plan") ApprovePlan) >>= (@?= Left "stale-digest")
    count sc "lockstep_project_tasks" >>= (@?= 0)
    approved <- accepted (approve sc view r)
    revisionState approved @?= "approved"
    pv <- viewOf sc view
    fmap revisionNumber (planViewEffective pv) @?= Just 1
    ts <- tasksOf sc view
    L.length ts @?= 5
    core <- taskFor approved ts "core"
    cli <- taskFor approved ts "cli"
    suite <- taskFor approved ts "suite"
    render <- taskFor approved ts "render"
    docs <- taskFor approved ts "docs"
    -- The approval accepted every unit as ready work; the graph decides what can start.
    taskState core @?= "ready"
    taskReadinessOf core @?= ReadyToWork
    taskReadinessOf cli @?= WaitingFor [taskTitle core]
    L.sort (taskDependencies suite) @?= L.sort [taskId cli, taskId render]
    taskDependencies docs @?= [taskId cli]
    taskPriority core @?= priorityValue High
    taskPriority cli @?= priorityValue Normal
    taskTitle core @?= "Build the core"
    assertBool "acceptance carried" ("Lines and syllables are parsed." `T.isInfixOf` taskAcceptance core)
    -- Units and typed edges are recorded with the revision.
    count sc "lockstep_plan_units" >>= (@?= 5)
    count sc "lockstep_plan_edges WHERE kind = 'human-acceptance'" >>= (@?= 1)
    count sc "lockstep_plan_edges WHERE kind = 'technical'" >>= (@?= 4)
    count sc "lockstep_plan_reconciliations WHERE outcome = 'added'" >>= (@?= 5)
    -- The person's approval is the Ticket acceptance: principal Human.
    count sc ("lockstep_events WHERE subject_id = '" <> T.unpack (taskId core) <> "' AND command = 'accept' AND principal = 'human'") >>= (@?= 1)
    taskReadinessOf render @?= WaitingFor [taskTitle core]
    -- Approving again is already-decided.
    approve sc view r >>= (@?= Left "already-decided")

unauthorized :: Assertion
unauthorized =
  withScenario $ \sc -> do
    (view, _) <- project sc "caesura"
    r1 <- accepted (propose sc view "one" (caesura prdText))
    ready (decidePlan (scRuntime sc) "" (projectId view) 1 (revisionDigest r1) ApprovePlan) >>= (@?= Left "forbidden")
    ready (decidePlan (scRuntime sc) "owner-session" (projectId view) 7 (revisionDigest r1) ApprovePlan) >>= (@?= Left "unknown-revision")
    rejected <- accepted (ready (decidePlan (scRuntime sc) "owner-session" (projectId view) 1 (revisionDigest r1) RejectPlan))
    revisionState rejected @?= "rejected"
    approve sc view r1 >>= (@?= Left "already-decided")
    pv1 <- viewOf sc view
    assertBool "a rejected revision is effective" (isNothing (planViewEffective pv1))
    count sc "lockstep_project_tasks" >>= (@?= 0)
    -- Two proposals; the newer is approved; the older can no longer be.
    r2 <- accepted (propose sc view "two" (caesura prdText2))
    r3 <- accepted (propose sc view "three" (caesura prdText2) {planTitle = "Caesura, again"})
    _ <- accepted (approve sc view r3)
    approve sc view r2 >>= (@?= Left "superseded")
    pv <- viewOf sc view
    fmap revisionNumber (planViewEffective pv) @?= Just 3
    -- Stored plan rows refuse every change.
    refusedSql sc "UPDATE lockstep_plan_revisions SET document = '{}'"
    refusedSql sc "DELETE FROM lockstep_plan_revisions"
    refusedSql sc "UPDATE lockstep_plan_decisions SET decision = 'approved'"
    refusedSql sc "DELETE FROM lockstep_plan_decisions"
    refusedSql sc "UPDATE lockstep_plan_units SET unit_digest = repeat('0', 64)"
    refusedSql sc "DELETE FROM lockstep_plan_edges"
    refusedSql sc "TRUNCATE lockstep_plan_reconciliations"
    refusedSql sc ("INSERT INTO lockstep_plan_decisions (revision_id, decision, digest, actor) SELECT id, 'approved', '" <> T.unpack (sha "x") <> "', 'forger' FROM lockstep_plan_revisions WHERE revision_number = 2")

durable :: Assertion
durable =
  withScenario $ \sc -> do
    (view, _) <- project sc "caesura"
    r <- accepted (propose sc view "one" (caesura prdText))
    _ <- accepted (approve sc view r)
    before <- viewOf sc view
    config <- databaseConfigFor (scAdmin sc) (scDb sc)
    after <-
      withRuntime config $ \runtime ->
        accepted (ready (planView runtime (projectId view)))
    fmap revisionDigest (planViewEffective after) @?= Just (revisionDigest r)
    fmap revisionDigest (planViewEffective after) @?= fmap revisionDigest (planViewEffective before)
    fmap revisionDocument (planViewEffective after) @?= Just (caesura prdText)
    fmap revisionTasks (planViewEffective after) @?= fmap revisionTasks (planViewEffective before)
    revisionDigest r @?= planDigestText sha256Hasher (caesura prdText)

reconciliation :: Assertion
reconciliation =
  withScenario $ \sc -> do
    (view, _) <- project sc "caesura"
    r1 <- accepted (propose sc view "one" (caesura prdText))
    a1 <- accepted (approve sc view r1)
    -- A new PRD revision: every unit cites the PRD, so every unit changes; with a new architecture only core would.
    let
      onlyArch = (caesura prdText) {planSources = [PlanSource "prd" (sha prdText), PlanSource "architecture" (sha (archText <> "v2"))]}
    r2 <- accepted (propose sc view "two" onlyArch)
    a2 <- accepted (approve sc view r2)
    L.sort (revisionReconciliation a2)
      @?= [("cli", "invalidated"), ("core", "changed"), ("docs", "kept"), ("render", "invalidated"), ("suite", "invalidated")]
    -- Units keep their tasks.
    L.sort (revisionTasks a2) @?= L.sort (revisionTasks a1)
    count sc "lockstep_project_tasks" >>= (@?= 5)
    r3 <- accepted (propose sc view "three" (caesura prdText2) {planSources = [PlanSource "prd" (sha prdText2), PlanSource "architecture" (sha (archText <> "v2"))]})
    a3 <- accepted (approve sc view r3)
    L.sort (revisionReconciliation a3)
      @?= [("cli", "changed"), ("core", "changed"), ("docs", "changed"), ("render", "changed"), ("suite", "changed")]
    pv <- viewOf sc view
    fmap revisionState (L.sortOn revisionNumber (planViewRevisions pv)) @?= ["superseded", "superseded", "approved"]
    -- The uncertainty stays visible on every revision, approved or not.
    traverse_ (\r -> L.length (planUncertainties (revisionDocument r)) @?= 1) (planViewRevisions pv)

parity :: Assertion
parity =
  withScenario $ \sc -> do
    (view, _) <- project sc "caesura"
    -- A-U2-1 (Update 2 R6.2): core names the engineering checks, and the project uses them.
    let
      engineeringCore p = p {planUnits = [if unitKey u == k "core" then u {unitProfile = "lockstep-engineering"} else u | u <- planUnits p]}
    r <- accepted (propose sc view "one" (engineeringCore (caesura prdText)))
    approved <- accepted (approve sc view r)
    ek <- idem "enable"
    _ <- accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing))
    accepted (ready (chooseChecks (scRuntime sc) (projectId view) "lockstep-bug-fix" "lockstep-engineering" False)) >>= (@?= ChecksChosen)
    tk <- idem "ticket"
    ticket <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) "A ticket" "It works." Normal [])))
    ticketReady <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId ticket) (taskTicketRevision ticket) MarkReady))
    ts <- tasksOf sc view
    core <- taskFor approved ts "core"
    -- Same kind of record, same readiness rule, same hand-over.
    (taskState core, taskReadinessOf core) @?= (taskState ticketReady, taskReadinessOf ticketReady)
    ak1 <- idem "admit-core"
    a1 <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak1 (taskId core) (taskTicketRevision core)))
    ak2 <- idem "admit-ticket"
    a2 <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak2 (taskId ticketReady) (taskTicketRevision ticketReady)))
    assertBool "two Work Orders" (admissionWorkOrder a1 /= admissionWorkOrder a2)
    count sc "lockstep_bug_admissions" >>= (@?= 2)
    -- A-U2-1: the plan task is handed over as the greenfield work its unit names; the ticket as a bug fix.
    count sc "lockstep_bug_admissions WHERE work_kind = 'greenfield'" >>= (@?= 1)
    count sc "lockstep_bug_admissions WHERE work_kind = 'bug-fix'" >>= (@?= 1)
    -- A plan task that is waiting is refused like any waiting task.
    cli <- taskFor approved ts "cli"
    ak3 <- idem "admit-cli"
    ready (admitBug (scRuntime sc) (folders sc) ak3 (taskId cli) (taskTicketRevision cli)) >>= (@?= Left "task-waiting") . fmap admissionWorkOrder

draftingBounded :: Assertion
draftingBounded =
  withScenario $ \sc -> do
    (view, _) <- project sc "caesura"
    d1 <- draft sc view "no-helper" prdText
    noHelper <- engineWith sc []
    drafting sc noHelper >>= (@?= [DraftNoHelper]) . fmap reportOutcome
    count sc "lockstep_plan_revisions" >>= (@?= 0)
    -- Replaying the request returns the same draft; other content under the key is key-conflict.
    ik <- idem "draft-no-helper"
    again <- accepted (ready (requestDraft (scRuntime sc) ik (projectId view) "owner-session" prdText (Just archText)))
    draftId again @?= draftId d1
    ready (requestDraft (scRuntime sc) ik (projectId view) "owner-session" prdText2 (Just archText)) >>= (@?= Left "key-conflict") . fmap draftId
    -- A draft a stopped worker left started is finished uncertain and never run.
    d2 <- draft sc view "interrupted" prdText2
    adminExecute (scAdmin sc) (T.unpack (scDb sc)) ("UPDATE lockstep_plan_drafts SET started_at = now() WHERE id = '" <> T.unpack (draftId d2) <> "'")
    engine <- engineWith sc [planAnswer (caesura prdText2)]
    drafting sc engine >>= (@?= [DraftUncertain]) . fmap reportOutcome
    count sc "lockstep_plan_revisions" >>= (@?= 0)
    drafting sc engine >>= (@?= [])
    pv <- viewOf sc view
    L.sort (fmap draftOutcome (planViewDrafts pv)) @?= [Just "no-helper", Just "uncertain"]
