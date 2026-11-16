{-# LANGUAGE OverloadedStrings #-}

{- | Update 2 R6.1, the authoritative dependency and Git basis, against real
PostgreSQL, Git and processes with scripted roles: a planned unit builds on its
predecessor's exact accepted commit whatever the person's checkout holds, also
across a restart; a dependency recorded the older way (an untyped task
dependency) or through a typed edge that needs the person's Done builds on the
predecessor's accepted commit too, never on the checkout; a predecessor commit
that is gone refuses the hand-over; a rejected ancestor leaves nothing
eligible; a busy writer holds only its own repository; standalone work still
builds on the repository's current commit.
-}
module Lockstep.AuthoritativeBasisTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO (FilePath, writeFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Conversation (Channel (..), Sender (..))
import Lockstep.Application.Dispatch (DispatchReport (..), DispatchView (..), dispatchOnce, dispatchView)
import Lockstep.Application.Engine (TransactionView (..), decideCompletion)
import Lockstep.Application.EngineWorker (engineOnceWith)
import Lockstep.Application.Execution (Admission (..), admitBug)
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (NewTask (..), TaskView (..), createTask)
import Lockstep.Kernel.Plan (EdgeKind (..), PlanEdge (..), PlanMode (..))
import Lockstep.Kernel.Task (Priority (..), TaskReadiness (..))
import Lockstep.Support.Postgres (databaseConfigFor, withRuntime)
import Lockstep.Support.Scheduling (Scenario (..), Scripts, accepted, acceptedCount, approveIn, count, engineFor, fixOfTask, folders, gitIn, headOf, idemWith, k, markReady, passesUntil, planOf, projectWith, ready, refusedWith, tasksOf, valueFiles, valueScripts, valueTitle, valueUnit, withScenario)

tests :: TestTree
tests =
  testGroup
    "R6.1 authoritative dependency and Git basis (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a planned unit builds on its predecessor's exact accepted commit, not on a newer checkout; a restart and more passes do not change it (R6.1 1, 8)" plannedBasis
    , testCase "an untyped task dependency and a typed edge that needs the person's Done both build on the predecessor's accepted commit, recorded as the basis (R6.1 2, 3)" legacyAndTypedBases
    , testCase "a predecessor's accepted commit that is gone refuses the hand-over with its reason; nothing is handed over (R6.1 4)" missingBasisRefused
    , testCase "a rejected ancestor leaves its invalidated descendant's dependents ineligible, for the scheduler and for a person (R6.1 9)" rejectedAncestor
    , testCase "a busy writer holds only its own repository; standalone work elsewhere builds on that repository's current commit (R6.1 5, 6, 7)" writerAndStandalone
    ]

-- Fixtures ---------------------------------------------------------------------------------------

idem :: T.Text -> IO IdempotencyKey
idem =
  idemWith "test-git-basis-"

project :: Scenario -> T.Text -> IO (ProjectView, FilePath)
project sc name =
  projectWith sc "test-git-basis-" name (valueFiles 3) True

approved :: Scenario -> ProjectView -> T.Text -> [Int] -> [PlanEdge] -> IO ()
approved sc view name units edges =
  void (approveIn sc "test-git-basis-" view name (planOf "Values" Brownfield (fmap valueUnit units) edges))

-- | The scripts of the three value units.
table :: [(T.Text, Scripts)]
table =
  fmap valueScripts [1, 2, 3]

basisOf :: TransactionView -> IO String
basisOf v =
  maybe (assertFailure "the fix has no basis") (pure . T.unpack) (viewBasis v)

-- | The accepted commit of a fix: its work branch's head once accepted.
acceptedCommitOf :: FilePath -> TransactionView -> IO String
acceptedCommitOf folder v =
  maybe (assertFailure "the fix has no branch") (headOf folder . T.unpack) (viewBranch v)

done :: Scenario -> TransactionView -> IO ()
done sc v =
  void (accepted (ready (decideCompletion (scRuntime sc) (viewId v) (SenderHuman ApplicationChannel) "done")))

-- Cases ------------------------------------------------------------------------------------------

plannedBasis :: Assertion
plannedBasis =
  withScenario $ \sc -> do
    (view, folder) <- project sc "planned"
    approved sc view "planned" [1, 2] [PlanEdge (k "f2") (k "f1") Technical]
    engine <- engineFor sc table
    passesUntil sc engine 60 ((== 1) <$> acceptedCount sc)
    -- The person moves their checkout on meanwhile: a commit Lockstep did not make.
    writeFile (folder <> "/notes.md") "# Notes\n"
    _ <- gitIn folder ["add", "notes.md"]
    _ <- gitIn folder ["commit", "-q", "-m", "the person's own work"]
    checkout <- headOf folder "HEAD"
    passesUntil sc engine 60 ((== 2) <$> acceptedCount sc)
    f1 <- unitFixBy sc view "Make f1 return 1"
    f2 <- unitFixBy sc view "Make f2 return 2"
    predecessor <- acceptedCommitOf folder f1
    basis <- basisOf f2
    basis @?= predecessor
    assertBool "the dependent was built on the person's checkout" (basis /= checkout)
    count sc "lockstep_fix_bases" >>= (@?= 1)
    -- A restart and more passes change nothing: the basis is recorded once.
    config <- databaseConfigFor (scAdmin sc) (scDb sc)
    withRuntime config $ \runtime -> traverse_ (const (engineOnceWith runtime engine (folders sc))) [1 :: Int, 2, 3]
    again <- unitFixBy sc view "Make f2 return 2"
    viewBasis again @?= viewBasis f2
    count sc "lockstep_transaction_records WHERE kind = 'basis'" >>= (@?= 2)
    count sc "lockstep_bug_admissions" >>= (@?= 2)

legacyAndTypedBases :: Assertion
legacyAndTypedBases =
  withScenario $ \sc -> do
    engine <- engineFor sc table
    -- The older way: two ordinary tasks, the second depending on the first (no plan, no kind).
    (plain, plainFolder) <- project sc "untyped"
    ta <- idem "task-a"
    a <- accepted (ready (createTask (scRuntime sc) (NewTask ta (projectId plain) (valueTitle 1) "f1.value() is 1." Normal [])))
    aReady <- markReady sc a
    tb <- idem "task-b"
    b <- accepted (ready (createTask (scRuntime sc) (NewTask tb (projectId plain) (valueTitle 2) "f2.value() is 2." Normal [taskId a])))
    bReady <- markReady sc b
    ak <- idem "admit-a"
    _ <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId aReady) (taskTicketRevision aReady)))
    passesUntil sc engine 60 ((== 1) <$> acceptedCount sc)
    fixA <- fixOfTask sc (taskId a)
    done sc fixA
    bk <- idem "admit-b"
    _ <- accepted (ready (admitBug (scRuntime sc) (folders sc) bk (taskId bReady) (taskTicketRevision bReady)))
    passesUntil sc engine 60 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'accepted'")
    fixB <- fixOfTask sc (taskId b)
    predecessorA <- acceptedCommitOf plainFolder fixA
    basisB <- basisOf fixB
    checkoutA <- headOf plainFolder "HEAD"
    basisB @?= predecessorA
    assertBool "the untyped dependent was built on the person's checkout" (basisB /= checkoutA)
    -- Its branch has the predecessor's work, which the checkout never had.
    bBranch <- maybe (assertFailure "no branch") (pure . T.unpack) (viewBranch fixB)
    gitIn plainFolder ["show", bBranch <> ":f1.py"] >>= (@?= "def value():\n    return 1\n")
    gitIn plainFolder ["show", "HEAD:f1.py"] >>= (@?= "def value():\n    return 0\n")
    -- A typed edge that needs the person's Done: the same rule.
    (typed, typedFolder) <- project sc "typed"
    approved sc typed "typed" [1, 2] [PlanEdge (k "f2") (k "f1") HumanAcceptance]
    passesUntil sc engine 60 ((== 1) <$> count sc ("lockstep_transactions t JOIN lockstep_bug_admissions x ON x.work_order_id = t.work_order_id WHERE t.state = 'accepted' AND x.project_id = '" <> T.unpack (projectId typed) <> "'"))
    typedF1 <- unitFixBy sc typed "Make f1 return 1"
    done sc typedF1
    passesUntil sc engine 60 ((== 2) <$> count sc ("lockstep_transactions t JOIN lockstep_bug_admissions x ON x.work_order_id = t.work_order_id WHERE t.state IN ('accepted', 'done') AND x.project_id = '" <> T.unpack (projectId typed) <> "'"))
    typedF2 <- unitFixBy sc typed "Make f2 return 2"
    predecessorTyped <- acceptedCommitOf typedFolder typedF1
    basisTyped <- basisOf typedF2
    basisTyped @?= predecessorTyped
    -- Both recorded as the dependent's basis provenance.
    count sc "lockstep_fix_bases" >>= (@?= 2)

missingBasisRefused :: Assertion
missingBasisRefused =
  withScenario $ \sc -> do
    (view, folder) <- project sc "missing"
    approved sc view "missing" [1, 2] [PlanEdge (k "f2") (k "f1") Technical]
    engine <- engineFor sc table
    passesUntil sc engine 60 ((== 1) <$> acceptedCount sc)
    f1 <- unitFixBy sc view "Make f1 return 1"
    branch <- maybe (assertFailure "no branch") (pure . T.unpack) (viewBranch f1)
    -- The accepted commit is removed from the repository behind Lockstep's back.
    _ <- gitIn folder ["branch", "-D", branch]
    _ <- gitIn folder ["reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all"]
    _ <- gitIn folder ["gc", "-q", "--prune=now"]
    reports <- ready (dispatchOnce (scRuntime sc) (folders sc))
    fmap reportResult reports @?= [Left "prerequisite-basis-missing"]
    count sc "lockstep_bug_admissions" >>= (@?= 1)
    v <- accepted (ready (dispatchView (scRuntime sc) (projectId view)))
    dispatchViewRefusal v @?= Just ("f2", "prerequisite-basis-missing")
    -- Never built on the checkout instead: still nothing handed over after more passes.
    traverse_ (const (engineOnceWith (scRuntime sc) engine (folders sc))) [1 :: Int, 2, 3]
    count sc "lockstep_bug_admissions" >>= (@?= 1)
    count sc "lockstep_transactions" >>= (@?= 1)

rejectedAncestor :: Assertion
rejectedAncestor =
  withScenario $ \sc -> do
    (view, _) <- project sc "rejected"
    approved sc view "rejected" [1, 2, 3] [PlanEdge (k "f2") (k "f1") Technical, PlanEdge (k "f3") (k "f2") Technical]
    engine <- engineFor sc table
    passesUntil sc engine 120 ((== 2) <$> acceptedCount sc)
    f1 <- unitFixBy sc view "Make f1 return 1"
    void (accepted (ready (decideCompletion (scRuntime sc) (viewId f1) (SenderHuman ApplicationChannel) "not-done")))
    count sc "lockstep_fix_invalidations" >>= (@?= 1)
    -- f3 depends on the invalidated f2: never handed over, by the scheduler or by a person.
    traverse_ (const (engineOnceWith (scRuntime sc) engine (folders sc))) [1 :: Int, 2, 3]
    count sc "lockstep_bug_admissions" >>= (@?= 2)
    ts <- tasksOf sc view
    t3 <- maybe (assertFailure "no f3 task") pure (L.find ((== valueTitle 3) . taskTitle) ts)
    taskReadinessOf t3 @?= WaitingFor [valueTitle 2]
    pk <- idem "admit-f3"
    refusedWith "task-waiting" (fmap (fmap admissionWorkOrder) (ready (admitBug (scRuntime sc) (folders sc) pk (taskId t3) (taskTicketRevision t3))))
    v <- accepted (ready (dispatchView (scRuntime sc) (projectId view)))
    L.sort (dispatchViewWaiting v) @?= [("f1", "stopped"), ("f2", "invalidated"), ("f3", "waiting-for")]

writerAndStandalone :: Assertion
writerAndStandalone =
  withScenario $ \sc -> do
    (busy, busyFolder) <- project sc "busy"
    approved sc busy "busy" [1, 2] []
    -- An uncommitted file: the busy project's first fix halts at its basis and keeps the writer.
    writeFile (busyFolder <> "/notes.txt") "uncommitted\n"
    (other, otherFolder) <- project sc "standalone"
    st <- idem "standalone"
    s <- accepted (ready (createTask (scRuntime sc) (NewTask st (projectId other) (valueTitle 3) "f3.value() is 3." Normal [])))
    sReady <- markReady sc s
    sk <- idem "admit-standalone"
    _ <- accepted (ready (admitBug (scRuntime sc) (folders sc) sk (taskId sReady) (taskTicketRevision sReady)))
    checkout <- headOf otherFolder "HEAD"
    engine <- engineFor sc table
    passesUntil sc engine 80 ((== 1) <$> acceptedCount sc)
    count sc "lockstep_transactions WHERE state = 'halted'" >>= (@?= 1)
    v <- accepted (ready (dispatchView (scRuntime sc) (projectId busy)))
    L.sort (dispatchViewWaiting v) @?= [("f1", "handed-over"), ("f2", "writer-busy")]
    standalone <- fixOfTask sc (taskId s)
    basisOf standalone >>= (@?= checkout)
    count sc "lockstep_fix_bases" >>= (@?= 0)

-- | The fix of the task with this title in the project.
unitFixBy :: Scenario -> ProjectView -> T.Text -> IO TransactionView
unitFixBy sc view title = do
  ts <- tasksOf sc view
  case L.find ((== title) . taskTitle) ts of
    Just t -> fixOfTask sc (taskId t)
    Nothing -> assertFailure ("no task " <> T.unpack title)
