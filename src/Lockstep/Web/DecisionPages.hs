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
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.Decisions (DecisionReceipt (..), OpenDecision (..), StoppedFacts (..), UnknownFacts (..), decisionId)
import Lockstep.Kernel.Decision (choiceWords)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidText)
import Lockstep.Web.Fragment (attr, cls, fragment, href)

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
            [ E.li [] [E.a [href ("/app/decisions/" <> decisionId d)] [E.text (titleOf d)], E.text (" \8212 " <> askWords d)]
            | d <- ds
            ]
    , E.p [cls "ls-muted"] [E.text "Approving work Lockstep does, signing finished work off and confirming changed checks arrive in a later update of Lockstep."]
    ]

choicesFor :: OpenDecision -> [T.Text]
choicesFor decision =
  case decision of
    StoppedWork _ -> ["put-back", "cancel"]
    UnknownOutcome _ -> ["happened", "did-not-happen", "try-again", "give-up"]

expectedOf :: OpenDecision -> Int
expectedOf decision =
  case decision of
    StoppedWork s -> stoppedRevision s
    UnknownOutcome u -> unknownGeneration u

decisionPage :: OpenDecision -> T.Text -> Maybe T.Text -> LBS.ByteString
decisionPage decision key notice =
  let
    subject = decisionId decision
    choice name =
      let
        (label, consequence) = choiceWords name
      in
        E.div
          [cls "ls-choice"]
          [ E.input [A.type_ HTML.InputRadio, attr "id" ("choice-" <> name), attr "name" "choice", attr "value" name]
          , E.label [attr "for" ("choice-" <> name)] [E.text label]
          , E.p [cls "ls-muted"] [E.text consequence]
          ]
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
              [ E.label [attr "for" "decision-text"] [E.text "What did you see, or why? (needed for It happened, It did not happen and Give up on it)"]
              , E.textarea [attr "id" "decision-text", attr "name" "text", attr "rows" "3", attr "maxlength" "500"] ""
              ]
          , E.div
              [cls "ls-choice"]
              [ E.input [A.type_ HTML.InputCheckbox, attr "id" "acknowledge", attr "name" "acknowledge", attr "value" "yes"]
              , E.label [attr "for" "acknowledge"] [E.text "I understand the step may already have happened, and could happen twice if it is tried again."]
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
               [attr "id" "decision-form", A.method B.FormPOST, A.action (B.mkRawURL ("/app/api/decisions/" <> subject))]
               ( [ E.input [A.type_ HTML.InputHidden, attr "name" "key", attr "value" key]
                 , E.input [A.type_ HTML.InputHidden, attr "name" "expected", attr "value" (T.pack (show (expectedOf decision)))]
                 , E.fieldset [] (E.legend [] [E.text "Your answer"] : fmap choice (choicesFor decision))
                 ]
                   <> extras
                   <> [E.button [attr "id" "decide", attr "type" "submit", cls "ls-primary"] [E.text "Record my decision"]]
               )
           , E.details [] [E.summary [] [E.text "Technical details"], E.dl [cls "ls-facts"] facts]
           , E.p [] [E.a [href "/app/decisions", attr "id" "back-to-decisions"] [E.text "Back to Decisions"]]
           ]

-- | What was recorded; also the page of a decision that is no longer open.
donePage :: DecisionReceipt -> Maybe T.Text -> LBS.ByteString
donePage receipt notice =
  let
    (label, consequence) = choiceWords (receiptChoice receipt)
  in
    fragment $
      [E.h1 [] [E.text "Done"]]
        <> [E.p [cls "ls-notice", attr "role" "alert"] [E.text n] | Just n <- [notice]]
        <> [ E.p [cls "ls-good-text"] [E.text ("Recorded: " <> label <> ".")]
           , E.p [] [E.text consequence]
           ]
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
           , E.p [] [E.a [href "/app/decisions", attr "id" "back-to-decisions"] [E.text "Back to Decisions"]]
           ]
