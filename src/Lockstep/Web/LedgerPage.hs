{- | The ledger page (contract C-P2.8 V3). Read-only: every Work Order with its
effects, each effect's status as text (its class only a redundant cue), the
evidence behind it, the decision refusals and the latest schedule decision.
A refused observation is marked as refused, and a human attestation is shown
as one, never as an observation.
-}
module Lockstep.Web.LedgerPage
  ( ledgerPage
  , ledgerFailurePage
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.List qualified as L
import Data.Text qualified as T
import Data.Time qualified as Time
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.Ledger (StoredObservation (..), StoredRecovery (..), StoredResolution (..))
import Lockstep.Application.LedgerView
  ( EffectLine (..)
  , LedgerProjection (..)
  , OrderLine (..)
  , RefusalLine (..)
  , TicketLine (..)
  )
import Lockstep.Kernel.Effect
  ( Intent (..)
  , OperationId (..)
  , effectClassName
  , effectKeyText
  , effectSpecBudget
  , effectSpecClass
  , effectSpecName
  , intentStateName
  )
import Lockstep.Kernel.EffectView (effectStatusClass, effectStatusLabel)
import Lockstep.Kernel.Identity (TicketId (..), WorkOrderId (..), uuidText)
import Lockstep.Kernel.WorkOrder (WorkOrderState (..), workOrderStateName)
import Lockstep.Web.Components.Page (page)

txt :: String -> T.Text
txt =
  T.pack

cls :: T.Text -> A.Attribute tag
cls =
  A.class_ . HTML.Class

custom :: String -> T.Text -> A.Attribute tag
custom name =
  A.customAttribute (T.pack name)

tshow :: Int -> T.Text
tshow =
  T.pack . show

ledgerPage :: LedgerProjection -> E.HTML
ledgerPage p =
  page
    (txt "Lockstep ledger")
    [ E.main
        [cls (txt "ls-wide")]
        ( [ E.h1 [] [E.text (txt "Ledger")]
          , E.p
              []
              [ E.text (txt ("Read from the database at " <> Time.formatTime Time.defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC" (projectionTime p) <> ". Read-only. "))
              , E.a [A.href (B.mkRawURL (txt "/operator/ledger"))] [E.text (txt "Refresh")]
              , E.text (txt " · ")
              , E.a [A.href (B.mkRawURL (txt "/operator/center"))] [E.text (txt "Command center")]
              ]
          , E.p
              [cls (txt "ls-muted")]
              [ E.text
                  (txt "An effect counts as applied only when its destination answered so, directly or by a lookup. A human attestation is shown as attested; an unknown or unfinished outcome is never shown as applied.")
              ]
          , E.h2 [] [E.text (txt "Tickets")]
          , ticketTable (projectionTickets p)
          ]
            <> L.concatMap orderSection (projectionOrders p)
            <> [ E.h2 [] [E.text (txt "Refused decisions")]
               , refusalTable (projectionRefusals p)
               , E.h2 [] [E.text (txt "Latest schedule decision")]
               ]
            <> scheduleSection (projectionSchedule p)
        )
    ]

ledgerFailurePage :: E.HTML
ledgerFailurePage =
  page
    (txt "Lockstep ledger")
    [ E.main
        [cls (txt "ls-wide")]
        [ E.h1 [] [E.text (txt "Ledger")]
        , E.p
            [cls (txt "ls-notice")]
            [E.text (txt "The ledger could not be shown: the database is not ready, or a stored record did not reproduce. Nothing partial is shown. See lockstep ledger show and the status page.")]
        ]
    ]

ticketTable :: [TicketLine] -> E.ChildHTML E.Main grandparent
ticketTable rows =
  E.table
    [cls (txt "ls-ledger")]
    [ E.thead [] [E.tr [] (fmap header ["Ticket", "Title", "State", "Revision"])]
    , E.tbody
        []
        [ E.tr
            []
            [ E.th [custom "scope" (txt "row")] [E.code [] [E.text (ticketText (ticketLineId t))]]
            , E.td [] [E.text (ticketLineTitle t)]
            , E.td [] [E.code [] [E.text (ticketLineState t)]]
            , E.td [] [E.text (tshow (ticketLineRevision t))]
            ]
        | t <- rows
        ]
    ]

header :: String -> E.ChildHTML E.TableRow grandparent
header h =
  E.th [custom "scope" (txt "col")] [E.text (txt h)]

ticketText :: TicketId -> T.Text
ticketText (TicketId u) =
  uuidText u

orderStateText :: WorkOrderState -> T.Text
orderStateText state =
  workOrderStateName state
    <> case state of
      Halted reason -> txt " (" <> reason <> txt ")"
      Waiting _ reason -> txt " (" <> reason <> txt ")"
      _ -> T.empty

orderSection :: OrderLine -> [E.ChildHTML E.Main grandparent]
orderSection o =
  [ E.h2 [] [E.text (txt "Work order "), E.code [] [E.text (case orderLineId o of WorkOrderId u -> uuidText u)]]
  , E.p
      []
      [ E.text (txt "Ticket ")
      , E.code [] [E.text (ticketText (orderLineTicket o))]
      , E.text (txt " · state ")
      , E.code [] [E.text (orderStateText (orderLineState o))]
      , E.text (txt (" · revision " <> show (orderLineRevision o) <> " · binding "))
      , E.code [] [E.text (T.take 12 (orderLineBinding o))]
      ]
  , E.table
      [cls (txt "ls-ledger")]
      [ E.thead [] [E.tr [] (fmap header ["Operation", "Effect", "State", "Generation", "Dispatches / budget", "Status", "Reason", "Evidence"])]
      , E.tbody [] (fmap effectRow (orderLineEffects o))
      ]
  ]

effectRow :: EffectLine -> E.ChildHTML E.TableBody grandparent
effectRow e =
  let
    i = effectLineIntent e
    spec = intentSpec i
    status = effectLineStatus e
  in
    E.tr
      []
      [ E.th [custom "scope" (txt "row")] [E.code [] [E.text (case intentOperation i of OperationId u -> uuidText u)]]
      , E.td [] [E.text (effectKeyText (intentKey i) <> txt " · " <> effectSpecName spec <> txt " (" <> effectClassName (effectSpecClass spec) <> txt ")")]
      , E.td [] [E.code [] [E.text (intentStateName (intentState i))]]
      , E.td [] [E.text (tshow (intentGeneration i))]
      , E.td [] [E.text (tshow (intentDispatches i) <> txt " / " <> tshow (effectSpecBudget spec))]
      , E.td [] [E.span [cls (effectStatusClass status)] [E.text (effectStatusLabel status)]]
      , E.td [] [E.text (effectLineReason e)]
      , E.td [] [evidenceList e]
      ]

evidenceList :: EffectLine -> E.ChildHTML E.TableDataCell grandparent
evidenceList e =
  case fmap observationItem (effectLineObservations e) <> fmap recoveryItem (effectLineRecoveries e) <> fmap resolutionItem (effectLineResolutions e) of
    [] -> E.text (txt "none recorded")
    items -> E.ul [] items

observationItem :: StoredObservation -> E.ChildHTML E.UnorderedList grandparent
observationItem o =
  E.li
    []
    [ E.text
        ( case storedRefusal o of
            Nothing -> txt "observed (generation " <> tshow (storedGeneration o) <> txt "): "
            Just code -> txt "REFUSED (" <> code <> txt ") observation (generation " <> tshow (storedGeneration o) <> txt "): "
        )
    , E.code [] [E.text (storedObservation o)]
    ]

recoveryItem :: StoredRecovery -> E.ChildHTML E.UnorderedList grandparent
recoveryItem r =
  E.li [] [E.text (txt "recovery (generation " <> tshow (recoveredGeneration r) <> txt "): "), E.code [] [E.text (recoveryDecision r)]]

resolutionItem :: StoredResolution -> E.ChildHTML E.UnorderedList grandparent
resolutionItem r =
  E.li
    []
    [ E.text (resolutionBasis r <> txt " (generation " <> tshow (resolvedGeneration r) <> (if resolutionAcknowledged r then txt ", duplication risk acknowledged" else T.empty) <> txt "): ")
    , E.code [] [E.text (resolutionDecision r)]
    ]

refusalTable :: [RefusalLine] -> E.ChildHTML E.Main grandparent
refusalTable rows =
  E.table
    [cls (txt "ls-ledger")]
    [ E.thead [] [E.tr [] (fmap header ["Subject", "Expected revision", "Principal", "Code", "Command"])]
    , E.tbody
        []
        [ E.tr
            []
            [ E.th [custom "scope" (txt "row")] [E.code [] [E.text (refusalLineSubject r)]]
            , E.td [] [E.text (tshow (refusalLineExpected r))]
            , E.td [] [E.text (refusalLinePrincipal r)]
            , E.td [] [E.code [] [E.text (refusalLineCode r)]]
            , E.td [] [E.code [] [E.text (refusalLineCommand r)]]
            ]
        | r <- rows
        ]
    ]

scheduleSection :: Maybe (T.Text, T.Text) -> [E.ChildHTML E.Main grandparent]
scheduleSection schedule =
  case schedule of
    Nothing -> [E.p [] [E.text (txt "No schedule decision yet.")]]
    Just (rendering, digest) ->
      [ E.p [] [E.text (txt "Digest "), E.code [] [E.text digest]]
      , E.pre [] [E.text rendering]
      ]
