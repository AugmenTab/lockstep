{-# LANGUAGE OverloadedStrings #-}

{- | Update 2 R6.6, improvement proposal integrity, against real PostgreSQL
and Git: commit evidence must be a commit a Lockstep fix recorded (the
well-formed hash of any other commit is refused, never shown as evidence); a
Profile rule must target a Profile Lockstep knows, at its current version; a
proposal whose target has moved on may still be rejected (a terminal decision
that authorizes nothing) but never approved; deciding writes only the
decision.
-}
module Lockstep.ProposalIntegrityTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Conversation (Channel (..), Sender (..))
import Lockstep.Application.Engine (TransactionView (..))
import Lockstep.Application.ProfileDocument (encodeRawProfile)
import Lockstep.Application.Profiles (addProfile)
import Lockstep.Application.Proposals (ProposalView (..), decideImprovement, proposeImprovement)
import Lockstep.Application.Tasks (TaskView (..))
import Lockstep.Kernel.Execution (bugFixRaw)
import Lockstep.Kernel.Plan (PlanMode (..))
import Lockstep.Kernel.Profile (RawProfile (..))
import Lockstep.Kernel.Proposal (Decision (..), ProposalInput (..), Proposer (..), Scope (..))
import Lockstep.Kernel.Summary (Evidence (..))
import Lockstep.Support.Scheduling (Scenario (..), approveIn, count, engineFor, fixOfTask, idemWith, passesUntil, planOf, projectWith, ready, taskOfUnit, valueFiles, valueUnit, withScenario)

tests :: TestTree
tests =
  testGroup
    "R6.6 improvement proposal integrity (real Git, PostgreSQL)"
    [ testCase "commit evidence must be a commit a fix recorded; another well-formed hash is refused (R6.6)" commitRecorded
    , testCase "a Profile rule must target a Profile Lockstep knows, at its current version (R6.6)" knownTarget
    , testCase "a proposal whose target moved on may be rejected, never approved; the decision changes nothing else (R6.6, OQ-P6.9-2)" staleRejection
    ]

-- Fixtures ---------------------------------------------------------------------------------------

prefix :: T.Text
prefix =
  "test-proposal-integrity-"

idem :: T.Text -> IO IdempotencyKey
idem =
  idemWith prefix

-- | A fix that recorded its basis commit and halted at its discovery (no helper); its id and that commit.
recordedFix :: Scenario -> IO (T.Text, T.Text)
recordedFix sc = do
  (view, _) <- projectWith sc prefix "proposals" (valueFiles 1) True
  r <- approveIn sc prefix view "proposals" (planOf "Values" Brownfield [valueUnit 1] [])
  engine <- engineFor sc []
  passesUntil sc engine 20 ((== 1) <$> count sc "lockstep_transactions WHERE state = 'halted'")
  t <- taskOfUnit sc view r "f1"
  fix <- fixOfTask sc (taskId t)
  basis <- maybe (assertFailure "no basis recorded") pure (viewBasis fix)
  pure (viewId fix, basis)

proposal :: [Evidence] -> ProposalInput
proposal evidence =
  ProposalInput
    { inputScope = EngineeringPractice
    , inputTarget = "commit-messages"
    , inputCurrent = "1"
    , inputProposed = "2"
    , inputTitle = "Name the test in every fix's commit message"
    , inputBenefit = "A reader finds the frozen test from the commit."
    , inputRisks = "Longer messages."
    , inputEvidence = evidence
    , inputPrivate = False
    , inputProposer = ByPerson "owner-session"
    }

propose :: Scenario -> T.Text -> ProposalInput -> IO (Either [T.Text] ProposalView)
propose sc key input = do
  ik <- idem key
  ready (proposeImprovement (scRuntime sc) ik input)

proposed :: Scenario -> T.Text -> ProposalInput -> IO ProposalView
proposed sc key input =
  propose sc key input >>= either (\e -> assertFailure ("proposal refused: " <> show e)) pure

decide :: Scenario -> ProposalView -> T.Text -> Decision -> IO (Either T.Text ProposalView)
decide sc p seen decision =
  ready (decideImprovement (scRuntime sc) (SenderHuman ApplicationChannel) (proposalId p) seen decision)

teamChecks :: Scenario -> Integer -> IO ()
teamChecks sc version =
  ready (addProfile (scRuntime sc) (LBS.fromStrict (TE.encodeUtf8 (encodeRawProfile bugFixRaw {rawProfileId = "team-checks", rawProfileVersion = version}))))
    >>= either (const (assertFailure ("team-checks " <> show version <> " refused"))) (const (pure ()))

rule :: T.Text -> T.Text -> [Evidence] -> ProposalInput
rule target current evidence =
  (proposal evidence) {inputScope = ProfileRule, inputTarget = target, inputCurrent = current, inputProposed = "9"}

-- Cases ------------------------------------------------------------------------------------------

commitRecorded :: Assertion
commitRecorded =
  withScenario $ \sc -> do
    (_, basis) <- recordedFix sc
    propose sc "unrecorded" (proposal [OfCommit "0123456789abcdef0123456789abcdef01234567"]) >>= (@?= Left ["evidence-unknown"])
    count sc "lockstep_improvement_proposals" >>= (@?= 0)
    p <- proposed sc "recorded" (proposal [OfCommit basis])
    proposalSupport' p @?= 1
    -- The same recorded commit in capitals is the same evidence, the same proposal.
    q <- proposed sc "upper" (proposal [OfCommit (T.toUpper basis)])
    proposalId q @?= proposalId p
    count sc "lockstep_improvement_proposals" >>= (@?= 1)

knownTarget :: Assertion
knownTarget =
  withScenario $ \sc -> do
    (fix, _) <- recordedFix sc
    propose sc "unknown" (rule "no-such-checks" "1" [OfFix fix]) >>= (@?= Left ["unknown-target"])
    -- Lockstep's own engineering checks are known (version 1) without being in the catalog yet.
    _ <- proposed sc "built-in" (rule "lockstep-engineering" "1" [OfFix fix])
    teamChecks sc 1
    _ <- proposed sc "catalog" (rule "team-checks" "1" [OfFix fix])
    count sc "lockstep_improvement_proposals" >>= (@?= 2)

staleRejection :: Assertion
staleRejection =
  withScenario $ \sc -> do
    (fix, _) <- recordedFix sc
    teamChecks sc 1
    rejected <- proposed sc "to-reject" (rule "team-checks" "1" [OfFix fix])
    approvable <- proposed sc "to-approve" ((rule "team-checks" "1" [OfFix fix]) {inputTitle = "Another rule"})
    -- The catalog moves on: both proposals are stale.
    teamChecks sc 2
    profiles <- count sc "lockstep_profiles WHERE profile_id = 'team-checks'"
    decide sc approvable "1" ApproveProposal >>= (@?= Left "stale-target") . fmap proposalDecision
    d <- decide sc rejected "1" RejectProposal >>= either (\e -> assertFailure ("refused: " <> T.unpack e)) pure
    proposalDecision d @?= Just "rejected"
    -- A decision is terminal and writes only itself.
    decide sc rejected "1" ApproveProposal >>= (@?= Left "already-decided") . fmap proposalDecision
    count sc "lockstep_improvement_decisions" >>= (@?= 1)
    count sc "lockstep_profiles WHERE profile_id = 'team-checks'" >>= (@?= profiles)
