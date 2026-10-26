{- | Decisions a person makes in the browser (contract C-P3.8 M2, M5): the
typed request, its canonical payload (the receipt's digest is the hash of it),
the rules for the text a person writes, and the plain words for each choice
and refusal. Pure; no principal is part of a request: the application applies
every one as a Human.
-}
module Lockstep.Kernel.Decision
  ( DecisionRequest (..)
  , decisionPayload
  , decisionSubject
  , decisionChoiceName
  , decisionExpected
  , checkDecisionText
  , choiceWords
  , decisionRefusalWords
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Effect (OperationId (..))
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidText)

data DecisionRequest
  = PutBackInLine WorkOrderId Int
  | CancelWork WorkOrderId Int
  | ItHappened OperationId Int T.Text
  | ItDidNotHappen OperationId Int T.Text
  | TryAgain OperationId Int Bool
  | GiveUp OperationId Int T.Text Bool
  deriving (Eq, Show)

decisionSubject :: DecisionRequest -> T.Text
decisionSubject request =
  case request of
    PutBackInLine (WorkOrderId u) _ -> uuidText u
    CancelWork (WorkOrderId u) _ -> uuidText u
    ItHappened (OperationId u) _ _ -> uuidText u
    ItDidNotHappen (OperationId u) _ _ -> uuidText u
    TryAgain (OperationId u) _ _ -> uuidText u
    GiveUp (OperationId u) _ _ _ -> uuidText u

decisionChoiceName :: DecisionRequest -> T.Text
decisionChoiceName request =
  T.pack $
    case request of
      PutBackInLine _ _ -> "put-back"
      CancelWork _ _ -> "cancel"
      ItHappened {} -> "happened"
      ItDidNotHappen {} -> "did-not-happen"
      TryAgain {} -> "try-again"
      GiveUp {} -> "give-up"

decisionExpected :: DecisionRequest -> Int
decisionExpected request =
  case request of
    PutBackInLine _ n -> n
    CancelWork _ n -> n
    ItHappened _ n _ -> n
    ItDidNotHappen _ n _ -> n
    TryAgain _ n _ -> n
    GiveUp _ n _ _ -> n

decisionText :: DecisionRequest -> Maybe T.Text
decisionText request =
  case request of
    ItHappened _ _ t -> Just t
    ItDidNotHappen _ _ t -> Just t
    GiveUp _ _ t _ -> Just t
    _ -> Nothing

decisionAcknowledged :: DecisionRequest -> Bool
decisionAcknowledged request =
  case request of
    TryAgain _ _ a -> a
    GiveUp _ _ _ a -> a
    _ -> False

-- | M2: one field per line; the text quoted with @\\@, @"@ and new lines escaped.
decisionPayload :: DecisionRequest -> T.Text
decisionPayload request =
  T.unlines
    [ T.pack "lockstep-decision-v1"
    , T.pack "subject " <> decisionSubject request
    , T.pack "choice " <> decisionChoiceName request
    , T.pack "expected " <> T.pack (show (decisionExpected request))
    , T.pack "text " <> quoted (fromMaybe T.empty (decisionText request))
    , T.pack "acknowledged " <> T.pack (if decisionAcknowledged request then "true" else "false")
    ]

quoted :: T.Text -> T.Text
quoted text =
  T.pack "\"" <> T.concatMap escape text <> T.pack "\""
 where
  escape c =
    case c of
      '\\' -> T.pack "\\\\"
      '"' -> T.pack "\\\""
      '\n' -> T.pack "\\n"
      _ -> T.singleton c

-- | Evidence and reasons: 1 to 500 characters after trimming, no control characters.
checkDecisionText :: DecisionRequest -> Either T.Text ()
checkDecisionText request =
  case fmap T.strip (decisionText request) of
    Nothing -> Right ()
    Just t
      | T.null t -> Left (T.pack "text-empty")
      | T.length t > 500 -> Left (T.pack "text-too-long")
      | T.any Char.isControl t -> Left (T.pack "text-control")
      | otherwise -> Right ()

-- | A choice's label and what it will do.
choiceWords :: T.Text -> (T.Text, T.Text)
choiceWords name =
  case T.unpack name of
    "put-back" -> pair "Put it back in line" "The work goes back to the queue and can be picked up again; what it already did is kept."
    "cancel" -> pair "Cancel this work" "The work is stopped for good and will not be picked up again. The task itself stays."
    "happened" -> pair "It happened" "Lockstep records, on your word, that the step took effect. It is marked as confirmed by a person, not as checked by Lockstep."
    "did-not-happen" -> pair "It did not happen" "Lockstep records, on your word, that the step did not take effect. It may be tried again if tries are left."
    "try-again" -> pair "Try it again" "The step may run once more. If the first try did take effect, it could happen twice: tick the box to say you accept that."
    "give-up" -> pair "Give up on it" "The step is abandoned and will not run again, and its work stops until a person puts it back in line."
    _ -> pair "Unknown choice" "Lockstep does not offer this choice."
 where
  pair a b =
    (T.pack a, T.pack b)

decisionRefusalWords :: T.Text -> T.Text
decisionRefusalWords code =
  T.pack $
    case T.unpack code of
      c | c `L.elem` ["stale-revision", "stale-claim", "not-unknown", "already-settled", "illegal-transition", "already-terminal"] -> "This changed since the page was shown. Nothing was changed; here is how it stands now."
      "duplication-risk-not-acknowledged" -> "Trying again could make it happen twice. Nothing was changed. Tick the box to say you accept that, then try again."
      "idempotency-key-expired" -> "It is too late to try this step again safely. Nothing was changed. Choose another answer."
      "key-conflict" -> "This form was already used for a different answer. Nothing was changed. Open the decision again."
      "text-empty" -> "Write what you saw or why, in a few words."
      "text-too-long" -> "Keep it to 500 characters or fewer."
      "text-control" -> "Use plain text on one line."
      _ -> "Lockstep could not record this. Nothing was changed. The exact reason is under Technical details."
