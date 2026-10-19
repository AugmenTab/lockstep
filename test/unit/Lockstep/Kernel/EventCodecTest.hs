{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.5 §4 and §7: canonical event texts for durable Tickets and Work Orders.
module Lockstep.Kernel.EventCodecTest
  ( tests
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.EventCodec
  ( TicketEvent (..)
  , WorkOrderEvent (..)
  , decodeTicketEvent
  , decodeWorkOrderEvent
  , encodeTicketEvent
  , encodeWorkOrderEvent
  , parsePrincipal
  , principalName
  )
import Lockstep.Kernel.Evidence (mkHumanSignoff)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.LifecycleFixtures (Fixtures (..), claimA, withFixtures)
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Principal (..))
import Lockstep.Kernel.WorkOrder (Claim (..), WorkOrderInput (..))

tests :: TestTree
tests =
  testGroup
    "Event codec (C-P2.5 E10, §4)"
    [ testCase "fixtures (exercised on their own before the freeze)" $
        withFixtures $ \fx -> do
          claimGeneration claimA @?= 1
          assertBool "signoff" (isJust (mkHumanSignoff "owner"))
          _ <- pure (fxAcceptedA fx, fxIntegratedA fx)
          pure ()
    , testCase "every durable Work Order event round-trips" $
        traverse_
          ( \e -> case encodeWorkOrderEvent e of
              Left reason -> assertFailure ("not encoded: " <> show e <> ": " <> T.unpack reason)
              Right text -> do
                assertBool ("one line: " <> T.unpack text) (not (T.any (== '\n') text))
                decodeWorkOrderEvent text @?= Just e
          )
          ( WorkOrderCreated
              : fmap
                WorkOrderStep
                [ WoMarkEligible
                , WoMarkIneligible
                , WoClaim claim3
                , WoRelease claim3
                , WoStart claim3
                , WoWait claim3 tricky
                , WoResume claim3
                , WoComplete claim3 []
                , WoHalt tricky
                , WoRequeue
                , WoSupersede other
                , WoCancel
                ]
          )
    , testCase "golden Work Order texts" $ do
        encodeWorkOrderEvent WorkOrderCreated @?= Right "create"
        encodeWorkOrderEvent (WorkOrderStep WoMarkEligible) @?= Right "mark-eligible"
        encodeWorkOrderEvent (WorkOrderStep (WoClaim claim3))
          @?= Right "claim engineer=00000000-0000-0002-0000-000000000001 generation=3"
        encodeWorkOrderEvent (WorkOrderStep (WoWait claim3 "a \"b\" \\ c"))
          @?= Right "wait engineer=00000000-0000-0002-0000-000000000001 generation=3 reason=\"a \\\"b\\\" \\\\ c\""
        encodeWorkOrderEvent (WorkOrderStep (WoSupersede other))
          @?= Right "supersede by=00000000-0000-0000-0000-000000000009"
        encodeWorkOrderEvent (WorkOrderStep (WoComplete claim3 []))
          @?= Right "complete engineer=00000000-0000-0002-0000-000000000001 generation=3"
    , testCase "complete with Work Units is not durable" $
        withFixtures $ \fx ->
          case encodeWorkOrderEvent (WorkOrderStep (WoComplete claimA [fxAcceptedA fx])) of
            Left _ -> pure ()
            Right text -> assertFailure ("encoded: " <> T.unpack text)
    , testCase "every durable Ticket event round-trips" $
        case mkHumanSignoff "owner \"signoff\" 2026" of
          Nothing -> assertFailure "signoff"
          Just signoff ->
            traverse_
              ( \e -> case encodeTicketEvent e of
                  Left reason -> assertFailure ("not encoded: " <> show e <> ": " <> T.unpack reason)
                  Right text -> do
                    assertBool ("one line: " <> T.unpack text) (not (T.any (== '\n') text))
                    decodeTicketEvent text @?= Just e
              )
              [ TicketCreated tricky
              , TicketRevised "Second title"
              , TicketStep TicketAccept
              , TicketStep TicketStartWork
              , TicketStep TicketReviewRequested
              , TicketStep TicketChangesRequested
              , TicketStep (TicketSignoff signoff)
              , TicketStep (TicketCancel signoff)
              , TicketStep (TicketBlock tricky)
              , TicketStep TicketUnblock
              ]
    , testCase "golden Ticket texts" $ do
        encodeTicketEvent (TicketCreated "Fix \"login\"") @?= Right "create title=\"Fix \\\"login\\\"\""
        encodeTicketEvent (TicketRevised "t") @?= Right "revise title=\"t\""
        encodeTicketEvent (TicketStep TicketAccept) @?= Right "accept"
        encodeTicketEvent (TicketStep TicketStartWork) @?= Right "start-work"
        encodeTicketEvent (TicketStep (TicketBlock "r")) @?= Right "block reason=\"r\""
        case mkHumanSignoff "s" of
          Nothing -> assertFailure "signoff"
          Just signoff -> encodeTicketEvent (TicketStep (TicketCancel signoff)) @?= Right "cancel by=\"s\""
    , testCase "work-accepted and integrated are not durable" $
        withFixtures $ \fx -> do
          case encodeTicketEvent (TicketStep (TicketWorkAccepted (fxAcceptedA fx :| []))) of
            Left _ -> pure ()
            Right text -> assertFailure ("encoded: " <> T.unpack text)
          case encodeTicketEvent (TicketStep (TicketIntegrated (fxIntegratedA fx))) of
            Left _ -> pure ()
            Right text -> assertFailure ("encoded: " <> T.unpack text)
    , testCase "malformed texts decode to Nothing" $ do
        traverse_
          (\text -> decodeWorkOrderEvent text @?= Nothing)
          [ ""
          , "bogus"
          , "mark-eligible extra"
          , "claim engineer=xyz generation=1"
          , "claim generation=1"
          , "claim engineer=00000000-0000-0002-0000-000000000001 generation=-1"
          , "claim engineer=00000000-0000-0002-0000-000000000001 generation=x"
          , "claim engineer=00000000-0000-0002-0000-000000000001"
          , "halt reason=unquoted"
          , "halt reason=\"open"
          , "halt reason=\"a\" extra"
          , "supersede by=nope"
          , "CREATE"
          ]
        traverse_
          (\text -> decodeTicketEvent text @?= Nothing)
          ["", "create", "create title=", "create title=\"x", "accept now", "signoff by=s", "unblock x"]
    , testCase "principals round-trip; agent never parses" $ do
        traverse_ (\p -> parsePrincipal (principalName p) @?= Just p) [Human, Supervisor, Scheduler, DeliveryAdapter]
        fmap principalName [Human, Supervisor, Scheduler, DeliveryAdapter] @?= ["human", "supervisor", "scheduler", "delivery-adapter"]
        parsePrincipal "agent" @?= Nothing
        parsePrincipal "Human" @?= Nothing
    ]
 where
  claim3 = claimA {claimGeneration = 3}
  other = WorkOrderId (uuidFromWords 0 9)
  tricky = "needs \"input\" \\ now, ok"
