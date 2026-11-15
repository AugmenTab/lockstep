{- | Improvement proposals (contract C-P6.9 P1–P5). Stub for the frozen tests:
the types are the contract's, the rules are not written yet.
-}
module Lockstep.Kernel.Proposal
  ( Scope (..)
  , scopeCode
  , parseScope
  , Proposer (..)
  , ProposalInput (..)
  , Proposal
  , proposalInput
  , proposalSupport
  , ProposalProblem (..)
  , problemCode
  , validateProposal
  , proposalText
  , evidenceKey
  , evidenceFromKey
  , Decision (..)
  , decisionCode
  , decideProposal
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Summary (Evidence)
import Lockstep.Kernel.Transition (Principal)

data Scope
  = EngineeringPractice
  | ProfileRule
  | TestAdequacy
  | ReviewInstructions
  | SkillScope
  deriving (Eq, Show, Enum, Bounded)

scopeCode :: Scope -> T.Text
scopeCode _ =
  T.empty

parseScope :: T.Text -> Maybe Scope
parseScope _ =
  Nothing

data Proposer
  = -- | A person, by their session or the command line.
    ByPerson T.Text
  | -- | A fix (its transaction), with the Profiles its Work Order is bound to.
    ByFix T.Text [T.Text]
  deriving (Eq, Show)

data ProposalInput
  = ProposalInput
  { inputScope :: Scope
  , inputTarget :: T.Text
  , inputCurrent :: T.Text
  , inputProposed :: T.Text
  , inputTitle :: T.Text
  , inputBenefit :: T.Text
  , inputRisks :: T.Text
  , inputEvidence :: [Evidence]
  , inputPrivate :: Bool
  , inputProposer :: Proposer
  }
  deriving (Eq, Show)

newtype Proposal
  = Proposal ProposalInput
  deriving (Eq, Show)

proposalInput :: Proposal -> ProposalInput
proposalInput (Proposal i) =
  i

proposalSupport :: Proposal -> Int
proposalSupport _ =
  0

data ProposalProblem
  = TextInvalid
  | NoChange
  | NoEvidence
  | SelfPrivilege
  | PrivateScope
  deriving (Eq, Show, Enum, Bounded)

problemCode :: ProposalProblem -> T.Text
problemCode _ =
  T.empty

evidenceKey :: Evidence -> T.Text
evidenceKey _ =
  T.empty

evidenceFromKey :: T.Text -> Maybe Evidence
evidenceFromKey _ =
  Nothing

validateProposal :: ProposalInput -> Either [ProposalProblem] Proposal
validateProposal _ =
  Left []

proposalText :: Proposal -> T.Text
proposalText _ =
  T.empty

data Decision
  = ApproveProposal
  | RejectProposal
  deriving (Eq, Show, Enum, Bounded)

decisionCode :: Decision -> T.Text
decisionCode _ =
  T.empty

decideProposal :: Principal -> T.Text -> Maybe Decision -> Proposal -> Either T.Text ()
decideProposal _ _ _ _ =
  Left (T.pack "not-implemented")
