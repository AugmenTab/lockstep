{-# LANGUAGE OverloadedStrings #-}

{- | Update 2, DG-08 local Phase signoff (owner decision: option C, with B as
the default), against real PostgreSQL, Git and processes with scripted roles:
where the approved plan designates a human gate (a later phase's unit needs
the person's acceptance of an earlier phase's unit), automatic scheduling
never passes it until the person signs that unit off (Done); a boundary with
no gate advances provisionally; the gate is shown with where it stands; a
Planner refinement cannot remove a gate, while the owner's own revision may.
-}
module Lockstep.PhaseGateTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Conversation (Channel (..), Sender (..))
import Lockstep.Application.Engine (Engine (..), TransactionView (..), decideCompletion)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.PhaseGates (phaseGatesOf)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (DraftOutcome (..), DraftReport (..), draftPlansUntil, requestDraft)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (TaskView (..))
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (directRunner, scriptedAdapter)
import Lockstep.Kernel.Plan (EdgeKind (..), PlanDocument (..), PlanEdge (..), PlanMode (..), PlanSource (..), PlanUnit (..))
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Support.Scheduling (Scenario (..), accepted, acceptedCount, approveIn, count, engineFor, fixOfTask, folders, idemWith, k, passesUntil, planOf, projectWith, proposeIn, ready, tasksOf, valueFiles, valueScripts, valueTitle, valueUnit, withScenario)

tests :: TestTree
tests =
  testGroup
    "DG-08 Phase signoff where the plan designates a human gate (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a human gate holds the later phase's unit until the person signs off; a boundary without a gate advances provisionally (DG-08 C, B)" gateHolds
    , testCase "a Planner refinement that removes a human gate is refused; the owner's own revision may remove it (DG-08 C)" plannerCannotRemove
    ]

-- Fixtures ---------------------------------------------------------------------------------------

prefix :: T.Text
prefix =
  "test-phase-gate-"

-- | Value unit fN in this phase.
inPhase :: Int -> T.Text -> PlanUnit
inPhase n phase =
  (valueUnit n) {unitPhase = phase, unitSubphase = phase <> ".1"}

-- | f1 in P1; f2 in P2 behind a human gate on f1; f3 in P2 after f1 by a technical edge (no gate).
gated :: PlanDocument
gated =
  planOf "Values" Brownfield [inPhase 1 "P1", inPhase 2 "P2", inPhase 3 "P2"] [PlanEdge (k "f2") (k "f1") HumanAcceptance, PlanEdge (k "f3") (k "f1") Technical]

taskTitled :: Scenario -> ProjectView -> T.Text -> IO TaskView
taskTitled sc view title = do
  ts <- tasksOf sc view
  maybe (assertFailure ("no task " <> T.unpack title)) pure (L.find ((== title) . taskTitle) ts)

gatesOf :: Scenario -> ProjectView -> IO [(T.Text, T.Text, T.Text)]
gatesOf sc view =
  accepted (ready (phaseGatesOf (scRuntime sc) (projectId view)))

sha :: T.Text -> T.Text
sha text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

-- Cases ------------------------------------------------------------------------------------------

gateHolds :: Assertion
gateHolds =
  withScenario $ \sc -> do
    (view, _) <- projectWith sc prefix "gated" (valueFiles 3) True
    _ <- approveIn sc prefix view "gated" gated
    engine <- engineFor sc (fmap valueScripts [1, 2, 3])
    -- f1, then f3 past the ungated boundary, provisionally, with no Done.
    passesUntil sc engine 120 ((== 2) <$> acceptedCount sc)
    traverse_ (const (engineOnceWith (scRuntime sc) engine (folders sc))) [1 :: Int, 2, 3]
    count sc "lockstep_bug_admissions" >>= (@?= 2)
    count sc "lockstep_transactions WHERE state = 'done'" >>= (@?= 0)
    gatesOf sc view >>= (@?= [("f2", "f1", "waiting-for-signoff")])
    -- The person signs f1 off: the gate opens and the scheduler hands f2 over by itself.
    t1 <- taskTitled sc view (valueTitle 1)
    f1 <- fixOfTask sc (taskId t1)
    void (accepted (ready (decideCompletion (scRuntime sc) (viewId f1) (SenderHuman ApplicationChannel) "done")))
    passesUntil sc engine 120 ((== 3) <$> count sc "lockstep_transactions WHERE state IN ('accepted', 'done')")
    count sc "lockstep_bug_admissions WHERE actor = 'scheduler'" >>= (@?= 3)
    gatesOf sc view >>= (@?= [("f2", "f1", "signed-off")])

plannerCannotRemove :: Assertion
plannerCannotRemove =
  withScenario $ \sc -> do
    (view, _) <- projectWith sc prefix "refined" (valueFiles 3) True
    _ <- approveIn sc prefix view "refined" gated
    let
      prd = "# Values\n\nThree values, the second signed off after the first.\n"
      ungated = gated {planSources = [PlanSource "prd" (sha prd)], planEdges = [PlanEdge (k "f2") (k "f1") Technical, PlanEdge (k "f3") (k "f1") Technical]}
      answer = "{\"result\":{\"kind\":\"plan\",\"plan\":" <> encodePlanDocument ungated <> "}}"
    dk <- idemWith prefix "draft"
    _ <- accepted (ready (requestDraft (scRuntime sc) dk (projectId view) "owner-session" prd Nothing))
    cancel <- newCancel
    runner <- directRunner cancel (scTmp sc <> "/work")
    let
      planner = Engine runner (\role _ -> if role == Planner then Just (scriptedAdapter "scripts/runner/scripted-role" (TE.encodeUtf8 ("{\"steps\":[" <> answer <> "]}"))) else Nothing)
    reports <- ready (draftPlansUntil (scRuntime sc) planner (pure False))
    fmap reportOutcome reports @?= [DraftRefused ["human-gate-removed"]]
    count sc "lockstep_plan_revisions" >>= (@?= 1)
    gatesOf sc view >>= (@?= [("f2", "f1", "waiting-for-signoff")])
    -- The owner's own revision may remove the gate: it is their authority.
    owned <- proposeIn sc prefix view "owner-ungated" ungated
    case owned of
      Right _ -> pure ()
      Left e -> assertFailure ("the owner's revision was refused: " <> show e)
    count sc "lockstep_plan_revisions" >>= (@?= 2)
