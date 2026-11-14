{- | Master Plans (contract C-P6.4): proposals by a person or the Planner,
the owner's digest-bound decision, the units of an approved revision as
canonical tasks, reconciliation with the previous effective revision, and the
Planner's bounded drafts from a PRD. A proposal is never authority.
-}
module Lockstep.Application.Plans
  ( ProposalRefusal (..)
  , RevisionView (..)
  , PlanView (..)
  , DraftView (..)
  , PlanDecision (..)
  , DraftOutcome (..)
  , DraftReport (..)
  , proposePlan
  , proposePlanFile
  , decidePlan
  , planView
  , requestDraft
  , requestDraftFiles
  , draftPlans
  , draftPlansUntil
  , draftOutcomeCode
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO (FilePath)
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Application.Engine (Engine)
import Lockstep.Kernel.Plan (PlanDocument)

-- | A refused proposal: its code and, for an invalid plan, each problem in words.
data ProposalRefusal
  = ProposalRefusal
  { proposalRefusalCode :: T.Text
  , proposalRefusalProblems :: [T.Text]
  }
  deriving (Eq, Show)

data RevisionView
  = RevisionView
  { revisionNumber :: Int
  , revisionDigest :: T.Text
  , revisionState :: T.Text
  -- ^ @proposed@, @approved@, @rejected@ or @superseded@ (approved, then replaced by a newer approval).
  , revisionProposedBy :: T.Text
  -- ^ @Human@ or @Planner@.
  , revisionProposer :: T.Text
  , revisionDecidedBy :: Maybe T.Text
  , revisionDocument :: PlanDocument
  , revisionReconciliation :: [(T.Text, T.Text)]
  -- ^ Each unit's key and outcome, once approved.
  , revisionTasks :: [(T.Text, T.Text)]
  -- ^ Each unit's key and task, once approved.
  }
  deriving (Eq, Show)

data DraftView
  = DraftView
  { draftId :: T.Text
  , draftPrdDigest :: T.Text
  , draftArchitectureDigest :: Maybe T.Text
  , draftOutcome :: Maybe T.Text
  , draftCode :: Maybe T.Text
  }
  deriving (Eq, Show)

data PlanView
  = PlanView
  { planViewRevisions :: [RevisionView]
  -- ^ Newest first.
  , planViewEffective :: Maybe RevisionView
  , planViewDrafts :: [DraftView]
  -- ^ In request order.
  }
  deriving (Eq, Show)

data PlanDecision
  = ApprovePlan
  | RejectPlan
  deriving (Eq, Show)

data DraftOutcome
  = DraftProposed Int
  | DraftRefused [T.Text]
  | DraftFailed T.Text
  | DraftNoHelper
  | DraftUncertain
  deriving (Eq, Show)

data DraftReport
  = DraftReport
  { reportDraft :: T.Text
  , reportOutcome :: DraftOutcome
  }
  deriving (Eq, Show)

-- | The outcome's word in the worker's pass report.
draftOutcomeCode :: DraftOutcome -> T.Text
draftOutcomeCode _ =
  T.empty

-- | A person's proposal (M4): the document's bytes into the project's plan.
proposePlan :: DatabaseRuntime -> IdempotencyKey -> T.Text -> T.Text -> LBS.ByteString -> IO (Either NotReadyReason (Either ProposalRefusal RevisionView))
proposePlan _ _ _ _ _ =
  pure (Right (Left (ProposalRefusal T.empty [])))

-- | 'proposePlan' from a file; @file-unreadable@ when it cannot be read.
proposePlanFile :: DatabaseRuntime -> IdempotencyKey -> T.Text -> T.Text -> FilePath -> IO (Either NotReadyReason (Either ProposalRefusal RevisionView))
proposePlanFile _ _ _ _ _ =
  pure (Right (Left (ProposalRefusal T.empty [])))

-- | The owner's decision (M5), by an operator session, on a revision named by number and digest.
decidePlan :: DatabaseRuntime -> T.Text -> T.Text -> Int -> T.Text -> PlanDecision -> IO (Either NotReadyReason (Either T.Text RevisionView))
decidePlan _ _ _ _ _ _ =
  pure (Right (Left T.empty))

planView :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text PlanView))
planView _ _ =
  pure (Right (Left T.empty))

-- | A person's request that the Planner draft a plan (M10): the PRD and, optionally, the architecture.
requestDraft :: DatabaseRuntime -> IdempotencyKey -> T.Text -> T.Text -> T.Text -> Maybe T.Text -> IO (Either NotReadyReason (Either T.Text DraftView))
requestDraft _ _ _ _ _ _ =
  pure (Right (Left T.empty))

-- | 'requestDraft' from files; @file-unreadable@ when one cannot be read.
requestDraftFiles :: DatabaseRuntime -> IdempotencyKey -> T.Text -> T.Text -> FilePath -> Maybe FilePath -> IO (Either NotReadyReason (Either T.Text DraftView))
requestDraftFiles _ _ _ _ _ _ =
  pure (Right (Left T.empty))

-- | One pass over the pending drafts (the worker's phase).
draftPlans :: DatabaseRuntime -> Engine -> IO (Either NotReadyReason [DraftReport])
draftPlans runtime engine =
  draftPlansUntil runtime engine (pure False)

-- | 'draftPlans', checking before each draft whether to stop.
draftPlansUntil :: DatabaseRuntime -> Engine -> IO Bool -> IO (Either NotReadyReason [DraftReport])
draftPlansUntil _ _ _ =
  pure (Right [])
