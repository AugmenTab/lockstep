{-# LANGUAGE OverloadedStrings #-}

{- | Typed path parameters (STACK_PATTERNS §5): each parses its segment to the
domain type when a request is recognised, and renders it when a URL is
generated. An identity is the canonical lowercase UUID of the Kernel's
'parseIdentity'; a segment that is not one is no route (404), so no handler
sees an unparsed id.
-}
module Lockstep.Web.Routes.Params
  ( identityParam
  , projectIdParam
  , taskIdParam
  , transactionIdParam
  , DecisionKey
  , decisionKeyParam
  , decisionKeyText
  , stoppedWorkKey
  , unknownOutcomeKey
  , decisionWorkOrder
  , decisionOperation
  , receiptIdParam
  ) where

import Beeline.Routing qualified as R
import Data.Bits (toIntegralSized)
import Data.Char qualified as Char
import Data.Coerce (Coercible, coerce)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Kernel.Effect (OperationId (..))
import Lockstep.Kernel.Identity (ProjectId (..), ReceiptId (..), TaskId (..), TransactionId (..), Uuid, WorkOrderId (..), identityText, parseIdentity, receiptIdNumber)

identityParam :: Coercible Uuid identity => T.Text -> R.ParameterDefinition identity
identityParam name =
  R.convertParam
    (Just "uuid")
    (maybe (Left "not a canonical id") Right . parseIdentity)
    identityText
    (R.textParam name)

projectIdParam :: R.ParameterDefinition ProjectId
projectIdParam =
  identityParam "projectId"

taskIdParam :: R.ParameterDefinition TaskId
taskIdParam =
  identityParam "taskId"

transactionIdParam :: R.ParameterDefinition TransactionId
transactionIdParam =
  identityParam "transactionId"

{- | What a decision's address names (C-P3.8 M6): stopped work is named by its
work order, an unknown outcome by its operation, and both share the one frozen
address @/app/decisions/<uuid>@. The key keeps the UUID; which of the two it is
comes from the decision it names (or, once closed, from the choice made), never
from this text.
-}
newtype DecisionKey
  = DecisionKey Uuid
  deriving (Eq)

decisionKeyParam :: R.ParameterDefinition DecisionKey
decisionKeyParam =
  identityParam "decisionId"

decisionKeyText :: DecisionKey -> T.Text
decisionKeyText =
  identityText

stoppedWorkKey :: WorkOrderId -> DecisionKey
stoppedWorkKey =
  coerce

unknownOutcomeKey :: OperationId -> DecisionKey
unknownOutcomeKey =
  coerce

decisionWorkOrder :: DecisionKey -> WorkOrderId
decisionWorkOrder =
  coerce

decisionOperation :: DecisionKey -> OperationId
decisionOperation =
  coerce

{- | A receipt number: plain decimal digits, at most 18 of them, within the
key's range; anything else is no receipt (it never wraps to another).
-}
receiptIdParam :: R.ParameterDefinition ReceiptId
receiptIdParam =
  R.convertParam
    (Just "int64")
    parseReceipt
    (T.pack . show . receiptIdNumber)
    (R.textParam "receiptId")
 where
  parseReceipt t =
    case TR.decimal t of
      Right (n, rest)
        | T.null rest
        , T.length t <= 18
        , T.all Char.isDigit t
        , Just i <- toIntegralSized (n :: Integer) ->
            Right (ReceiptId i)
      _ -> Left "not a receipt number"
