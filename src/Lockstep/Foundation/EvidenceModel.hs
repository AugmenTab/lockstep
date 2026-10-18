{- | The gate-row evidence model of VISUAL_EVIDENCE_CONTRACT §3–§4 (contract
C-P1.6 E1, E2). Pure. 'effectiveDisposition' is the only way a row's
disposition reaches a view, so a claimed PASSED without complete, current,
matching evidence cannot render as passed.
-}
module Lockstep.Foundation.EvidenceModel
  ( Disposition (..)
  , EvidenceItem (..)
  , TestedRevision (..)
  , RowInput (..)
  , effectiveDisposition
  , aggregate
  , dispositionLabel
  , dispositionClass
  ) where

import Data.List qualified as L
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

data Disposition
  = Passed
  | Failed
  | Inconclusive T.Text
  | Blocked T.Text
  | NotRun T.Text
  deriving (Eq, Show)

data EvidenceItem
  = EvidenceItem
  { evidenceLocator :: T.Text
  , evidenceSha256 :: T.Text
  , evidenceKind :: T.Text
  , evidenceProducer :: T.Text
  }
  deriving (Eq, Show)

data TestedRevision
  = TestedRevision
  { revisionCommit :: T.Text
  , revisionDirty :: Bool
  }
  deriving (Eq, Show)

data RowInput
  = RowInput
  { rowCriterion :: T.Text
  , rowStatement :: T.Text
  , rowSourceRefs :: [T.Text]
  , rowRequired :: Bool
  , rowMethod :: T.Text
  , rowExpected :: T.Text
  , rowActual :: Maybe T.Text
  , rowClaimed :: Disposition
  , rowEvidence :: [EvidenceItem]
  , rowTestedRevision :: Maybe TestedRevision
  }
  deriving (Eq, Show)

{- | Rules 2–4, applied to a claimed 'Passed' only: incomplete evidence, then
unavailable or changed evidence, then a stale revision. Every other claim is
returned unchanged (a stale FAILED stays FAILED).
-}
effectiveDisposition :: T.Text -> (T.Text -> Maybe T.Text) -> RowInput -> Disposition
effectiveDisposition declared resolve row =
  case rowClaimed row of
    Passed
      | incomplete -> Inconclusive (T.pack "incomplete evidence")
      | any (isNothing . current) (rowEvidence row) -> Inconclusive (T.pack "evidence unavailable")
      | any changed (rowEvidence row) -> Inconclusive (T.pack "evidence changed")
      | fmap revisionCommit (rowTestedRevision row) /= Just declared -> Inconclusive (T.pack "stale revision")
      | otherwise -> Passed
    claim -> claim
 where
  incomplete =
    isNothing (rowActual row)
      || L.null (rowEvidence row)
      || maybe True revisionDirty (rowTestedRevision row)
  current =
    resolve . evidenceLocator
  changed item =
    current item /= Just (evidenceSha256 item)

severity :: Disposition -> Int
severity disposition =
  case disposition of
    Failed -> 4
    Blocked _ -> 3
    Inconclusive _ -> 2
    NotRun _ -> 1
    Passed -> 0

-- | Rule 5: the worst required disposition; no required rows is NOT_RUN.
aggregate :: [(Bool, Disposition)] -> Disposition
aggregate rows =
  case [d | (True, d) <- rows] of
    [] -> NotRun (T.pack "no required rows")
    first : rest -> L.foldl' (\worst d -> if severity d > severity worst then d else worst) first rest

dispositionLabel :: Disposition -> T.Text
dispositionLabel disposition =
  case disposition of
    Passed -> T.pack "PASSED"
    Failed -> T.pack "FAILED"
    Inconclusive why -> T.pack "INCONCLUSIVE (" <> why <> T.pack ")"
    Blocked why -> T.pack "BLOCKED (" <> why <> T.pack ")"
    NotRun why -> T.pack "NOT_RUN (" <> why <> T.pack ")"

dispositionClass :: Disposition -> T.Text
dispositionClass disposition =
  T.pack $
    case disposition of
      Passed -> "ls-passed"
      Failed -> "ls-failed"
      Inconclusive _ -> "ls-inconclusive"
      Blocked _ -> "ls-blocked"
      NotRun _ -> "ls-not-run"
