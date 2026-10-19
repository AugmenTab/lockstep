{-# LANGUAGE OverloadedStrings #-}

{- | The read-only projection of the durable ledger (contract C-P2.8 V2, §4).
Each effect's display status comes from "Lockstep.Kernel.EffectView" and the
facts read with it, in the same transaction. 'renderProjection' is the
canonical text: it leaves out the time, so the same durable facts always
render the same, before and after a restart.
-}
module Lockstep.Application.LedgerView
  ( TicketLine (..)
  , EffectLine (..)
  , OrderLine (..)
  , RefusalLine (..)
  , LedgerProjection (..)
  , projectLedger
  , renderProjection
  , projectionTimeText
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time qualified as Time
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Ledger
  ( IntentFacts (..)
  , LedgerFacts (..)
  , LedgerFailure
  , OrderFacts (..)
  , StoredObservation (..)
  , StoredRecovery (..)
  , StoredResolution (..)
  , readLedger
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
import Lockstep.Kernel.EffectView (EffectStatus, StatusFacts (..), effectStatus, effectStatusLabel, effectStatusReason)
import Lockstep.Kernel.Identity (TicketId (..), WorkOrderId (..), uuidText)
import Lockstep.Kernel.WorkOrder (WorkOrder (..), WorkOrderState (..), workOrderStateName)

data TicketLine
  = TicketLine
  { ticketLineId :: TicketId
  , ticketLineTitle :: T.Text
  , ticketLineState :: T.Text
  , ticketLineRevision :: Int
  }
  deriving (Eq, Show)

data EffectLine
  = EffectLine
  { effectLineIntent :: Intent
  , effectLineStatus :: EffectStatus
  , effectLineReason :: T.Text
  , effectLineObservations :: [StoredObservation]
  , effectLineRecoveries :: [StoredRecovery]
  , effectLineResolutions :: [StoredResolution]
  }
  deriving (Eq, Show)

data OrderLine
  = OrderLine
  { orderLineId :: WorkOrderId
  , orderLineTicket :: TicketId
  , orderLineState :: WorkOrderState
  , orderLineRevision :: Int
  , orderLineBinding :: T.Text
  , orderLineEffects :: [EffectLine]
  }
  deriving (Eq, Show)

data RefusalLine
  = RefusalLine
  { refusalLineSubject :: T.Text
  , refusalLineExpected :: Int
  , refusalLinePrincipal :: T.Text
  , refusalLineCommand :: T.Text
  , refusalLineCode :: T.Text
  }
  deriving (Eq, Show)

data LedgerProjection
  = LedgerProjection
  { projectionTime :: UTCTime
  , projectionTickets :: [TicketLine]
  , projectionOrders :: [OrderLine]
  , projectionRefusals :: [RefusalLine]
  , projectionSchedule :: Maybe (T.Text, T.Text)
  }
  deriving (Eq, Show)

projectLedger :: DatabaseRuntime -> IO (Either LedgerFailure LedgerProjection)
projectLedger runtime =
  fmap project <$> readLedger runtime

project :: LedgerFacts -> LedgerProjection
project facts =
  LedgerProjection
    { projectionTime = factTime facts
    , projectionTickets = [TicketLine t title state revision | (t, title, state, revision) <- factTickets facts]
    , projectionOrders = fmap order (factOrders facts)
    , projectionRefusals = [RefusalLine s e p c code | (s, e, p, c, code) <- factRefusals facts]
    , projectionSchedule = factSchedule facts
    }
 where
  order o =
    let
      wo = factOrder o
      active =
        case workOrderState wo of
          Active _ -> True
          _ -> False
    in
      OrderLine
        { orderLineId = workOrderId wo
        , orderLineTicket = factTicket o
        , orderLineState = workOrderState wo
        , orderLineRevision = factRevision o
        , orderLineBinding = factBinding o
        , orderLineEffects = fmap (effect active) (factIntents o)
        }
  effect active i =
    let
      statusFacts = StatusFacts (factTime facts) active (L.any attestedApplied (factResolutions i))
      intent = factIntent i
    in
      EffectLine
        { effectLineIntent = intent
        , effectLineStatus = effectStatus statusFacts intent
        , effectLineReason = effectStatusReason statusFacts intent
        , effectLineObservations = factObservations i
        , effectLineRecoveries = factRecoveries i
        , effectLineResolutions = factResolutions i
        }

-- | An attested application: the only resolution that settles an intent as applied without a destination's answer.
attestedApplied :: StoredResolution -> Bool
attestedApplied r =
  resolutionBasis r == T.pack "human-attested" && T.pack "attested-applied" `T.isPrefixOf` resolutionDecision r

-- | The projection's database time, ISO 8601 (for @ledger show@'s first line).
projectionTimeText :: LedgerProjection -> T.Text
projectionTimeText =
  T.pack . Time.formatTime Time.defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" . projectionTime

-- Rendering (§4) -----------------------------------------------------------------

renderProjection :: LedgerProjection -> T.Text
renderProjection p =
  T.concat
    ( fmap ticketText (projectionTickets p)
        <> L.concatMap orderText (projectionOrders p)
        <> fmap refusalText (projectionRefusals p)
        <> maybe [] (\(_, digest) -> [line ["schedule", T.pack "digest=" <> digest]]) (projectionSchedule p)
    )

line :: [T.Text] -> T.Text
line ws =
  T.unwords ws <> T.pack "\n"

quoted :: T.Text -> T.Text
quoted text =
  T.pack "\"" <> T.concatMap escape text <> T.pack "\""
 where
  escape c =
    case c of
      '\\' -> T.pack "\\\\"
      '"' -> T.pack "\\\""
      _ -> T.singleton c

kv :: String -> T.Text -> T.Text
kv key value =
  T.pack (key <> "=") <> value

tshow :: Show a => a -> T.Text
tshow =
  T.pack . show

ticketText :: TicketLine -> T.Text
ticketText t =
  line ["ticket", ticketIdText (ticketLineId t), kv "state" (ticketLineState t), kv "revision" (tshow (ticketLineRevision t)), kv "title" (quoted (ticketLineTitle t))]

ticketIdText :: TicketId -> T.Text
ticketIdText (TicketId u) =
  uuidText u

orderStateText :: WorkOrderState -> T.Text
orderStateText state =
  workOrderStateName state
    <> case state of
      Halted reason -> T.pack " " <> kv "reason" (quoted reason)
      Waiting _ reason -> T.pack " " <> kv "reason" (quoted reason)
      _ -> T.empty

orderText :: OrderLine -> [T.Text]
orderText o =
  line
    [ "work-order"
    , case orderLineId o of WorkOrderId u -> uuidText u
    , kv "ticket" (ticketIdText (orderLineTicket o))
    , kv "state" (orderStateText (orderLineState o))
    , kv "revision" (tshow (orderLineRevision o))
    , kv "binding" (orderLineBinding o)
    ]
    : L.concatMap effectText (orderLineEffects o)

effectText :: EffectLine -> [T.Text]
effectText e =
  let
    i = effectLineIntent e
    spec = intentSpec i
  in
    T.pack "  "
      <> line
        [ "effect"
        , case intentOperation i of OperationId u -> uuidText u
        , kv "key" (effectKeyText (intentKey i))
        , kv "spec" (effectSpecName spec)
        , kv "class" (effectClassName (effectSpecClass spec))
        , kv "state" (intentStateName (intentState i))
        , kv "generation" (tshow (intentGeneration i))
        , kv "dispatches" (tshow (intentDispatches i))
        , kv "budget" (tshow (effectSpecBudget spec))
        , kv "status" (effectStatusLabel (effectLineStatus e))
        , kv "reason" (quoted (effectLineReason e))
        ]
      : fmap observationText (effectLineObservations e)
        <> fmap recoveryText (effectLineRecoveries e)
        <> fmap resolutionText (effectLineResolutions e)

bool :: Bool -> T.Text
bool b =
  T.pack (if b then "true" else "false")

observationText :: StoredObservation -> T.Text
observationText o =
  T.pack "    "
    <> line
      [ "observation"
      , kv "generation" (tshow (storedGeneration o))
      , kv "accepted" (bool (storedAccepted o))
      , kv "refusal" (fromMaybe "none" (storedRefusal o))
      , storedObservation o
      ]

recoveryText :: StoredRecovery -> T.Text
recoveryText r =
  T.pack "    " <> line ["recovery", kv "generation" (tshow (recoveredGeneration r)), recoveryDecision r]

resolutionText :: StoredResolution -> T.Text
resolutionText r =
  T.pack "    "
    <> line
      [ "resolution"
      , kv "generation" (tshow (resolvedGeneration r))
      , kv "basis" (resolutionBasis r)
      , kv "acknowledged" (bool (resolutionAcknowledged r))
      , resolutionDecision r
      ]

refusalText :: RefusalLine -> T.Text
refusalText r =
  line
    [ "refusal"
    , kv "subject" (refusalLineSubject r)
    , kv "expected" (tshow (refusalLineExpected r))
    , kv "principal" (refusalLinePrincipal r)
    , kv "code" (refusalLineCode r)
    , kv "command" (quoted (refusalLineCommand r))
    ]
