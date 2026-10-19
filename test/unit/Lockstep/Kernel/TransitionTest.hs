{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Kernel.TransitionTest
  ( tests
  ) where

import Data.Bifunctor (second)
import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Delivery (Delivery (..), DeliveryInput (..), DeliveryMode (..), integrationEvidence, newDelivery, stepDelivery)
import Lockstep.Kernel.Evidence (commitIdText, mkCommitId, mkHumanSignoff)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.LifecycleFixtures (Fixtures (..), admitted, attempt, claimA, passing, withFixtures)
import Lockstep.Kernel.Ticket (TicketInput (..), TicketState (..), stepTicket, ticketStateName)
import Lockstep.Kernel.Transition
  ( Command (..)
  , Principal (..)
  , TraceStep (..)
  , TransitionRefusal (..)
  , replay
  , replayTrace
  , transitionRefusalCode
  )
import Lockstep.Kernel.WorkOrder (WorkOrder (..), WorkOrderInput (..), WorkOrderKind (..), newWorkOrder, stepWorkOrder, workOrderStateName)
import Lockstep.Kernel.WorkUnitLifecycle (ReviewVerdict (..), WorkUnitInput (..), acceptedWorkUnit, newWorkUnit, stepWorkUnit)

tests :: TestTree
tests =
  testGroup
    "Kernel transitions, replay and evidence (C-P2.2 T2, T3, T8)"
    [ testCase "refusal codes" $
        fmap
          transitionRefusalCode
          [ AgentAssertion
          , AlreadyTerminal "done"
          , NotAuthorized Human "signoff"
          , IllegalTransition "ready" "signoff"
          , ClaimMismatch
          , BasisMismatch "x"
          , KindForbids "x"
          , AttemptBudgetExhausted
          , GatesPending
          ]
          @?= [ "agent-assertion"
              , "already-terminal"
              , "not-authorized"
              , "illegal-transition"
              , "claim-mismatch"
              , "basis-mismatch"
              , "kind-forbids"
              , "attempt-budget-exhausted"
              , "gates-pending"
              ]
    , testCase "replay stops at the first refusal and reports its index" $ do
        let
          commands = [Command Human TicketAccept, Command Human TicketStartWork, Command Supervisor TicketStartWork]
        fmap ticketStateName (replay stepTicket Proposed (L.take 1 commands)) @?= Right "ready"
        either (second transitionRefusalCode) (const (-1, "")) (replay stepTicket Proposed commands)
          @?= (1, "not-authorized")
    , testCase "replayTrace continues from the unchanged state after a refusal" $ do
        let
          commands = [Command Human TicketAccept, Command Human TicketStartWork, Command Supervisor TicketStartWork]
          (final, steps) = replayTrace stepTicket Proposed commands
        ticketStateName final @?= "in-progress"
        fmap kind steps @?= ["accepted ready", "refused not-authorized", "accepted in-progress"]
    , testCase "replaying the same commands twice gives equal results" $ do
        let
          commands = [Command Human TicketAccept, Command Agent TicketStartWork, Command Supervisor TicketStartWork, Command Human (TicketBlock "x")]
        replayTrace stepTicket Proposed commands @?= replayTrace stepTicket Proposed commands
        fmap ticketStateName (replay stepTicket Proposed commands) @?= fmap ticketStateName (replay stepTicket Proposed commands)
    , testCase "commit ids: 40 lowercase hex only" $ do
        fmap commitIdText (mkCommitId (T.replicate 40 "0")) @?= Just (T.replicate 40 "0")
        fmap commitIdText (mkCommitId (T.replicate 39 "0")) @?= Nothing
        fmap commitIdText (mkCommitId (T.replicate 41 "0")) @?= Nothing
        fmap commitIdText (mkCommitId (T.replicate 40 "A")) @?= Nothing
        fmap commitIdText (mkCommitId (T.replicate 40 "g")) @?= Nothing
    , testCase "human signoffs: non-empty, no control characters" $ do
        fmap (const ()) (mkHumanSignoff "") @?= Nothing
        fmap (const ()) (mkHumanSignoff "a\nb") @?= Nothing
        fmap (const ()) (mkHumanSignoff "owner") @?= Just ()
    , testCase "end to end: Ticket → Work Order → Work Unit → Delivery → Ready for Signoff → human Done" $
        withFixtures endToEnd
    , testCase "an Agent can never advance any domain, even with valid evidence" $
        withFixtures $ \fx -> do
          let
            order = newWorkOrder (WorkOrderId (uuidFromWords 5 1)) Engineering
          either transitionRefusalCode ticketStateName (stepTicket (ReadyForSignoff (fxIntegratedA fx)) (Command Agent (TicketSignoff (fxSignoff fx))))
            @?= "agent-assertion"
          either transitionRefusalCode (workOrderStateName . workOrderState) (stepWorkOrder order (Command Agent WoMarkEligible))
            @?= "agent-assertion"
          fmap (const ()) (stepWorkUnit (newWorkUnit (admitted 1)) (Command Agent (WuFreeze (fxPlain fx)))) @?= Left AgentAssertion
          fmap (const ()) (stepDelivery (newDelivery LocalOnly (fxAcceptedA fx :| [])) (Command Agent (DelIntegrate (fxCommitA fx)))) @?= Left AgentAssertion
    ]
 where
  kind step =
    case step of
      StepAccepted _ _ to -> "accepted " <> T.unpack (ticketStateName to)
      StepRefused _ _ refusal -> "refused " <> T.unpack (transitionRefusalCode refusal)

endToEnd :: Fixtures -> Assertion
endToEnd fx = do
  let
    a = fxCommitA fx
  ticket1 <- ok "ticket" (replay stepTicket Proposed [Command Human TicketAccept, Command Supervisor TicketStartWork])
  order <-
    ok
      "work order"
      ( replay
          stepWorkOrder
          (newWorkOrder (WorkOrderId (uuidFromWords 5 1)) Engineering)
          [Command Scheduler WoMarkEligible, Command Scheduler (WoClaim claimA), Command Supervisor (WoStart claimA)]
      )
  unit <-
    ok
      "work unit"
      ( replay
          stepWorkUnit
          (newWorkUnit (admitted 1))
          ( fmap
              (Command Supervisor)
              [ WuFreeze (fxGated fx)
              , WuStartAttempt (attempt 1)
              , WuImplementationObserved a
              , WuVerificationObserved (passing a)
              , WuGatePassed "challenge"
              , WuReviewObserved ReviewApproved
              ]
          )
      )
  accepted <- maybe (assertFailure "the accepted Work Unit gave no evidence") pure (acceptedWorkUnit unit)
  completed <- ok "complete" (stepWorkOrder order (Command Supervisor (WoComplete claimA [accepted])) `orIndex` 0)
  workOrderStateName (workOrderState completed) @?= "completed"
  -- Work Order completion is not Ticket completion: the Ticket is still in progress.
  ticketStateName ticket1 @?= "in-progress"
  ticket2 <- ok "code complete" (stepTicket ticket1 (Command Supervisor (TicketWorkAccepted (accepted :| []))) `orIndex` 0)
  delivered <- ok "delivery" (replay stepDelivery (newDelivery LocalOnly (accepted :| [])) [Command Supervisor (DelIntegrate a)])
  evidence <- maybe (assertFailure "the integrated delivery gave no evidence") pure (integrationEvidence delivered)
  ticket3 <- ok "integrated" (stepTicket ticket2 (Command Supervisor (TicketIntegrated evidence)) `orIndex` 0)
  -- Integration is not Done: it moves the Ticket only to Ready for Signoff.
  ticketStateName ticket3 @?= "ready-for-signoff"
  deliveryMode delivered @?= LocalOnly
  done <- ok "signoff" (stepTicket ticket3 (Command Human (TicketSignoff (fxSignoff fx))) `orIndex` 0)
  ticketStateName done @?= "done"

orIndex :: Either e a -> Int -> Either (Int, e) a
orIndex result index =
  either (\e -> Left (index, e)) Right result

ok :: String -> Either (Int, TransitionRefusal) a -> IO a
ok label result =
  case result of
    Right value -> pure value
    Left (index, refusal) -> assertFailure (label <> ": command " <> show index <> " refused: " <> show refusal)
