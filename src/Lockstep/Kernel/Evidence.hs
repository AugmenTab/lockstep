{- | Validated evidence values shared by the lifecycles (contract C-P2.2 T8).
The boundary supplies the raw text; only well-formed values are admitted.
-}
module Lockstep.Kernel.Evidence
  ( CommitId
  , mkCommitId
  , commitIdText
  , HumanSignoff
  , mkHumanSignoff
  , humanSignoffText
  ) where

import Data.Char qualified as Char
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

-- | A full Git commit id: 40 lowercase hex characters.
newtype CommitId
  = CommitId T.Text
  deriving (Eq, Ord, Show)

mkCommitId :: T.Text -> Maybe CommitId
mkCommitId text =
  if T.length text == 40 && T.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) text
    then Just (CommitId text)
    else Nothing

commitIdText :: CommitId -> T.Text
commitIdText (CommitId text) =
  text

-- | The receipt of an authenticated human decision (the boundary authenticates it).
newtype HumanSignoff
  = HumanSignoff T.Text
  deriving (Eq, Show)

mkHumanSignoff :: T.Text -> Maybe HumanSignoff
mkHumanSignoff text =
  if T.null text || T.any Char.isControl text
    then Nothing
    else Just (HumanSignoff text)

humanSignoffText :: HumanSignoff -> T.Text
humanSignoffText (HumanSignoff text) =
  text
