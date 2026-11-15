{- | Improvement proposals (contract C-P6.9). Stub for the frozen tests: nothing
is recorded or decided yet.
-}
module Lockstep.Application.Proposals
  ( ProposalView (..)
  , proposeImprovement
  , decideImprovement
  , listProposals
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Conversation (Sender)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Kernel.Proposal (Decision, ProposalInput)

data ProposalView
  = ProposalView
  { proposalId :: T.Text
  , proposalScope :: T.Text
  , proposalTarget :: T.Text
  , proposalCurrent :: T.Text
  , proposalProposed :: T.Text
  , proposalTitle :: T.Text
  , proposalSupport' :: Int
  -- ^ Distinct pieces of canonical evidence.
  , proposalPrivate :: Bool
  , proposalBy :: T.Text
  , proposalDecision :: Maybe T.Text
  }
  deriving (Eq, Show)

proposeImprovement :: DatabaseRuntime -> IdempotencyKey -> ProposalInput -> IO (Either NotReadyReason (Either [T.Text] ProposalView))
proposeImprovement _ _ _ =
  pure (Right (Left [T.pack "not-implemented"]))

decideImprovement :: DatabaseRuntime -> Sender -> T.Text -> T.Text -> Decision -> IO (Either NotReadyReason (Either T.Text ProposalView))
decideImprovement _ _ _ _ _ =
  pure (Right (Left (T.pack "not-implemented")))

listProposals :: DatabaseRuntime -> Bool -> IO (Either NotReadyReason [ProposalView])
listProposals _ _ =
  pure (Right [])
