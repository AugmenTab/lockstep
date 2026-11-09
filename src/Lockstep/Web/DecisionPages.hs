{-# LANGUAGE OverloadedStrings #-}

{- | The Decisions pages (contract C-P3.8 M5–M7): the section lists each open
decision as a link (the C-P3.4 rule for the section holds: no form, no button,
and it names what arrives later); one page per decision with what it is about,
how it stands, the legal choices and what each will do; and the Done page with
the receipt. No Work Order, Ticket, intent, generation, Supervisor or scheduler
word outside Technical details.
-}
module Lockstep.Web.DecisionPages
  ( decisionsOverview
  , decisionPage
  , donePage
  , DecisionChoice (..)
  , decisionChoiceCode
  , choiceFits
  , decisionRequest
  , openDecisionKey
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.Decisions (DecisionReceipt (..), OpenDecision (..), StoppedFacts (..), UnknownFacts (..), decisionId)
import Lockstep.Kernel.Decision (DecisionRequest (..), choiceWords)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidText)
import Lockstep.Web.Fields (acknowledgeField, choiceField, expectedField, keyField, textField)
import Lockstep.Web.Fragment (attr, cls, elementId, fragment)
import Lockstep.Web.Routes.App (Section (Decisions), decideAction, decisionLink, sectionLink)
import Lockstep.Web.Routes.Params (DecisionKey, decisionOperation, decisionWorkOrder, stoppedWorkKey, unknownOutcomeKey)

{- | A person's answer to a decision (C-P3.8 M6), spelled as the form's
@choice@ value. Stopped work is put back or canceled; an unknown outcome gets the
other four.
-}
data DecisionChoice
  = ChoosePutBack
  | ChooseCancel
  | ChooseHappened
  | ChooseDidNotHappen
  | ChooseTryAgain
  | ChooseGiveUp
  deriving (Eq, Enum, Bounded)

decisionChoiceCode :: DecisionChoice -> T.Text
decisionChoiceCode choice =
  case choice of
    ChoosePutBack -> "put-back"
    ChooseCancel -> "cancel"
    ChooseHappened -> "happened"
    ChooseDidNotHappen -> "did-not-happen"
    ChooseTryAgain -> "try-again"
    ChooseGiveUp -> "give-up"

-- | The address of an open decision: its work order, or its operation.
openDecisionKey :: OpenDecision -> DecisionKey
openDecisionKey decision =
  case decision of
    StoppedWork s -> stoppedWorkKey (stoppedOrder s)
    UnknownOutcome u -> unknownOutcomeKey (unknownOperation u)

-- | A choice belongs to its open decision.
choiceFits :: DecisionChoice -> OpenDecision -> Bool
choiceFits choice decision =
  choice `L.elem` choicesFor decision

{- | The request a choice makes about the decision at @key@: a stopped-work
choice names a work order, an unknown-outcome choice an operation.
-}
decisionRequest :: DecisionChoice -> DecisionKey -> Int -> T.Text -> Bool -> DecisionRequest
decisionRequest choice key expected text acknowledged =
  case choice of
    ChoosePutBack -> PutBackInLine (decisionWorkOrder key) expected
    ChooseCancel -> CancelWork (decisionWorkOrder key) expected
    ChooseHappened -> ItHappened (decisionOperation key) expected text
    ChooseDidNotHappen -> ItDidNotHappen (decisionOperation key) expected text
    ChooseTryAgain -> TryAgain (decisionOperation key) expected acknowledged
    ChooseGiveUp -> GiveUp (decisionOperation key) expected text acknowledged

backToDecisions :: E.ChildHTML E.Division E.Body
backToDecisions =
  E.p [] [E.a [A.href (sectionLink Decisions), A.id (elementId 'b' "ack-to-decisions")] [E.text "Back to Decisions"]]

askWords :: OpenDecision -> T.Text
askWords decision =
  case decision of
    StoppedWork _ -> "This work was stopped. Should it go back in line?"
    UnknownOutcome u -> "Nobody knows whether a step happened (" <> unknownStep u <> "). What happened?"

titleOf :: OpenDecision -> T.Text
titleOf decision =
  case decision of
    StoppedWork s -> stoppedTitle s
    UnknownOutcome u -> unknownTitle u

decisionsOverview :: Maybe [OpenDecision] -> LBS.ByteString
decisionsOverview open =
  fragment
    [ E.h1 [] [E.text "Decisions"]
    , E.p [] [E.text "Things only you can decide. Open one to see what it is about and what each answer will do."]
    , case open of
        Nothing -> E.p [cls "ls-notice"] [E.text "The decisions cannot be shown right now. Run lockstep to see what to do."]
        Just [] -> E.p [] [E.text "Nothing needs your decision right now."]
        Just ds ->
          E.ul
            [cls "ls-projects"]
            [ E.li [] [E.a [A.href (decisionLink (openDecisionKey d))] [E.text (titleOf d)], E.text (" \8212 " <> askWords d)]
            | d <- ds
            ]
    , E.p [cls "ls-muted"] [E.text "Approving work Lockstep does, signing finished work off and confirming changed checks arrive in a later update of Lockstep."]
    ]

choicesFor :: OpenDecision -> [DecisionChoice]
choicesFor decision =
  case decision of
    StoppedWork _ -> [ChoosePutBack, ChooseCancel]
    UnknownOutcome _ -> [ChooseHappened, ChooseDidNotHappen, ChooseTryAgain, ChooseGiveUp]

expectedOf :: OpenDecision -> Int
expectedOf decision =
  case decision of
    StoppedWork s -> stoppedRevision s
    UnknownOutcome u -> unknownGeneration u

decisionPage :: OpenDecision -> T.Text -> Maybe T.Text -> LBS.ByteString
decisionPage decision key notice =
  let
    subject = decisionId decision
    choice c =
      let
        name = decisionChoiceCode c
        (label, consequence) = choiceWords name
        choiceId = elementId 'c' ("hoice-" <> name)
      in
        E.div
          [cls "ls-choice"]
          [ E.input [A.type_ HTML.InputRadio, A.id choiceId, A.name choiceField, attr "value" name]
          , E.label [A.for choiceId] [E.text label]
          , E.p [cls "ls-muted"] [E.text consequence]
          ]
    textId = elementId 'd' "ecision-text"
    acknowledgeId = elementId 'a' "cknowledge"
    story =
      case decision of
        StoppedWork s ->
          [ E.p [] [E.text "This work was stopped and waits for a person to say what happens next."]
          , E.p [] [E.text ("The reason recorded: " <> stoppedReason s)]
          ]
        UnknownOutcome u ->
          [ E.p [] [E.text ("Lockstep started the step " <> unknownStep u <> " but never learned whether it took effect. Its work cannot go on until a person answers.")]
          , E.p [] [E.text ("What Lockstep recorded: " <> unknownReason u)]
          ]
    extras =
      case decision of
        StoppedWork _ -> []
        UnknownOutcome _ ->
          [ E.div
              [cls "ls-field"]
              [ E.label [A.for textId] [E.text "What did you see, or why? (needed for It happened, It did not happen and Give up on it)"]
              , E.textarea [A.id textId, A.name textField, attr "rows" "3", attr "maxlength" "500"] ""
              ]
          , E.div
              [cls "ls-choice"]
              [ E.input [A.type_ HTML.InputCheckbox, A.id acknowledgeId, A.name acknowledgeField, attr "value" "yes"]
              , E.label [A.for acknowledgeId] [E.text "I understand the step may already have happened, and could happen twice if it is tried again."]
              ]
          ]
    facts =
      [ E.dt [] [E.text "Subject"]
      , E.dd [] [E.code [] [E.text subject]]
      ]
        <> case decision of
          StoppedWork s ->
            [ E.dt [] [E.text "Work Order state"]
            , E.dd [] [E.code [] [E.text ("halted, revision " <> T.pack (show (stoppedRevision s)))]]
            ]
          UnknownOutcome u ->
            [ E.dt [] [E.text "Effect intent"]
            , E.dd [] [E.code [] [E.text ("UNKNOWN, generation " <> T.pack (show (unknownGeneration u)) <> ", work order " <> orderText (unknownOrder u))]]
            , E.dt [] [E.text "Observations"]
            , E.dd [] [E.code [] [E.text (if null (unknownObservations u) then "none" else T.unlines (unknownObservations u))]]
            ]
    orderText (WorkOrderId w) =
      uuidText w
  in
    fragment $
      [ E.h1 [] [E.text (titleOf decision)]
      , E.p [cls "ls-muted"] [E.text "A decision for you"]
      ]
        <> [E.p [cls "ls-notice", attr "role" "alert"] [E.text n] | Just n <- [notice]]
        <> [E.h2 [] [E.text "How it stands"]]
        <> story
        <> [ E.h2 [] [E.text "What do you want to do?"]
           , E.form
               [A.id (elementId 'd' "ecision-form"), A.method B.FormPOST, A.action (decideAction (openDecisionKey decision))]
               ( [ E.input [A.type_ HTML.InputHidden, A.name keyField, attr "value" key]
                 , E.input [A.type_ HTML.InputHidden, A.name expectedField, attr "value" (T.pack (show (expectedOf decision)))]
                 , E.fieldset [] (E.legend [] [E.text "Your answer"] : fmap choice (choicesFor decision))
                 ]
                   <> extras
                   <> [E.button [A.id (elementId 'd' "ecide"), attr "type" "submit", cls "ls-primary"] [E.text "Record my decision"]]
               )
           , E.details [] [E.summary [] [E.text "Technical details"], E.dl [cls "ls-facts"] facts]
           , backToDecisions
           ]

{- | What was recorded; also the page of a decision that is no longer open. A
receipt that is no longer current (C-C.R1 R4: the work changed after it) is
never shown as how things stand; the earlier answer stays under Technical
details.
-}
donePage :: DecisionReceipt -> Maybe T.Text -> LBS.ByteString
donePage receipt notice =
  let
    (label, consequence) = choiceWords (receiptChoice receipt)
    outcome
      | receiptCurrent receipt =
          [ E.h1 [] [E.text "Done"]
          , E.p [cls "ls-good-text"] [E.text ("Recorded: " <> label <> ".")]
          , E.p [] [E.text consequence]
          ]
      | otherwise =
          [ E.h1 [] [E.text "Nothing to decide here now"]
          , E.p [] [E.text "This decision is no longer waiting for you. It was decided or changed elsewhere after the last answer recorded on this page, so that answer is not how it stands now."]
          , E.p [] [E.text "Decisions shows everything that needs you."]
          ]
  in
    fragment $
      L.take 1 outcome
        <> [E.p [cls "ls-notice", attr "role" "alert"] [E.text n] | Just n <- [notice]]
        <> L.drop 1 outcome
        <> [E.p [] [E.text "This answer was already recorded; nothing was done twice."] | receiptReplayed receipt]
        <> [ E.details
               []
               [ E.summary [] [E.text "Technical details"]
               , E.dl
                   [cls "ls-facts"]
                   [ E.dt [] [E.text "Receipt"]
                   , E.dd [] [E.code [] [E.text (receiptSubject receipt <> " " <> receiptChoice receipt <> " expected=" <> T.pack (show (receiptExpected receipt)) <> " " <> receiptOutcome receipt)]]
                   ]
               ]
           , backToDecisions
           ]
