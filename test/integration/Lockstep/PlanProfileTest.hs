{-# LANGUAGE OverloadedStrings #-}

{- | Update 2 R6.2, the first Work Unit's Profile, against real PostgreSQL, Git
and processes with scripted roles: a plan unit handed over by a person enters
the kind and Profile its approved unit names, exactly as the scheduler's
hand-over of the next unit does; a planned feature is a feature and a planned
documentation change keeps its non-behavioural obligations; repository checks
that do not cover the unit's kind refuse the person's hand-over as they refuse
the scheduler's (never a silent bug fix); a plain task is still a bug fix; the
kind stays bound across a replay and a restart.
-}
module Lockstep.PlanProfileTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Dispatch (DispatchReport (..), dispatchOnce)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (Admission (..), admitBug)
import Lockstep.Application.Plans (RevisionView)
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (NewTask (..), TaskView (..), createTask)
import Lockstep.Kernel.Plan (EdgeKind (..), PlanEdge (..), PlanMode (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Support.Postgres (databaseConfigFor, withRuntime)
import Lockstep.Support.Scheduling (Scenario (..), Scripts (..), TestSpec (..), accepted, acceptedCount, approveIn, candidate, count, discovery, engineFor, fixes, folders, idemWith, k, markReady, passesUntil, planOf, projectWith, ready, refusedWith, review, taskOfUnit, unitOf, useEngineering, valueTest, withScenario)

tests :: TestTree
tests =
  testGroup
    "R6.2 the first Work Unit's Profile (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a person hands the first greenfield unit over, the scheduler the second: both are greenfield work under the approved Profile, and both run (R6.2)" greenfieldFirstByPerson
    , testCase "a planned feature handed over by a person is a feature; a planned documentation change keeps its non-behavioural obligations; a replay and a restart keep the kind (R6.2)" plannedKinds
    , testCase "checks that do not cover the unit's kind refuse the person's hand-over as they refuse the scheduler's, never a bug fix instead; a plain task is still a bug fix (R6.2)" substitutionRefused
    ]

-- Fixtures ---------------------------------------------------------------------------------------

prefix :: T.Text
prefix =
  "test-plan-profile-"

idem :: T.Text -> IO IdempotencyKey
idem =
  idemWith prefix

-- | A project holding README.md (and f1.py), allowed to run; with the engineering checks when asked.
project :: Scenario -> T.Text -> Bool -> IO ProjectView
project sc name engineering = do
  (view, _) <- projectWith sc prefix name [("README.md", "# Values\n"), ("f1.py", "def value():\n    return 0\n")] True
  when engineering (useEngineering sc view)
  pure view

approved :: Scenario -> ProjectView -> T.Text -> PlanMode -> [(T.Text, T.Text, T.Text, T.Text, [T.Text])] -> [PlanEdge] -> IO RevisionView
approved sc view name mode units edges =
  approveIn sc prefix view name (planOf "Values" mode [unitOf key title kind "lockstep-engineering" criterion outputs | (key, title, kind, criterion, outputs) <- units] edges)

-- | A greenfield unit creating @gN.py@ whose @value()@ is N, red-first ("No module named").
greenfield :: Int -> (T.Text, Scripts)
greenfield n =
  ( "Build g" <> v <> " that returns " <> v
  , Scripts
      { scriptsPlanner =
          [ discovery "README.md" (Just ("import " <> g, "No module named")) [file]
          , candidate criterion "README.md" [file] [TestSpec ("test_" <> file) (valueTest g v (g <> " is wrong")) (Just "No module named")]
          ]
      , scriptsFix = fixes file ("def value():\n    return " <> v <> "\n")
      , scriptsReview = review [file, "test_" <> file]
      }
  )
 where
  v = T.pack (show n)
  g = "g" <> v
  file = g <> ".py"
  criterion = g <> ".value() is " <> v <> "."

-- | The person's hand-over of a task.
handOver :: Scenario -> T.Text -> TaskView -> IO (Either T.Text Admission)
handOver sc key t = do
  ik <- idem key
  ready (admitBug (scRuntime sc) (folders sc) ik (taskId t) (taskTicketRevision t))

-- Cases ------------------------------------------------------------------------------------------

greenfieldFirstByPerson :: Assertion
greenfieldFirstByPerson =
  withScenario $ \sc -> do
    view <- project sc "greenfield" True
    r <-
      approved
        sc
        view
        "greenfield"
        Greenfield
        [("g1", "Build g1 that returns 1", "greenfield", "g1.value() is 1.", ["g1.py"]), ("g2", "Build g2 that returns 2", "greenfield", "g2.value() is 2.", ["g2.py"])]
        [PlanEdge (k "g2") (k "g1") Technical]
    -- The person starts the first unit before the scheduler's first pass.
    g1 <- taskOfUnit sc view r "g1"
    _ <- accepted (handOver sc "admit-g1" g1)
    engine <- engineFor sc (fmap greenfield [1, 2])
    passesUntil sc engine 80 ((== 2) <$> acceptedCount sc)
    -- Both are greenfield work, classed greenfield; the second was the scheduler's.
    count sc "lockstep_bug_admissions WHERE work_kind = 'greenfield'" >>= (@?= 2)
    count sc "lockstep_bug_admissions WHERE work_kind = 'greenfield' AND actor = 'scheduler'" >>= (@?= 1)
    count sc "lockstep_work_orders WHERE classes = 'greenfield'" >>= (@?= 2)
    count sc "lockstep_bug_admissions WHERE work_kind = 'bug-fix'" >>= (@?= 0)
    -- Both bound to the repository's engineering checks.
    count sc "lockstep_work_order_profile_sources WHERE level = 'repository-default' AND profile_id = 'lockstep-engineering'" >>= (@?= 2)

plannedKinds :: Assertion
plannedKinds =
  withScenario $ \sc -> do
    view <- project sc "kinds" True
    r <-
      approved
        sc
        view
        "kinds"
        Brownfield
        [("f1", "Make f1 return 1", "feature", "f1.value() is 1.", ["f1.py"]), ("readme", "Describe the values", "documentation", "README.md says what each file returns.", ["README.md"])]
        []
    f1 <- taskOfUnit sc view r "f1"
    readme <- taskOfUnit sc view r "readme"
    a1 <- accepted (handOver sc "admit-f1" f1)
    _ <- accepted (handOver sc "admit-readme" readme)
    count sc "lockstep_bug_admissions WHERE work_kind = 'feature'" >>= (@?= 1)
    count sc "lockstep_work_orders WHERE classes = 'feature' AND non_behavioural_rationale IS NULL" >>= (@?= 1)
    count sc "lockstep_bug_admissions WHERE work_kind = 'documentation'" >>= (@?= 1)
    count sc "lockstep_work_orders WHERE classes = 'documentation' AND path_classes = 'docs' AND non_behavioural_rationale IS NOT NULL" >>= (@?= 1)
    -- A replay of the person's request is the same hand-over, of the same kind.
    again <- accepted (handOver sc "admit-f1" f1)
    admissionWorkOrder again @?= admissionWorkOrder a1
    count sc "lockstep_bug_admissions" >>= (@?= 2)
    -- A restart: the bound kind is read from the hand-over, unchanged.
    config <- databaseConfigFor (scAdmin sc) (scDb sc)
    engine <- engineFor sc []
    withRuntime config $ \runtime -> void (engineOnceWith runtime engine (folders sc))
    count sc "lockstep_bug_admissions WHERE work_kind = 'feature'" >>= (@?= 1)
    count sc "lockstep_work_orders WHERE classes = 'bug'" >>= (@?= 0)

substitutionRefused :: Assertion
substitutionRefused =
  withScenario $ \sc -> do
    -- Only the Bug Profile's checks: they do not cover a feature.
    view <- project sc "bug-only" False
    r <- approved sc view "bug-only" Brownfield [("f1", "Make f1 return 1", "feature", "f1.value() is 1.", ["f1.py"])] []
    f1 <- taskOfUnit sc view r "f1"
    refusedWith "kind-checks-missing" (fmap (fmap admissionWorkOrder) (handOver sc "admit-f1" f1))
    count sc "lockstep_bug_admissions" >>= (@?= 0)
    -- The scheduler is refused the same way.
    reports <- ready (dispatchOnce (scRuntime sc) (folders sc))
    fmap reportResult reports @?= [Left "kind-checks-missing"]
    count sc "lockstep_bug_admissions" >>= (@?= 0)
    -- A plain task is still a bug fix.
    tk <- idem "plain"
    t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) "Make f1 return 2" "f1.value() is 2." Normal [])))
    tReady <- markReady sc t
    _ <- accepted (handOver sc "admit-plain" tReady)
    count sc "lockstep_bug_admissions WHERE work_kind = 'bug-fix'" >>= (@?= 1)
    count sc "lockstep_work_orders WHERE classes = 'bug'" >>= (@?= 1)
