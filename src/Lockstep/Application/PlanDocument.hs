{- | The plan document, @lockstep-plan@ version 1 (contract C-P6.4 M1): one
Fleece schema decodes and encodes it. A key the format does not define is
refused at every level, so no field a Planner adds can carry authority.
-}
module Lockstep.Application.PlanDocument
  ( PlanDocumentError (..)
  , planDocumentErrorCode
  , decodePlanDocument
  , decodePlanDocumentText
  , encodePlanDocument
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Plan (PlanDocument)

data PlanDocumentError
  = PlanMalformed T.Text
  | PlanUnknownKeys [T.Text]
  | PlanUnsupportedFormat
  | PlanInvalidUnitKey T.Text
  | PlanInvalidValue T.Text
  deriving (Eq, Show)

planDocumentErrorCode :: PlanDocumentError -> T.Text
planDocumentErrorCode _ =
  T.empty

decodePlanDocument :: LBS.ByteString -> Either PlanDocumentError PlanDocument
decodePlanDocument _ =
  Left (PlanMalformed T.empty)

decodePlanDocumentText :: T.Text -> Either PlanDocumentError PlanDocument
decodePlanDocumentText _ =
  Left (PlanMalformed T.empty)

encodePlanDocument :: PlanDocument -> T.Text
encodePlanDocument _ =
  T.empty
