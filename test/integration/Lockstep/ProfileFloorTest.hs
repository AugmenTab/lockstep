{-# LANGUAGE OverloadedStrings #-}

{- | Update 2 R6.4, effective Profile floors, against real PostgreSQL and Git:
a kind's floor is held by value, not by name — a project whose checks hold a
floor check more strongly runs the kind; checks that weaken one, drop one,
open an exception path on one or move it to another stage are refused; the
effective checks of a Work Unit are shown as they are (Profile, version, kind,
each floor check held as required or more strongly, exceptions, budgets); and
a Profile version added later binds no Work Unit already handed over, while a
weaker one refuses the next hand-over.
-}
module Lockstep.ProfileFloorTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.EffectiveChecks (EffectiveChecks (..), effectiveChecksOf)
import Lockstep.Application.Execution (Admission (..), admitBug)
import Lockstep.Application.Plans (RevisionView)
import Lockstep.Application.ProfileDocument (encodeRawProfile)
import Lockstep.Application.Profiles (addProfile)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), chooseChecks)
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (TaskView (..))
import Lockstep.Kernel.Plan (PlanMode (..))
import Lockstep.Kernel.Profile (RawGate (..), RawProfile (..))
import Lockstep.Kernel.WorkPolicy (engineeringRaw)
import Lockstep.Support.Scheduling (Scenario (..), accepted, approveIn, count, folders, idemWith, planOf, projectWith, ready, refusedWith, taskOfUnit, unitOf, useEngineering, withScenario)

tests :: TestTree
tests =
  testGroup
    "R6.4 effective Profile floors (real Git, PostgreSQL)"
    [ testCase "checks that hold a floor check more strongly run the kind; its effective checks say so (R6.4)" strongerAccepted
    , testCase "checks that weaken a floor check, drop one, open an exception path on one or move its stage are refused (R6.4)" weakerRefused
    , testCase "the engineering checks are shown as they are: Profile, version, kind, floor, exceptions, budgets (R6.4)" engineeringShown
    , testCase "a Profile version added later binds no Work Unit already handed over; a weaker one refuses the next (R6.4)" staleVersion
    ]

-- Fixtures ---------------------------------------------------------------------------------------

prefix :: T.Text
prefix =
  "test-profile-floor-"

idem :: T.Text -> IO IdempotencyKey
idem =
  idemWith prefix

-- | Lockstep's engineering checks under another id and version, with one change to the feature floor's checks.
variant :: T.Text -> Integer -> (RawGate -> RawGate) -> RawProfile
variant name version change =
  engineeringRaw {rawProfileId = name, rawProfileVersion = version, rawGates = fmap change (rawGates engineeringRaw)}

-- | Changes the named gate only.
onGate :: T.Text -> (RawGate -> RawGate) -> RawGate -> RawGate
onGate gate change g =
  if rawGateId g == gate then change g else g

register :: Scenario -> RawProfile -> IO ()
register sc raw =
  ready (addProfile (scRuntime sc) (LBS.fromStrict (TE.encodeUtf8 (encodeRawProfile raw))))
    >>= either (const (assertFailure ("profile " <> T.unpack (rawProfileId raw) <> " refused"))) (const (pure ()))

-- | A project whose checks are this registered Profile (chosen from the Bug Profile enabling set).
projectUsing :: Scenario -> T.Text -> RawProfile -> IO ProjectView
projectUsing sc name raw = do
  (view, _) <- projectWith sc prefix name [("f1.py", "def value():\n    return 0\n"), ("f2.py", "def value():\n    return 0\n")] True
  register sc raw
  accepted (ready (chooseChecks (scRuntime sc) (projectId view) "lockstep-bug-fix" (rawProfileId raw) False)) >>= (@?= ChecksChosen)
  pure view

-- | One feature unit f1 (and f2 when asked), naming the engineering checks.
featurePlan :: Scenario -> ProjectView -> T.Text -> [T.Text] -> IO RevisionView
featurePlan sc view name keys =
  approveIn sc prefix view name (planOfFeatures keys)
 where
  planOfFeatures ks =
    planOfUnits [unitOf key ("Make " <> key <> " return 1") "feature" "lockstep-engineering" (key <> ".value() is 1.") [key <> ".py"] | key <- ks]
  planOfUnits units =
    planOf "Values" Brownfield units []

handOver :: Scenario -> T.Text -> TaskView -> IO (Either T.Text Admission)
handOver sc key t = do
  ik <- idem key
  ready (admitBug (scRuntime sc) (folders sc) ik (taskId t) (taskTicketRevision t))

checksOf :: Scenario -> TaskView -> IO EffectiveChecks
checksOf sc t =
  ready (effectiveChecksOf (scRuntime sc) (taskId t)) >>= maybe (assertFailure "no effective checks shown") pure

-- Cases ------------------------------------------------------------------------------------------

strongerAccepted :: Assertion
strongerAccepted =
  withScenario $ \sc -> do
    -- The feature review needs a person's approval and a deterministic command too: stronger on two axes.
    view <- projectUsing sc "stronger" (variant "team-engineering" 1 (onGate "feature-review" (\g -> g {rawGateApproval = "human", rawGateVerifiers = rawGateVerifiers g <> ["deterministic-command"]})))
    r <- featurePlan sc view "stronger" ["f1"]
    f1 <- taskOfUnit sc view r "f1"
    _ <- accepted (handOver sc "admit-stronger" f1)
    count sc "lockstep_bug_admissions WHERE work_kind = 'feature'" >>= (@?= 1)
    shown <- checksOf sc f1
    (checksProfile shown, checksVersion shown, checksKind shown) @?= ("team-engineering", 1, "feature")
    L.lookup "feature-review" (checksFloor shown) @?= Just "stronger"
    L.lookup "feature-tests" (checksFloor shown) @?= Just "as-required"
    checksExceptions shown @?= []

weakerRefused :: Assertion
weakerRefused =
  withScenario $ \sc -> do
    let
      refusedFor name change = do
        view <- projectUsing sc name (variant name 1 change)
        r <- featurePlan sc view name ["f1"]
        f1 <- taskOfUnit sc view r "f1"
        refusedWith "kind-checks-missing" (fmap (fmap admissionWorkOrder) (handOver sc ("admit-" <> name) f1))
    refusedFor "weaker-approval" (onGate "feature-review" (\g -> g {rawGateApproval = "none"}))
    refusedFor "fewer-verifiers" (onGate "feature-tests" (\g -> g {rawGateVerifiers = ["digest-check"]}))
    refusedFor "exception-path" (onGate "feature-tests" (\g -> g {rawGateExceptionPath = True}))
    refusedFor "other-stage" (onGate "feature-review" (\g -> g {rawGateStage = "before-completion"}))
    view <- projectUsing sc "missing" engineeringRaw {rawProfileId = "missing", rawGates = L.filter ((/= "feature-tests") . rawGateId) (rawGates engineeringRaw)}
    r <- featurePlan sc view "missing" ["f1"]
    f1 <- taskOfUnit sc view r "f1"
    refusedWith "kind-checks-missing" (fmap (fmap admissionWorkOrder) (handOver sc "admit-missing" f1))
    count sc "lockstep_bug_admissions" >>= (@?= 0)

engineeringShown :: Assertion
engineeringShown =
  withScenario $ \sc -> do
    (view, _) <- projectWith sc prefix "engineering" [("f1.py", "def value():\n    return 0\n")] True
    useEngineering sc view
    r <- featurePlan sc view "engineering" ["f1"]
    f1 <- taskOfUnit sc view r "f1"
    _ <- accepted (handOver sc "admit-engineering" f1)
    shown <- checksOf sc f1
    (checksProfile shown, checksVersion shown, checksKind shown) @?= ("lockstep-engineering", 1, "feature")
    fmap fst (checksFloor shown) @?= ["feature-requirements", "feature-review", "feature-tests", "feature-verification"]
    L.all ((== "as-required") . snd) (checksFloor shown) @?= True
    (checksExceptions shown, checksCorrections shown, checksAttempts shown, checksNonBehavioural shown) @?= ([], 2, 2, False)

staleVersion :: Assertion
staleVersion =
  withScenario $ \sc -> do
    view <- projectUsing sc "versions" (variant "team-engineering" 1 id)
    r <- featurePlan sc view "versions" ["f1", "f2"]
    f1 <- taskOfUnit sc view r "f1"
    _ <- accepted (handOver sc "admit-v1" f1)
    -- A later, weaker version: the Work Unit already handed over keeps version 1; the next is refused.
    register sc (variant "team-engineering" 2 (onGate "feature-review" (\g -> g {rawGateApproval = "none"})))
    count sc "lockstep_work_order_profile_sources WHERE profile_id = 'team-engineering' AND version = 1" >>= (@?= 1)
    count sc "lockstep_work_order_profile_sources WHERE profile_id = 'team-engineering' AND version = 2" >>= (@?= 0)
    checksOf sc f1 >>= (@?= 1) . checksVersion
    f2 <- taskOfUnit sc view r "f2"
    refusedWith "kind-checks-missing" (fmap (fmap admissionWorkOrder) (handOver sc "admit-v2" f2))
