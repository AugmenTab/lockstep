{- | Canonical event texts (contract C-P2.5 E10, §4). Each durable Ticket and
Work Order event is one line: a verb, then @key=value@ fields in a fixed
order, where text values are quoted with @\\@ and @"@ escaped. Inputs that
carry another lifecycle's opaque evidence are not durable in Phase 2 and do
not encode. Decoding accepts exactly the encodings.
-}
module Lockstep.Kernel.EventCodec
  ( principalName
  , parsePrincipal
  , WorkOrderEvent (..)
  , TicketEvent (..)
  , encodeWorkOrderEvent
  , decodeWorkOrderEvent
  , encodeTicketEvent
  , decodeTicketEvent
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Evidence (humanSignoffText, mkHumanSignoff)
import Lockstep.Kernel.Identity (EngineerId (..), WorkOrderId (..), parseUuid, uuidText)
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Principal (..))
import Lockstep.Kernel.WorkOrder (Claim (..), WorkOrderInput (..))

principalName :: Principal -> T.Text
principalName principal =
  T.pack $
    case principal of
      Human -> "human"
      Supervisor -> "supervisor"
      Scheduler -> "scheduler"
      DeliveryAdapter -> "delivery-adapter"
      Agent -> "agent"

-- | An @agent@ event is never written, so it never parses.
parsePrincipal :: T.Text -> Maybe Principal
parsePrincipal text =
  L.find ((== text) . principalName) [Human, Supervisor, Scheduler, DeliveryAdapter]

data WorkOrderEvent
  = WorkOrderCreated
  | WorkOrderStep WorkOrderInput
  deriving (Eq, Show)

data TicketEvent
  = TicketCreated T.Text
  | TicketRevised T.Text
  | TicketStep TicketInput
  deriving (Eq, Show)

notDurable :: String -> Either T.Text a
notDurable what =
  Left (T.pack (what <> " carries another lifecycle's evidence and is not durable in Phase 2"))

-- Encoding -------------------------------------------------------------------

encodeWorkOrderEvent :: WorkOrderEvent -> Either T.Text T.Text
encodeWorkOrderEvent event =
  case event of
    WorkOrderCreated -> Right (T.pack "create")
    WorkOrderStep input ->
      case input of
        WoMarkEligible -> verb "mark-eligible" []
        WoMarkIneligible -> verb "mark-ineligible" []
        WoClaim c -> verb "claim" (claimFields c)
        WoRelease c -> verb "release" (claimFields c)
        WoStart c -> verb "start" (claimFields c)
        WoWait c reason -> verb "wait" (claimFields c <> [quoted "reason" reason])
        WoResume c -> verb "resume" (claimFields c)
        WoComplete c [] -> verb "complete" (claimFields c)
        WoComplete _ _ -> notDurable "complete with Work Units"
        WoHalt reason -> verb "halt" [quoted "reason" reason]
        WoRequeue -> verb "requeue" []
        WoSupersede (WorkOrderId u) -> verb "supersede" [bare "by" (uuidText u)]
        WoCancel -> verb "cancel" []

encodeTicketEvent :: TicketEvent -> Either T.Text T.Text
encodeTicketEvent event =
  case event of
    TicketCreated title -> verb "create" [quoted "title" title]
    TicketRevised title -> verb "revise" [quoted "title" title]
    TicketStep input ->
      case input of
        TicketAccept -> verb "accept" []
        TicketStartWork -> verb "start-work" []
        TicketWorkAccepted _ -> notDurable "work-accepted"
        TicketReviewRequested -> verb "review-requested" []
        TicketChangesRequested -> verb "changes-requested" []
        TicketIntegrated _ -> notDurable "integrated"
        TicketSignoff signoff -> verb "signoff" [quoted "by" (humanSignoffText signoff)]
        TicketCancel signoff -> verb "cancel" [quoted "by" (humanSignoffText signoff)]
        TicketBlock reason -> verb "block" [quoted "reason" reason]
        TicketUnblock -> verb "unblock" []

verb :: String -> [T.Text] -> Either T.Text T.Text
verb name parts =
  Right (T.unwords (T.pack name : parts))

claimFields :: Claim -> [T.Text]
claimFields (Claim (EngineerId u) generation) =
  [bare "engineer" (uuidText u), bare "generation" (T.pack (show generation))]

bare :: String -> T.Text -> T.Text
bare key value =
  T.pack (key <> "=") <> value

quoted :: String -> T.Text -> T.Text
quoted key value =
  T.pack (key <> "=\"") <> T.concatMap escape value <> T.pack "\""
 where
  escape c =
    case c of
      '\\' -> T.pack "\\\\"
      '"' -> T.pack "\\\""
      _ -> T.singleton c

-- Decoding -------------------------------------------------------------------

data Value
  = Bare T.Text
  | Quoted T.Text
  deriving (Eq)

-- | The verb and its fields, or Nothing for any text that is not well formed.
parseLine :: T.Text -> Maybe (T.Text, [(T.Text, Value)])
parseLine text =
  let
    (name, rest) = T.breakOn (T.pack " ") text
  in
    if T.null name then Nothing else fmap (\fs -> (name, fs)) (fields rest)

fields :: T.Text -> Maybe [(T.Text, Value)]
fields text
  | T.null text = Just []
  | otherwise = do
      rest <- T.stripPrefix (T.pack " ") text
      let
        (key, afterKey) = T.breakOn (T.pack "=") rest
      valueText <- T.stripPrefix (T.pack "=") afterKey
      if T.null key || T.any (\c -> c == ' ' || c == '"') key
        then Nothing
        else do
          (value, remaining) <- valueOf valueText
          fmap ((key, value) :) (fields remaining)

valueOf :: T.Text -> Maybe (Value, T.Text)
valueOf text =
  case T.uncons text of
    Just ('"', rest) -> quotedValue [] rest
    _ ->
      let
        (token, remaining) = T.breakOn (T.pack " ") text
      in
        if T.null token || T.any (== '"') token then Nothing else Just (Bare token, remaining)

quotedValue :: [Char] -> T.Text -> Maybe (Value, T.Text)
quotedValue acc text =
  case T.uncons text of
    Nothing -> Nothing
    Just ('"', rest) -> Just (Quoted (T.pack (L.reverse acc)), rest)
    Just ('\\', rest) ->
      case T.uncons rest of
        Just (c, rest') | c == '\\' || c == '"' -> quotedValue (c : acc) rest'
        _ -> Nothing
    Just (c, rest) -> quotedValue (c : acc) rest

decodeWorkOrderEvent :: T.Text -> Maybe WorkOrderEvent
decodeWorkOrderEvent text = do
  (name, fs) <- parseLine text
  case (T.unpack name, fs) of
    ("create", []) -> Just WorkOrderCreated
    ("mark-eligible", []) -> step WoMarkEligible
    ("mark-ineligible", []) -> step WoMarkIneligible
    ("claim", _) -> step . WoClaim =<< claimOf fs
    ("release", _) -> step . WoRelease =<< claimOf fs
    ("start", _) -> step . WoStart =<< claimOf fs
    ("resume", _) -> step . WoResume =<< claimOf fs
    ("complete", _) -> step . (`WoComplete` []) =<< claimOf fs
    ("wait", [e, g, (k, Quoted reason)]) | k == T.pack "reason" -> do
      c <- claimOf [e, g]
      step (WoWait c reason)
    ("halt", [(k, Quoted reason)]) | k == T.pack "reason" -> step (WoHalt reason)
    ("requeue", []) -> step WoRequeue
    ("supersede", [(k, Bare u)]) | k == T.pack "by" -> step . WoSupersede . WorkOrderId =<< either (const Nothing) Just (parseUuid u)
    ("cancel", []) -> step WoCancel
    _ -> Nothing
 where
  step = Just . WorkOrderStep

claimOf :: [(T.Text, Value)] -> Maybe Claim
claimOf fs =
  case fs of
    [(e, Bare u), (g, Bare n)] | e == T.pack "engineer" && g == T.pack "generation" -> do
      engineer <- either (const Nothing) Just (parseUuid u)
      generation <- natural n
      Just (Claim (EngineerId engineer) generation)
    _ -> Nothing

natural :: T.Text -> Maybe Int
natural text =
  if not (T.null text) && T.length text <= 9 && T.all Char.isDigit text
    then Just (T.foldl' (\acc c -> acc * 10 + Char.digitToInt c) 0 text)
    else Nothing

decodeTicketEvent :: T.Text -> Maybe TicketEvent
decodeTicketEvent text = do
  (name, fs) <- parseLine text
  case (T.unpack name, fs) of
    ("create", [(k, Quoted title)]) | k == T.pack "title" -> Just (TicketCreated title)
    ("revise", [(k, Quoted title)]) | k == T.pack "title" -> Just (TicketRevised title)
    ("accept", []) -> step TicketAccept
    ("start-work", []) -> step TicketStartWork
    ("review-requested", []) -> step TicketReviewRequested
    ("changes-requested", []) -> step TicketChangesRequested
    ("signoff", [(k, Quoted by)]) | k == T.pack "by" -> step . TicketSignoff =<< mkHumanSignoff by
    ("cancel", [(k, Quoted by)]) | k == T.pack "by" -> step . TicketCancel =<< mkHumanSignoff by
    ("block", [(k, Quoted reason)]) | k == T.pack "reason" -> step (TicketBlock reason)
    ("unblock", []) -> step TicketUnblock
    _ -> Nothing
 where
  step = Just . TicketStep
