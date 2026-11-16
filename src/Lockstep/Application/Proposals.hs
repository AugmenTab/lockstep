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

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, idempotencyKeyText)
import Lockstep.Application.Conversation (Sender (..), senderPrincipal)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Invalidations (invalidationOf)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Identity (HumanRequestId (..), TransactionId (..), identityText, parseIdentity, uuidText)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText, mkProfileId, profileIdText)
import Lockstep.Kernel.Proposal
  ( Decision (..)
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
import Lockstep.Kernel.Summary (Evidence (..))
import Lockstep.Persistence.Conversation qualified as Requests
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
      -- R-P6.9-1, -2: every link names a row of Lockstep's own, in its one spelling.
      resolved <- sequenceA <$> traverse canonicalEvidence (inputEvidence raw)
      case (proposer, resolved) of
        (Nothing, _) -> pure (Left [T.pack "unknown-fix"])
        (_, Nothing) -> pure (Left [T.pack "evidence-unknown"])
        (Just p, Just evidence) ->
          case validateProposal raw {inputProposer = p, inputEvidence = evidence} of
            Left problems -> pure (Left (fmap problemCode problems))
            Right proposal -> do
              let
                i = proposalInput proposal
                digest = sha (proposalText proposal)
              problem <- profileRuleProblem i
              byKey <- Store.findProposalByKey (idempotencyKeyText key)
              byDigest <- Store.findProposalByDigest digest
              case (byKey, byDigest) of
                _ | Just code <- problem -> pure (Left [code])
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

{- | R-P6.9-1, -2: a link as Lockstep's own row names it, in its one spelling;
Nothing when it names none. A commit is checked for its form only: a full SHA,
in lower case (R-P6.9-1, limited; docs/gates/P6.9/review.md).
-}
canonicalEvidence :: Evidence -> O.Orville (Maybe Evidence)
canonicalEvidence e =
  case e of
    OfFix t -> withFix t (pure . Just . OfFix . identityText)
    OfRecord t n ->
      withFix t $ \tx -> do
        records <- Transactions.transactionRecords tx
        pure $
          if L.any ((== n) . fromIntegral . Transactions.recordRowSequence) records
            then Just (OfRecord (identityText tx) n)
            else Nothing
    OfInvalidation t -> withFix t (\tx -> fmap (const (OfInvalidation (identityText tx))) <$> invalidationOf tx)
    OfRequest r ->
      case parseIdentity (T.toLower r) of
        Nothing -> pure Nothing
        Just q -> fmap (const (OfRequest (identityText (q :: HumanRequestId)))) <$> Requests.findRequest q
    -- Update 2 R6.6 (OQ-P6.9-1): a commit is evidence only when a fix of Lockstep's recorded it.
    OfCommit c ->
      let
        commit = T.toLower c
      in
        if T.length commit == 40 && T.all Char.isHexDigit commit
          then (\recorded -> if recorded then Just (OfCommit commit) else Nothing) <$> Transactions.commitRecorded commit
          else pure Nothing
 where
  -- An id in any letter case is the same id; its canonical spelling is lower case.
  withFix t found =
    case parseIdentity (T.toLower t) of
      Nothing -> pure Nothing
      Just tx -> Transactions.findTransaction tx >>= maybe (pure Nothing) (const (found tx))

{- | R-P6.9-4, Update 2 R6.6 (OQ-P6.9-1): a Profile rule targets a Profile
Lockstep knows, at its current version: a catalog Profile's latest version, or
version 1 of one of Lockstep's own not yet in the catalog. Any other target is
@unknown-target@; another version is @stale-target@.
-}
profileRuleProblem :: ProposalInput -> O.Orville (Maybe T.Text)
profileRuleProblem i
  | inputScope i /= ProfileRule = pure Nothing
  | otherwise = do
      current <- currentProfileVersion (inputTarget i)
      pure $
        case current of
          Nothing -> Just (T.pack "unknown-target")
          Just v
            | v /= T.strip (inputCurrent i) -> Just (T.pack "stale-target")
            | otherwise -> Nothing

-- | The current version of a Profile Lockstep knows, as text: the catalog's latest, else 1 for one of its own.
currentProfileVersion :: T.Text -> O.Orville (Maybe T.Text)
currentProfileVersion target =
  case mkProfileId target of
    Nothing -> pure Nothing
    Just profile -> do
      row <- Profiles.findProfile profile Nothing
      pure $
        case row of
          Just r -> Just (T.pack (show (Profiles.profileRowVersion r)))
          Nothing
            | target `L.elem` fmap T.pack ["lockstep-bug-fix", "lockstep-basic", "lockstep-engineering"] -> Just (T.pack "1")
            | otherwise -> Nothing

{- | A stored proposal as the Kernel's, to decide on; Nothing unless its stored
evidence reads back to exactly what was stored (R-P6.9-3).
-}
storedInput :: Store.ProposalRow -> Maybe ProposalInput
storedInput row = do
  scope <- parseScope (Store.proposalRowScope row)
  evidence <- traverse evidenceFromKey (T.words (Store.proposalRowEvidence row))
  if T.unwords (fmap evidenceKey evidence) == Store.proposalRowEvidence row then Just () else Nothing
  pure
    ProposalInput
      { inputScope = scope
      , inputTarget = Store.proposalRowTarget row
      , inputCurrent = Store.proposalRowCurrent row
      , inputProposed = Store.proposalRowProposed row
      , inputTitle = Store.proposalRowTitle row
      , inputBenefit = Store.proposalRowBenefit row
      , inputRisks = Store.proposalRowRisks row
      , inputEvidence = evidence
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
            then currentProfileVersion (Store.proposalRowTarget row)
            else pure Nothing
        case storedInput row >>= either (const Nothing) Just . validateProposal of
          Nothing -> pure (Left (T.pack "proposal-unreadable"))
          Just proposal ->
            case decideProposal (senderPrincipal sender) seen (parseDecision . Store.decisionRowDecision =<< earlier) proposal of
              Left code -> pure (Left code)
              Right ()
                {- P5: a Profile rule is approved only on the catalog's latest version of that Profile. Update 2 R6.6
                (OQ-P6.9-2): a stale proposal may still be rejected, a terminal decision that authorizes nothing. -}
                | decision == ApproveProposal && Store.proposalRowScope row == scopeCode ProfileRule && latest /= Just (T.strip seen) -> pure (Left (T.pack "stale-target"))
                | otherwise -> do
                    let
                      decided = Store.DecisionRow rawId (decisionCode decision) (T.strip seen) (actorOf sender)
                    Store.insertDecision decided
                    pure (Right (viewOf row (Just decided)))
 where
  parseDecision code =
    L.find ((== code) . decisionCode) [minBound .. maxBound]
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
    decisions <- Store.allDecisions
    pure [viewOf r (L.find ((== Store.proposalRowId r) . Store.decisionRowProposal) decisions) | r <- rows, Store.proposalRowPrivate r == private]
