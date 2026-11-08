{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Kernel.TicketTest
  ( tests
  ) where

import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty ((:|)))
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.LifecycleFixtures
  ( Expect (..)
  , Fixtures (..)
  , exhaustive
  , row
  , rows
  , withFixtures
  )
import Lockstep.Kernel.Ticket
  ( TicketInput (..)
  , TicketState (..)
  , stepTicket
  , ticketStateName
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..), transitionRefusalCode)

tests :: TestTree
tests =
  testGroup
    "Kernel Ticket lifecycle (C-P2.2 §3.1)"
    [ testCase "exhaustive: every state × input × principal matches the table" $
        withFixtures $ \fx -> do
          let
            ws = fxAcceptedA fx :| []
            states =
              [ ("proposed", Proposed)
              , ("ready", Ready)
              , ("in-progress", InProgress)
              , ("code-complete", CodeComplete ws)
              , ("awaiting-review", AwaitingReview ws)
              , ("ready-for-signoff", ReadyForSignoff (fxIntegratedA fx))
              , ("done", Done (fxSignoff fx))
              , ("canceled", Canceled (fxSignoff fx))
              , ("blocked", Blocked "waiting for the owner" InProgress)
              ]
            inputs =
              [ ("accept", TicketAccept)
              , ("start-work", TicketStartWork)
              , ("work-accepted", TicketWorkAccepted ws)
              , ("review-requested", TicketReviewRequested)
              , ("changes-requested", TicketChangesRequested)
              , ("integrated", TicketIntegrated (fxIntegratedA fx))
              , ("integrated-other", TicketIntegrated (fxIntegratedB fx))
              , ("signoff", TicketSignoff (fxSignoff fx))
              , ("cancel", TicketCancel (fxSignoff fx))
              , ("block", TicketBlock "dependency")
              , ("unblock", TicketUnblock)
              ]
            nonTerminal = ["proposed", "ready", "in-progress", "code-complete", "awaiting-review", "ready-for-signoff", "blocked"]
            table =
              [ row "proposed" "accept" [Human] (To "ready")
              , row "ready" "start-work" [Supervisor] (To "in-progress")
              , row "in-progress" "work-accepted" [Supervisor] (To "code-complete")
              , row "code-complete" "review-requested" [DeliveryAdapter] (To "awaiting-review")
              , row "ready-for-signoff" "signoff" [Human] (To "done")
              , row "blocked" "unblock" [Human] (To "in-progress")
              ]
                <> rows ["code-complete", "awaiting-review"] "changes-requested" [DeliveryAdapter] (To "in-progress")
                <> rows ["code-complete", "awaiting-review"] "integrated" [Supervisor, DeliveryAdapter] (To "ready-for-signoff")
                <> rows ["code-complete", "awaiting-review"] "integrated-other" [Supervisor, DeliveryAdapter] (Refuse "basis-mismatch")
                <> rows nonTerminal "cancel" [Human] (To "canceled")
                <> rows (L.filter (/= "blocked") nonTerminal) "block" [Human, Supervisor] (To "blocked")
          exhaustive stepTicket ticketStateName states inputs ["done", "canceled"] table
    , testCase "Done is reachable only by a human signoff from ready-for-signoff" $
        withFixtures $ \fx -> do
          fmap ticketStateName (stepTicket (ReadyForSignoff (fxIntegratedA fx)) (Command Human (TicketSignoff (fxSignoff fx))))
            @?= Right "done"
          either transitionRefusalCode ticketStateName (stepTicket (ReadyForSignoff (fxIntegratedA fx)) (Command Supervisor (TicketSignoff (fxSignoff fx))))
            @?= "not-authorized"
          either transitionRefusalCode ticketStateName (stepTicket (AwaitingReview (fxAcceptedA fx :| [])) (Command Human (TicketSignoff (fxSignoff fx))))
            @?= "illegal-transition"
    , testCase "unblock returns to the exact prior state, with its evidence" $
        withFixtures $ \fx -> do
          let
            prior = AwaitingReview (fxAcceptedA fx :| [])
          stepTicket (Blocked "x" prior) (Command Human TicketUnblock) @?= Right prior
    , testCase "integration evidence must cover every accepted Work Unit of the Ticket" $
        withFixtures $ \fx -> do
          let
            both = fxAcceptedA fx :| [fxAcceptedB fx]
          either transitionRefusalCode ticketStateName (stepTicket (CodeComplete both) (Command Supervisor (TicketIntegrated (fxIntegratedA fx))))
            @?= "basis-mismatch"
    , testCase "refusal codes name the reason" $
        withFixtures $ \fx -> do
          either transitionRefusalCode ticketStateName (stepTicket Proposed (Command Agent TicketAccept)) @?= "agent-assertion"
          either transitionRefusalCode ticketStateName (stepTicket (Done (fxSignoff fx)) (Command Human TicketUnblock)) @?= "already-terminal"
    ]
