{-# LANGUAGE OverloadedStrings #-}

{- | Improvement proposals (contract C-P6.9 P1–P5), pure: what a proposal
must say, its evidence counted once, its identity, no self-privilege, the
private scope, and who decides.
-}
module Lockstep.Kernel.ProposalTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Lockstep.Kernel.Proposal
  ( Decision (..)
  , ProposalInput (..)
  , ProposalProblem (..)
  , Proposer (..)
  , Scope (..)
  , decideProposal
  , decisionCode
  , parseScope
  , problemCode
  , proposalSupport
  , proposalText
  , scopeCode
  , validateProposal
  )
import Lockstep.Kernel.Summary (Evidence (..))
import Lockstep.Kernel.Transition (Principal (..))

input :: ProposalInput
input =
  ProposalInput
    { inputScope = EngineeringPractice
    , inputTarget = "commit-messages"
    , inputCurrent = "1"
    , inputProposed = "2"
    , inputTitle = "Name the test in every fix's commit message"
    , inputBenefit = "A reader finds the frozen test from the commit."
    , inputRisks = "Longer messages."
    , inputEvidence = [OfFix "tx-1", OfRecord "tx-1" 7]
    , inputPrivate = False
    , inputProposer = ByPerson "owner-session"
    }

problemsOf :: ProposalInput -> [ProposalProblem]
problemsOf i =
  fromLeft [] (validateProposal i)

tests :: TestTree
tests =
  testGroup
    "C-P6.9 improvement proposals (pure)"
    [ testGroup
        "what a proposal says (P1)"
        [ testCase "each scope has its code, and its code reads back" $ do
            fmap scopeCode [minBound .. maxBound] @?= ["engineering-practice", "profile-rule", "test-adequacy", "review-instructions", "skill"]
            traverse_ (\s -> parseScope (scopeCode s) @?= Just s) [minBound .. maxBound]
            parseScope "everything" @?= Nothing
        , testCase "a complete proposal is valid" $
            assertBool "refused" (isRight (validateProposal input))
        , testCase "each problem has its code" $
            fmap problemCode [minBound .. maxBound] @?= ["text-invalid", "no-change", "no-evidence", "self-privilege", "private-scope"]
        , testCase "an empty, too long or control-character text is refused" $ do
            problemsOf input {inputTitle = "  "} @?= [TextInvalid]
            problemsOf input {inputTitle = T.replicate 201 "x"} @?= [TextInvalid]
            problemsOf input {inputTarget = "a\tb"} @?= [TextInvalid]
            problemsOf input {inputRisks = T.replicate 4001 "r"} @?= [TextInvalid]
        , testCase "the same version twice is no change; no evidence is refused" $ do
            problemsOf input {inputProposed = "1"} @?= [NoChange]
            problemsOf input {inputEvidence = []} @?= [NoEvidence]
        ]
    , testGroup
        "evidence and identity (P2)"
        [ testCase "repeated evidence counts once: repeated opinions are not independent" $
            fmap proposalSupport (validateProposal input {inputEvidence = [OfFix "tx-1", OfFix "tx-1", OfRecord "tx-1" 7, OfRecord "tx-1" 7]}) @?= Right 2
        , testCase "the same proposal is the same text, whoever proposes it and in whatever order its evidence comes" $ do
            let
              a = validateProposal input
              b = validateProposal input {inputEvidence = [OfRecord "tx-1" 7, OfFix "tx-1", OfFix "tx-1"], inputProposer = ByFix "tx-9" [], inputTitle = "  Name the test in every fix's commit message "}
            fmap proposalText a @?= fmap proposalText b
        , testCase "a different version is a different proposal" $
            assertBool "same text" (fmap proposalText (validateProposal input) /= fmap proposalText (validateProposal input {inputProposed = "3"}))
        ]
    , testGroup
        "no self-privilege, private scope (P3, P4)"
        [ testCase "a fix may not propose a rule for the Profile its own Work Order is bound to" $ do
            problemsOf input {inputScope = ProfileRule, inputTarget = "lockstep-bug-fix", inputProposer = ByFix "tx" ["lockstep-bug-fix"]} @?= [SelfPrivilege]
            problemsOf input {inputScope = ProfileRule, inputTarget = "team-checks", inputProposer = ByFix "tx" ["lockstep-bug-fix"]} @?= []
            problemsOf input {inputScope = ProfileRule, inputTarget = "lockstep-bug-fix", inputProposer = ByPerson "owner"} @?= []
        , testCase "a private proposal is only a person's" $ do
            problemsOf input {inputPrivate = True, inputProposer = ByFix "tx" []} @?= [PrivateScope]
            problemsOf input {inputPrivate = True} @?= []
        ]
    , testGroup
        "who decides (P5)"
        [ testCase "each decision has its code" $
            fmap decisionCode [minBound .. maxBound] @?= ["approved", "rejected"]
        , testCase "only a person decides: an agent's or the Supervisor's approval is forged" $
            case validateProposal input of
              Left _ -> assertBool "refused" False
              Right p -> do
                decideProposal Agent "1" Nothing p @?= Left "not-authorized"
                decideProposal Supervisor "1" Nothing p @?= Left "not-authorized"
                decideProposal Human "1" Nothing p @?= Right ()
        , testCase "a decision on another version than the proposal's is stale; a decided proposal is not decided again" $
            case validateProposal input of
              Left _ -> assertBool "refused" False
              Right p -> do
                decideProposal Human "2" Nothing p @?= Left "stale-target"
                decideProposal Human "1" (Just RejectProposal) p @?= Left "already-decided"
        ]
    ]
