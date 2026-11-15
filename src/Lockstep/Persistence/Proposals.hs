{- | Storage for improvement proposals and the owner's decisions on them
(contract C-P6.9; migration 31). Both are written once and never changed;
proposals and decisions are serialized by 'lockProposals'.
-}
module Lockstep.Persistence.Proposals
  ( ProposalRow (..)
  , DecisionRow (..)
  , lockProposals
  , findProposalByKey
  , findProposalByDigest
  , findProposal
  , allProposals
  , insertProposal
  , decisionOf
  , insertDecision
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Text.Show (Show)

data ProposalRow
  = ProposalRow
  { proposalRowId :: T.Text
  , proposalRowKey :: T.Text
  , proposalRowDigest :: T.Text
  , proposalRowScope :: T.Text
  , proposalRowTarget :: T.Text
  , proposalRowCurrent :: T.Text
  , proposalRowProposed :: T.Text
  , proposalRowTitle :: T.Text
  , proposalRowBenefit :: T.Text
  , proposalRowRisks :: T.Text
  , proposalRowEvidence :: T.Text
  -- ^ The evidence keys, separated by spaces, in their canonical order.
  , proposalRowSupport :: Int32
  , proposalRowPrivate :: Bool
  , proposalRowBy :: T.Text
  -- ^ @person@ or @fix@.
  , proposalRowProposer :: T.Text
  }
  deriving (Eq, Show)

proposalTable :: O.TableDefinition O.NoKey ProposalRow ProposalRow
proposalTable =
  O.mkTableDefinitionWithoutKey "lockstep_improvement_proposals" $
    ProposalRow
      <$> O.marshallField proposalRowId proposalIdField
      <*> O.marshallField proposalRowKey proposalKeyField
      <*> O.marshallField proposalRowDigest proposalDigestField
      <*> O.marshallField proposalRowScope (O.unboundedTextField "scope")
      <*> O.marshallField proposalRowTarget (O.unboundedTextField "target")
      <*> O.marshallField proposalRowCurrent (O.unboundedTextField "current_version")
      <*> O.marshallField proposalRowProposed (O.unboundedTextField "proposed_version")
      <*> O.marshallField proposalRowTitle (O.unboundedTextField "title")
      <*> O.marshallField proposalRowBenefit (O.unboundedTextField "benefit")
      <*> O.marshallField proposalRowRisks (O.unboundedTextField "risks")
      <*> O.marshallField proposalRowEvidence (O.unboundedTextField "evidence")
      <*> O.marshallField proposalRowSupport (O.integerField "support")
      <*> O.marshallField proposalRowPrivate (O.booleanField "private")
      <*> O.marshallField proposalRowBy (O.unboundedTextField "proposed_by")
      <*> O.marshallField proposalRowProposer (O.unboundedTextField "proposer")

proposalIdField :: O.FieldDefinition O.NotNull T.Text
proposalIdField =
  O.unboundedTextField "id"

proposalKeyField :: O.FieldDefinition O.NotNull T.Text
proposalKeyField =
  O.unboundedTextField "idempotency_key"

proposalDigestField :: O.FieldDefinition O.NotNull T.Text
proposalDigestField =
  O.unboundedTextField "digest"

data DecisionRow
  = DecisionRow
  { decisionRowProposal :: T.Text
  , decisionRowDecision :: T.Text
  , decisionRowSeen :: T.Text
  , decisionRowActor :: T.Text
  }
  deriving (Eq, Show)

decisionTable :: O.TableDefinition O.NoKey DecisionRow DecisionRow
decisionTable =
  O.mkTableDefinitionWithoutKey "lockstep_improvement_decisions" $
    DecisionRow
      <$> O.marshallField decisionRowProposal decisionProposalField
      <*> O.marshallField decisionRowDecision (O.unboundedTextField "decision")
      <*> O.marshallField decisionRowSeen (O.unboundedTextField "version_seen")
      <*> O.marshallField decisionRowActor (O.unboundedTextField "actor")

decisionProposalField :: O.FieldDefinition O.NotNull T.Text
decisionProposalField =
  O.unboundedTextField "proposal_id"

-- | Serializes proposals and decisions until the transaction ends; reads stay possible.
lockProposals :: O.MonadOrville m => m ()
lockProposals =
  O.executeVoid O.OtherQuery (RawSql.fromString "LOCK TABLE lockstep_improvement_proposals IN EXCLUSIVE MODE")

findProposalByKey :: O.MonadOrville m => T.Text -> m (Maybe ProposalRow)
findProposalByKey k =
  O.findFirstEntityBy proposalTable (O.where_ (O.fieldEquals proposalKeyField k))

findProposalByDigest :: O.MonadOrville m => T.Text -> m (Maybe ProposalRow)
findProposalByDigest d =
  O.findFirstEntityBy proposalTable (O.where_ (O.fieldEquals proposalDigestField d))

findProposal :: O.MonadOrville m => T.Text -> m (Maybe ProposalRow)
findProposal i =
  O.findFirstEntityBy proposalTable (O.where_ (O.fieldEquals proposalIdField i))

-- | Every proposal, in the order they were made.
allProposals :: O.MonadOrville m => m [ProposalRow]
allProposals =
  O.findEntitiesBy proposalTable (O.orderBy (O.orderByField (O.utcTimestampField "created_at") O.ascendingOrder <> O.orderByField proposalIdField O.ascendingOrder))

insertProposal :: O.MonadOrville m => ProposalRow -> m ()
insertProposal =
  O.insertEntity proposalTable

decisionOf :: O.MonadOrville m => T.Text -> m (Maybe DecisionRow)
decisionOf i =
  O.findFirstEntityBy decisionTable (O.where_ (O.fieldEquals decisionProposalField i))

insertDecision :: O.MonadOrville m => DecisionRow -> m ()
insertDecision =
  O.insertEntity decisionTable
