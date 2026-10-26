{-# LANGUAGE OverloadedStrings #-}

{- | The Activity section (contract C-P3.9 N4, N5): what needs attention first,
then every piece of work with every step (its C-P2.8 label unchanged, and what
that label means), refused requests, and the raw ledger text under Technical
details. No form, no button; decisions happen on their own pages (C-P3.8).
-}
module Lockstep.Web.ActivityPage
  ( activityPage
  ) where

import Brigid.HTML.Elements qualified as E
import Control.Applicative ((<|>))
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude

import Lockstep.Application.Activity (ActivityView (..), retryLeft)
import Lockstep.Application.Ledger (LedgerFailure, StoredObservation (..), StoredRecovery (..), StoredResolution (..))
import Lockstep.Application.LedgerView (EffectLine (..), LedgerProjection (..), OrderLine (..), RefusalLine (..), TicketLine (..))
import Lockstep.Kernel.Activity (needsAttention, nextStep, orderStateWords, refusalMeaning, statusMeaning)
import Lockstep.Kernel.Effect (Intent (..), OperationId (..), effectSpecName)
import Lockstep.Kernel.EffectView (EffectStatus (..), effectStatusClass, effectStatusLabel)
import Lockstep.Kernel.Identity (TicketId (..), WorkOrderId (..), uuidText)
import Lockstep.Kernel.WorkOrder (WorkOrderState (..))
import Lockstep.Web.Fragment (attr, cls, fragment, href)

orderText :: WorkOrderId -> T.Text
orderText (WorkOrderId u) =
  uuidText u

opText :: OperationId -> T.Text
opText (OperationId u) =
  uuidText u

ticketText :: TicketId -> T.Text
ticketText (TicketId u) =
  uuidText u

label :: EffectStatus -> E.ChildHTML E.ListItem E.UnorderedList
label status =
  E.span [cls (effectStatusClass status)] [E.text (effectStatusLabel status)]

activityPage :: Either LedgerFailure ActivityView -> LBS.ByteString
activityPage read' =
  fragment $
    E.h1 [] [E.text "Activity"]
      : case read' of
        Left _ -> [E.p [cls "ls-notice"] [E.text "The history cannot be shown right now, so nothing here is guessed. Run lockstep to see what to do."]]
        Right view -> body view

body :: ActivityView -> [E.ChildHTML E.Division E.Body]
body view =
  let
    projection = activityProjection view
    orders = projectionOrders projection
    titles = [(ticketLineId t, ticketLineTitle t) | t <- projectionTickets projection]
    titleOf o = fromMaybe "" (L.lookup (orderLineTicket o) titles)
    subjectTitle subject =
      fromMaybe
        "Something no longer listed"
        ( L.lookup subject [(orderText (orderLineId o), titleOf o) | o <- orders]
            <|> L.lookup subject [(ticketText t, title) | (t, title) <- titles]
        )
    attention =
      [ E.li
          []
          ( [ E.text (titleOf o <> " \8212 the step " <> effectSpecName (intentSpec i) <> ": ")
            , label (effectLineStatus e)
            , E.text (" " <> statusMeaning (effectLineStatus e) (retryLeft i) <> maybe "" (" " <>) (nextStep (effectLineStatus e) (retryLeft i)))
            ]
              <> [ E.text " "
                 | effectLineStatus e == StatusUnknown
                 ]
              <> [ E.a [href ("/app/decisions/" <> opText (intentOperation i))] [E.text "Decide"]
                 | effectLineStatus e == StatusUnknown
                 ]
          )
      | o <- orders
      , e <- orderLineEffects o
      , let
          i = effectLineIntent e
      , needsAttention (effectLineStatus e) (retryLeft i)
      ]
        <> [ E.li
               []
               [ E.text (titleOf o <> " \8212 the work: " <> orderStateWords (orderLineState o) <> " ")
               , E.a [href ("/app/decisions/" <> orderText (orderLineId o))] [E.text "Decide"]
               ]
           | o <- orders
           , Halted _ <- [orderLineState o]
           ]
    step e =
      let
        i = effectLineIntent e
        raw =
          T.unlines $
            [effectLineReason e]
              <> fmap storedObservation (effectLineObservations e)
              <> fmap recoveryDecision (effectLineRecoveries e)
              <> fmap resolutionDecision (effectLineResolutions e)
      in
        E.li
          []
          [ E.text (effectSpecName (intentSpec i) <> ": ")
          , label (effectLineStatus e)
          , E.text (" " <> statusMeaning (effectLineStatus e) (retryLeft i))
          , E.details [] [E.summary [] [E.text "Technical details"], E.pre [] [E.text (opText (intentOperation i) <> "\n" <> raw)]]
          ]
    work o =
      [E.p [] [E.text (orderStateWords (orderLineState o))]]
        <> if L.null (orderLineEffects o)
          then [E.p [cls "ls-muted"] [E.text "No steps recorded."]]
          else [E.ul [cls "ls-steps"] (fmap step (orderLineEffects o))]
    groups =
      L.groupBy (\a b -> titleOf a == titleOf b) (L.sortOn (\o -> (titleOf o, orderText (orderLineId o))) orders)
    refusals = projectionRefusals projection
  in
    if L.null orders && L.null refusals
      then [E.p [] [E.text "Nothing has happened yet."], raw']
      else
        [ E.h2 [] [E.text "Needs attention"]
        , if L.null attention
            then E.p [] [E.text "Nothing needs attention."]
            else E.ul [cls "ls-attention"] attention
        , E.h2 [] [E.text "All work"]
        ]
          <> L.concat [E.h3 [] [E.text (titleOf first)] : L.concatMap work g | g@(first : _) <- groups]
          <> [ E.h2 [] [E.text "Refused requests"]
             , if L.null refusals
                 then E.p [] [E.text "None."]
                 else E.ul [] [E.li [] [E.text (subjectTitle (refusalLineSubject r) <> ": " <> refusalMeaning (refusalLineCode r))] | r <- refusals]
             , raw'
             ]
 where
  raw' =
    E.details
      [attr "id" "activity-raw"]
      [ E.summary [] [E.text "Technical details"]
      , E.p [] [E.text ("The ledger as read at " <> activityTime view <> ", in its canonical form:")]
      , E.pre [] [E.text (activityRaw view)]
      ]
