{- | The canonical backlog document, @lockstep-backlog@ version 1 (contract
C-P6.1 §1): one Fleece schema decodes and encodes it. A document with a key
the format does not define is refused, so no field a source adds can carry
state, priority or approval into Lockstep (B9).
-}
module Lockstep.Application.BacklogDocument
  ( DocumentError (..)
  , documentErrorCode
  , decodeBacklogDocument
  , encodeBacklogDocument
  , criteriaText
  , decodeCriteria
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Backlog (BacklogDocument, Criterion)

data DocumentError
  = DocumentMalformed T.Text
  | DocumentUnknownKeys [T.Text]
  | DocumentUnsupportedFormat
  | DocumentInvalidProvider
  | DocumentInvalidLocator
  | DocumentInvalidKey T.Text
  | DocumentInvalidRevision
  | DocumentInvalidRepository
  deriving (Eq, Show)

documentErrorCode :: DocumentError -> T.Text
documentErrorCode _ =
  T.empty

decodeBacklogDocument :: LBS.ByteString -> Either DocumentError BacklogDocument
decodeBacklogDocument _ =
  Left (DocumentMalformed T.empty)

encodeBacklogDocument :: BacklogDocument -> T.Text
encodeBacklogDocument _ =
  T.empty

-- | The stored form of an item's criteria (B8), and its reading.
criteriaText :: [Criterion] -> T.Text
criteriaText _ =
  T.empty

decodeCriteria :: T.Text -> Either T.Text [Criterion]
decodeCriteria _ =
  Left T.empty
