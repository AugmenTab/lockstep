{- | Improvement proposals (contract C-P6.9): proposed by a person or recorded
from a fix, kept once whatever key or proposer repeats them, decided only by
the owner on the version they looked at, and never installed: a decision is a
row, and nothing else changes.
-}
module Lockstep.Application.Proposals
  ( ProposalView (..)
  , proposeImprovement
  , decideImprovement
  , listProposals
  ) where

import Data.List qualified as L
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, idempotencyKeyText)
import Lockstep.Application.Conversation (Sender (..))
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Identity (TransactionId (..), parseIdentity, uuidText)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText, mkProfileId, profileIdText)
import Lockstep.Kernel.Proposal
  ( Decision
  , ProposalInput (..)
  , Proposer (..)
  , Scope (ProfileRule)
  , decideProposal
  , decisionCode
  , evidenceFromKey
  , evidenceKey
  , parseScope
  , problemCode
  , proposalInput
  , proposalSupport
  , proposalText
  , scopeCode
  , validateProposal
  )
import Lockstep.Kernel.Transition (Principal (..))
import Lockstep.Persistence.Ledger qualified as Ledger
import Lockstep.Persistence.Profiles qualified as Profiles
import Lockstep.Persistence.Proposals qualified as Store
import Lockstep.Persistence.Transactions qualified as Transactions

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

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

sha :: T.Text -> T.Text
sha text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

viewOf :: Store.ProposalRow -> Maybe Store.DecisionRow -> ProposalView
viewOf row decision =
  ProposalView
    { proposalId = Store.proposalRowId row
    , proposalScope = Store.proposalRowScope row
    , proposalTarget = Store.proposalRowTarget row
    , proposalCurrent = Store.proposalRowCurrent row
    , proposalProposed = Store.proposalRowProposed row
    , proposalTitle = Store.proposalRowTitle row
    , proposalSupport' = fromIntegral (Store.proposalRowSupport row)
    , proposalPrivate = Store.proposalRowPrivate row
    , proposalBy = Store.proposalRowBy row
    , proposalDecision = Store.decisionRowDecision <$> decision
    }

-- | P3: the Profiles a fix's Work Order is bound to (its stored binding's sources).
boundProfiles :: TransactionId -> O.Orville (Maybe [T.Text])
boundProfiles tx = do
  row <- Transactions.findTransaction tx
  case row of
    Nothing -> pure Nothing
    Just r -> Just . fmap (profileIdText . Ledger.sourceRowProfile) <$> Ledger.sourcesOf (Transactions.txRowWorkOrder r)

{- | P1–P4: records a proposal, or gives the one already recorded with the same
content (a duplicate, whatever its key or proposer). A key replays only the
proposal it recorded (@key-conflict@ otherwise). A fix that does not exist is
@unknown-fix@.
-}
proposeImprovement :: DatabaseRuntime -> IdempotencyKey -> ProposalInput -> IO (Either NotReadyReason (Either [T.Text] ProposalView))
proposeImprovement runtime key raw =
  whenReady runtime $ do
    u <- newUuid
    withDatabase runtime . O.withTransaction $ do
      Store.lockProposals
      -- A fix's proposal is checked against what its own Work Order is bound to.
      proposer <-
        case inputProposer raw of
          ByPerson who -> pure (Just (ByPerson who))
          ByFix tx _ -> maybe (pure Nothing) (fmap (fmap (ByFix tx)) . boundProfiles) (parseIdentity tx)
      case proposer of
        Nothing -> pure (Left [T.pack "unknown-fix"])
        Just p ->
          case validateProposal raw {inputProposer = p} of
            Left problems -> pure (Left (fmap problemCode problems))
            Right proposal -> do
              let
                i = proposalInput proposal
                digest = sha (proposalText proposal)
              byKey <- Store.findProposalByKey (idempotencyKeyText key)
              byDigest <- Store.findProposalByDigest digest
              case (byKey, byDigest) of
                (Just row, _)
                  | Store.proposalRowDigest row == digest -> Right . viewOf row <$> Store.decisionOf (Store.proposalRowId row)
                  | otherwise -> pure (Left [T.pack "key-conflict"])
                -- P2: the same proposal again is the same proposal.
                (Nothing, Just row) -> Right . viewOf row <$> Store.decisionOf (Store.proposalRowId row)
                (Nothing, Nothing) -> do
                  let
                    row =
                      Store.ProposalRow
                        { Store.proposalRowId = uuidText u
                        , Store.proposalRowKey = idempotencyKeyText key
                        , Store.proposalRowDigest = digest
                        , Store.proposalRowScope = scopeCode (inputScope i)
                        , Store.proposalRowTarget = inputTarget i
                        , Store.proposalRowCurrent = inputCurrent i
                        , Store.proposalRowProposed = inputProposed i
                        , Store.proposalRowTitle = inputTitle i
                        , Store.proposalRowBenefit = inputBenefit i
                        , Store.proposalRowRisks = inputRisks i
                        , Store.proposalRowEvidence = T.unwords (fmap evidenceKey (inputEvidence i))
                        , Store.proposalRowSupport = fromIntegral (proposalSupport proposal)
                        , Store.proposalRowPrivate = inputPrivate i
                        , Store.proposalRowBy = T.pack (case p of ByPerson _ -> "person"; ByFix _ _ -> "fix")
                        , Store.proposalRowProposer = case p of ByPerson who -> T.take 200 who; ByFix tx _ -> tx
                        }
                  Store.insertProposal row
                  pure (Right (viewOf row Nothing))

-- | A stored proposal as the Kernel's, to decide on.
storedInput :: Store.ProposalRow -> Maybe ProposalInput
storedInput row = do
  scope <- parseScope (Store.proposalRowScope row)
  pure
    ProposalInput
      { inputScope = scope
      , inputTarget = Store.proposalRowTarget row
      , inputCurrent = Store.proposalRowCurrent row
      , inputProposed = Store.proposalRowProposed row
      , inputTitle = Store.proposalRowTitle row
      , inputBenefit = Store.proposalRowBenefit row
      , inputRisks = Store.proposalRowRisks row
      , inputEvidence = mapMaybe evidenceFromKey (T.words (Store.proposalRowEvidence row))
      , inputPrivate = Store.proposalRowPrivate row
      , inputProposer = ByPerson (Store.proposalRowProposer row)
      }

{- | P5, P6: the owner's decision on the version they looked at; it records the
decision and changes nothing else. Only a person decides (@not-authorized@).
-}
decideImprovement :: DatabaseRuntime -> Sender -> T.Text -> T.Text -> Decision -> IO (Either NotReadyReason (Either T.Text ProposalView))
decideImprovement runtime sender rawId seen decision =
  whenReady runtime . withDatabase runtime . O.withTransaction $ do
    Store.lockProposals
    found <- Store.findProposal rawId
    case found of
      Nothing -> pure (Left (T.pack "unknown-proposal"))
      Just row -> do
        earlier <- Store.decisionOf rawId
        latest <-
          if Store.proposalRowScope row == scopeCode ProfileRule
            then maybe (pure Nothing) (fmap (fmap Profiles.profileRowVersion) . (`Profiles.findProfile` Nothing)) (mkProfileId (Store.proposalRowTarget row))
            else pure Nothing
        case storedInput row >>= either (const Nothing) Just . validateProposal of
          Nothing -> pure (Left (T.pack "proposal-unreadable"))
          Just proposal ->
            case decideProposal (principalOf sender) seen (parseDecision . Store.decisionRowDecision =<< earlier) proposal of
              Left code -> pure (Left code)
              Right ()
                -- P5: a Profile rule is about the catalog's latest version of that Profile.
                | Store.proposalRowScope row == scopeCode ProfileRule && fmap (T.pack . show) latest /= Just (T.strip seen) -> pure (Left (T.pack "stale-target"))
                | otherwise -> do
                    let
                      decided = Store.DecisionRow rawId (decisionCode decision) (T.strip seen) (actorOf sender)
                    Store.insertDecision decided
                    pure (Right (viewOf row (Just decided)))
 where
  parseDecision code =
    L.find ((== code) . decisionCode) [minBound .. maxBound]
  principalOf s =
    case s of
      SenderHuman _ -> Human
      SenderSupervisor -> Supervisor
      SenderPlanner _ -> Agent
      SenderAgent _ -> Agent
  actorOf s =
    case s of
      SenderHuman _ -> T.pack "person"
      _ -> T.pack "not-a-person"

{- | P4: the proposals, in the order they were made: the shared ones, or (for
the owner's own list) the private ones only.
-}
listProposals :: DatabaseRuntime -> Bool -> IO (Either NotReadyReason [ProposalView])
listProposals runtime private =
  whenReady runtime . withDatabase runtime $ do
    rows <- Store.allProposals
    traverse (\r -> viewOf r <$> Store.decisionOf (Store.proposalRowId r)) [r | r <- rows, Store.proposalRowPrivate r == private]
