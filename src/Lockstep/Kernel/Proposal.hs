{- | Improvement proposals (contract C-P6.9 P1–P5): what a proposal must say,
its evidence (canonical, each link once), its canonical text (so the same
proposal is one proposal), the rules that keep a Work Unit from raising its
own privileges or reaching a private scope, and who may decide on one. Pure:
nothing here installs anything.
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

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Enum (parseEnumText)
import Lockstep.Kernel.Summary (Evidence (..))
import Lockstep.Kernel.Transition (Principal (Human))

data Scope
  = EngineeringPractice
  | ProfileRule
  | TestAdequacy
  | ReviewInstructions
  | SkillScope
  deriving (Eq, Show, Enum, Bounded)

scopeCode :: Scope -> T.Text
scopeCode s =
  T.pack $
    case s of
      EngineeringPractice -> "engineering-practice"
      ProfileRule -> "profile-rule"
      TestAdequacy -> "test-adequacy"
      ReviewInstructions -> "review-instructions"
      SkillScope -> "skill"

parseScope :: T.Text -> Maybe Scope
parseScope =
  parseEnumText scopeCode

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

-- | A valid proposal: its texts stripped, its evidence distinct and in one order.
newtype Proposal
  = Proposal ProposalInput
  deriving (Eq, Show)

proposalInput :: Proposal -> ProposalInput
proposalInput (Proposal i) =
  i

-- | P2: how many distinct pieces of canonical evidence support it.
proposalSupport :: Proposal -> Int
proposalSupport (Proposal i) =
  L.length (inputEvidence i)

data ProposalProblem
  = TextInvalid
  | NoChange
  | NoEvidence
  | SelfPrivilege
  | PrivateScope
  deriving (Eq, Show, Enum, Bounded)

problemCode :: ProposalProblem -> T.Text
problemCode p =
  T.pack $
    case p of
      TextInvalid -> "text-invalid"
      NoChange -> "no-change"
      NoEvidence -> "no-evidence"
      SelfPrivilege -> "self-privilege"
      PrivateScope -> "private-scope"

-- | A piece of evidence as a key: the same link is the same key (P2).
evidenceKey :: Evidence -> T.Text
evidenceKey e =
  case e of
    OfFix t -> T.pack "fix:" <> t
    OfRecord t n -> T.pack "record:" <> t <> T.pack ":" <> T.pack (show n)
    OfCommit c -> T.pack "commit:" <> c
    OfInvalidation t -> T.pack "invalidation:" <> t
    OfRequest r -> T.pack "request:" <> r

-- | The evidence a key names; Nothing for text that is not one.
evidenceFromKey :: T.Text -> Maybe Evidence
evidenceFromKey key =
  case T.splitOn (T.pack ":") key of
    [kind, t]
      | kind == T.pack "fix" -> Just (OfFix t)
      | kind == T.pack "commit" -> Just (OfCommit t)
      | kind == T.pack "invalidation" -> Just (OfInvalidation t)
      | kind == T.pack "request" -> Just (OfRequest t)
    [kind, t, n]
      | kind == T.pack "record"
      , not (T.null n)
      , T.all Char.isDigit n
      , T.length n <= 9 ->
          Just (OfRecord t (T.foldl' (\acc c -> acc * 10 + (Char.ord c - Char.ord '0')) 0 n))
    _ -> Nothing

-- | P1–P4: every problem, in a fixed order; or the proposal as stored.
validateProposal :: ProposalInput -> Either [ProposalProblem] Proposal
validateProposal raw =
  case problems of
    [] -> Right (Proposal normal)
    ps -> Left ps
 where
  normal =
    raw
      { inputTarget = T.strip (inputTarget raw)
      , inputCurrent = T.strip (inputCurrent raw)
      , inputProposed = T.strip (inputProposed raw)
      , inputTitle = T.strip (inputTitle raw)
      , inputBenefit = T.strip (inputBenefit raw)
      , inputRisks = T.strip (inputRisks raw)
      , inputEvidence = L.map snd (L.sortOn fst (L.nubBy (\a b -> fst a == fst b) [(evidenceKey e, e) | e <- inputEvidence raw]))
      }
  line limit t = not (T.null t) && T.length t <= limit && not (T.any Char.isControl t)
  prose t = not (T.null t) && T.length t <= 4000 && not (T.any (\c -> Char.isControl c && c /= '\n') t)
  textsValid =
    line 200 (inputTarget normal)
      && line 100 (inputCurrent normal)
      && line 100 (inputProposed normal)
      && line 200 (inputTitle normal)
      && prose (inputBenefit normal)
      && prose (inputRisks normal)
  fromFix =
    case inputProposer raw of
      ByFix _ _ -> True
      ByPerson _ -> False
  ownProfile =
    case inputProposer raw of
      ByFix _ bound -> inputScope raw == ProfileRule && inputTarget normal `L.elem` bound
      ByPerson _ -> False
  problems =
    [TextInvalid | not textsValid]
      <> [NoChange | inputCurrent normal == inputProposed normal]
      <> [NoEvidence | L.null (inputEvidence normal)]
      <> [SelfPrivilege | ownProfile]
      <> [PrivateScope | inputPrivate raw && fromFix]

{- | P2: the canonical text a proposal's identity is the digest of: everything
it says, not who said it or under which key.
-}
proposalText :: Proposal -> T.Text
proposalText (Proposal i) =
  T.intercalate
    (T.pack "\n")
    [ T.pack "lockstep-proposal 1"
    , T.pack "scope: " <> scopeCode (inputScope i)
    , T.pack "target: " <> inputTarget i
    , T.pack "current: " <> inputCurrent i
    , T.pack "proposed: " <> inputProposed i
    , T.pack "title: " <> inputTitle i
    , T.pack "benefit: " <> T.replace (T.pack "\n") (T.pack "\n  ") (inputBenefit i)
    , T.pack "risks: " <> T.replace (T.pack "\n") (T.pack "\n  ") (inputRisks i)
    , T.pack "private: " <> T.pack (if inputPrivate i then "yes" else "no")
    , T.pack "evidence: " <> T.unwords (fmap evidenceKey (inputEvidence i))
    ]

data Decision
  = ApproveProposal
  | RejectProposal
  deriving (Eq, Show, Enum, Bounded)

decisionCode :: Decision -> T.Text
decisionCode d =
  T.pack $
    case d of
      ApproveProposal -> "approved"
      RejectProposal -> "rejected"

{- | P5: only a person decides, once, on the version they looked at being the
one the proposal is about.
-}
decideProposal :: Principal -> T.Text -> Maybe Decision -> Proposal -> Either T.Text ()
decideProposal principal seen earlier (Proposal i)
  | principal /= Human = Left (T.pack "not-authorized")
  | isJust earlier = Left (T.pack "already-decided")
  | T.strip seen /= inputCurrent i = Left (T.pack "stale-target")
  | otherwise = Right ()
