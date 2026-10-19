{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.2 §6 properties: seeded (reproducible), 2000 cases each. Command
sequences are guided: about three steps in four pick a command that is legal
in the current state, so sequences reach deep states; the rest are arbitrary,
including Agent commands and wrong principals.
-}
module Lockstep.Kernel.LifecyclePropertyTest
  ( tests
  ) where

import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Flipstone.Prelude
import Test.QuickCheck (Gen, Property, choose, conjoin, counterexample, elements, forAll, property, sized, (===))
import Test.Tasty (TestTree, localOption, testGroup)
import Test.Tasty.QuickCheck (QuickCheckReplay (QuickCheckReplayLegacy), QuickCheckTests (QuickCheckTests), testProperty)
import Text.Show (Show, show)

import Lockstep.Kernel.Delivery (Delivery (..), DeliveryInput (..), DeliveryMode (..), DeliveryState (..), deliveryStateName, mkPullRequestRef, newDelivery, stepDelivery)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.LifecycleFixtures (Fixtures (..), admitted, allPrincipals, attempt, claimA, claimB, fixtures, passing, verificationWith)
import Lockstep.Kernel.Ticket (TicketInput (..), TicketState (..), stepTicket, ticketStateName)
import Lockstep.Kernel.Transition (Command (..), Principal (..), TraceStep (..), TransitionRefusal, replayTrace)
import Lockstep.Kernel.WorkOrder (Claim, WorkOrder (..), WorkOrderInput (..), WorkOrderKind (..), WorkOrderState, newWorkOrder, stepWorkOrder, workOrderStateName)
import Lockstep.Kernel.WorkOrder qualified as WO
import Lockstep.Kernel.WorkUnitLifecycle
  ( Attempt (..)
  , CheckOutcome (..)
  , ReviewVerdict (..)
  , Verification (..)
  , WorkUnit (..)
  , WorkUnitInput (..)
  , WorkUnitState (..)
  , frozenAttemptBudget
  , newWorkUnit
  , stepWorkUnit
  , workUnitStateName
  )

tests :: TestTree
tests =
  localOption (QuickCheckReplayLegacy 20261018) . localOption (QuickCheckTests 2000) $
    testGroup
      "Kernel lifecycle properties (C-P2.2 §6; seed 20261018, 2000 cases)"
      [ testProperty "Ticket: general invariants; Done only by a human signoff from ready-for-signoff" $
          withFx $ \fx ->
            forAll (guided stepTicket (pool (ticketInputs fx)) Proposed) $ \commands ->
              let
                (final, steps) = replayTrace stepTicket Proposed commands
              in
                conjoin
                  [ general stepTicket Proposed (`L.elem` ["done", "canceled"]) ticketStateName commands final steps
                  , conjoin
                      [ counterexample ("into done: " <> show step) (doneByHuman step)
                      | step@(StepAccepted _ _ to) <- steps
                      , ticketStateName to == "done"
                      ]
                  ]
      , testProperty "Work Order: general invariants; Completed only from Active; claims always match" $
          withFx $ \fx ->
            forAll (elements [Engineering, Investigate]) $ \kind ->
              let
                start = newWorkOrder (WorkOrderId (uuidFromWords 5 1)) kind
              in
                forAll (guided stepWorkOrder (pool (workOrderInputs fx)) start) $ \commands ->
                  let
                    (final, steps) = replayTrace stepWorkOrder start commands
                    name = workOrderStateName . workOrderState
                  in
                    conjoin
                      [ general stepWorkOrder start (`L.elem` ["completed", "superseded", "canceled"]) name commands final steps
                      , conjoin
                          [ counterexample ("completed from " <> show from) (name from === "active")
                          | StepAccepted from _ to <- steps
                          , name to == "completed"
                          ]
                      , conjoin
                          [ counterexample ("claim " <> show c <> " against " <> show (workOrderState from)) (currentClaim (workOrderState from) === Just c)
                          | StepAccepted from (Command _ input) _ <- steps
                          , not (isClaimInput input)
                          , Just c <- [inputClaim input]
                          ]
                      ]
      , testProperty "Work Unit: general invariants; Accepted only with no pending gates; attempts within budget; inconclusive never Verified" $
          withFx $ \fx ->
            let
              start = newWorkUnit (admitted 1)
            in
              forAll (guided stepWorkUnit (pool (workUnitInputs fx)) start) $ \commands ->
                let
                  (final, steps) = replayTrace stepWorkUnit start commands
                  name = workUnitStateName . workUnitState
                  states = start : fmap after steps
                in
                  conjoin
                    [ general stepWorkUnit start (`L.elem` ["accepted", "halted"]) name commands final steps
                    , conjoin
                        [ counterexample ("accepted from " <> show (workUnitState from)) (noPendingGates (workUnitState from))
                        | StepAccepted from _ to <- steps
                        , name to == "accepted"
                        ]
                    , conjoin
                        [ counterexample ("attempt beyond budget: " <> show (workUnitState s)) (withinBudget (workUnitState s))
                        | s <- states
                        ]
                    , conjoin
                        [ counterexample ("inconclusive verification reached " <> show (workUnitState to)) (workUnitState to === Halted "verification-inconclusive")
                        | StepAccepted _ (Command _ (WuVerificationObserved v)) to <- steps
                        , inconclusive v
                        ]
                    ]
      , testProperty "Delivery: general invariants; PullRequest integration only from Approved with the same commit" $
          withFx $ \fx ->
            forAll (elements [LocalOnly, PullRequest]) $ \mode ->
              let
                start = newDelivery mode (fxAcceptedA fx :| [])
                name = deliveryStateName . deliveryState
              in
                forAll (guided stepDelivery (pool (deliveryInputs fx)) start) $ \commands ->
                  let
                    (final, steps) = replayTrace stepDelivery start commands
                  in
                    conjoin
                      [ general stepDelivery start (`L.elem` ["integrated", "closed-without-merge"]) name commands final steps
                      , conjoin
                          [ counterexample ("integrated from " <> show (deliveryState from)) (approvedFor (deliveryState from) input)
                          | StepAccepted from (Command _ input) to <- steps
                          , deliveryMode from == PullRequest
                          , name to == "integrated"
                          ]
                      ]
      ]

-- * Guided generation

-- | Every input with every principal.
pool :: [i] -> [Command i]
pool inputs =
  [Command principal input | input <- inputs, principal <- allPrincipals]

guided :: (s -> Command i -> Either TransitionRefusal s) -> [Command i] -> s -> Gen [Command i]
guided step commands start =
  sized $ \size -> do
    n <- choose (0, max 1 (size `div` 2 + 10))
    go n start
 where
  go remaining s
    | remaining <= (0 :: Int) = pure []
    | otherwise = do
        let
          legal = L.filter (either (const False) (const True) . step s) commands
        roll <- choose (1, 4 :: Int)
        command <- if roll <= 3 && not (L.null legal) then elements legal else elements commands
        rest <- go (remaining - 1) (fromRight s (step s command))
        pure (command : rest)

-- * General invariants (every domain)

general ::
  (Eq s, Show s, Eq i, Show i) =>
  (s -> Command i -> Either TransitionRefusal s) ->
  s ->
  (T.Text -> Bool) ->
  (s -> T.Text) ->
  [Command i] ->
  s ->
  [TraceStep s i] ->
  Property
general step start terminal name commands final steps =
  conjoin
    [ counterexample "an Agent command was accepted" $
        property (L.null [() | StepAccepted _ (Command Agent _) _ <- steps])
    , counterexample "a terminal state changed" $
        property (L.null [() | StepAccepted from _ _ <- steps, terminal (name from)])
    , counterexample "the steps is not a chain (a refusal changed state, or a step was lost)" $
        fmap before steps === L.take (L.length steps) (start : fmap after steps)
    , counterexample "the final state is not the last state of the steps" $
        final === L.foldl' (\_ step' -> after step') start steps
    , counterexample "replay is not deterministic" $
        (final, steps) === replayTrace step start commands
    ]

before :: TraceStep s i -> s
before step =
  case step of
    StepAccepted from _ _ -> from
    StepRefused from _ _ -> from

after :: TraceStep s i -> s
after step =
  case step of
    StepAccepted _ _ to -> to
    StepRefused from _ _ -> from

withFx :: (Fixtures -> Property) -> Property
withFx check =
  maybe (counterexample "fixtures could not be built" (property False)) check fixtures

-- * Ticket

ticketInputs :: Fixtures -> [TicketInput]
ticketInputs fx =
  [ TicketAccept
  , TicketStartWork
  , TicketWorkAccepted (fxAcceptedA fx :| [])
  , TicketWorkAccepted (fxAcceptedA fx :| [fxAcceptedB fx])
  , TicketReviewRequested
  , TicketChangesRequested
  , TicketIntegrated (fxIntegratedA fx)
  , TicketIntegrated (fxIntegratedB fx)
  , TicketSignoff (fxSignoff fx)
  , TicketCancel (fxSignoff fx)
  , TicketBlock "blocked"
  , TicketUnblock
  ]

doneByHuman :: TraceStep TicketState TicketInput -> Bool
doneByHuman step =
  case step of
    StepAccepted (ReadyForSignoff _) (Command Human (TicketSignoff _)) (Done _) -> True
    _ -> False

-- * Work Order

workOrderInputs :: Fixtures -> [WorkOrderInput]
workOrderInputs fx =
  [ WoMarkEligible
  , WoMarkIneligible
  , WoClaim claimA
  , WoClaim claimB
  , WoRelease claimA
  , WoRelease claimB
  , WoStart claimA
  , WoStart claimB
  , WoWait claimA "w"
  , WoWait claimB "w"
  , WoResume claimA
  , WoResume claimB
  , WoComplete claimA [fxAcceptedA fx]
  , WoComplete claimA []
  , WoComplete claimB []
  , WoHalt "h"
  , WoRequeue
  , WoSupersede (WorkOrderId (uuidFromWords 5 9))
  , WoCancel
  ]

inputClaim :: WorkOrderInput -> Maybe Claim
inputClaim input =
  case input of
    WoClaim c -> Just c
    WoRelease c -> Just c
    WoStart c -> Just c
    WoWait c _ -> Just c
    WoResume c -> Just c
    WoComplete c _ -> Just c
    _ -> Nothing

-- | WoClaim takes a new claim; every other claim-bearing input must name the current one.
isClaimInput :: WorkOrderInput -> Bool
isClaimInput input =
  case input of
    WoClaim _ -> True
    _ -> False

currentClaim :: WorkOrderState -> Maybe Claim
currentClaim state =
  case state of
    WO.Claimed c -> Just c
    WO.Active c -> Just c
    WO.Waiting c _ -> Just c
    _ -> Nothing

-- * Work Unit

workUnitInputs :: Fixtures -> [WorkUnitInput]
workUnitInputs fx =
  let
    a = fxCommitA fx
    b = fxCommitB fx
  in
    [ WuFreeze (fxGated fx)
    , WuFreeze (fxPlain fx)
    , WuFreeze (fxTight fx)
    , WuStartAttempt (attempt 1)
    , WuStartAttempt (attempt 2)
    , WuStartAttempt (attempt 3)
    , WuImplementationObserved a
    , WuImplementationObserved b
    , WuVerificationObserved (passing a)
    , WuVerificationObserved (passing b)
    , WuVerificationObserved (verificationWith a [CheckPassed, CheckFailed])
    , WuVerificationObserved (verificationWith a [CheckPassed, CheckUnknown])
    , WuVerificationObserved (verificationWith a [CheckNotRun])
    , WuGatePassed "challenge"
    , WuGateFailed "challenge" "gap"
    , WuGatePassed "other"
    , WuReviewObserved ReviewApproved
    , WuReviewObserved (ReviewChangesRequested "naming")
    , WuHalt "h"
    ]

noPendingGates :: WorkUnitState -> Bool
noPendingGates state =
  case state of
    Verified _ _ _ [] -> True
    _ -> False

withinBudget :: WorkUnitState -> Bool
withinBudget state =
  case state of
    Implementing fc a -> attemptNumber a <= frozenAttemptBudget fc
    Verifying fc a _ -> attemptNumber a <= frozenAttemptBudget fc
    Verified fc a _ _ -> attemptNumber a <= frozenAttemptBudget fc
    Rework fc n _ -> n < frozenAttemptBudget fc
    _ -> True

inconclusive :: Verification -> Bool
inconclusive v =
  let
    outcomes = fmap snd (NE.toList (verifiedChecks v))
  in
    CheckFailed `L.notElem` outcomes && L.any (`L.elem` [CheckNotRun, CheckUnknown]) outcomes

-- * Delivery

deliveryInputs :: Fixtures -> [DeliveryInput]
deliveryInputs fx =
  let
    a = fxCommitA fx
    b = fxCommitB fx
    prs = maybe [] (\pr -> [DelPublish pr a, DelPublish pr b]) (mkPullRequestRef "owner/repo#1")
  in
    prs
      <> [ DelApprove a
         , DelApprove b
         , DelRequestChanges
         , DelPush a
         , DelPush b
         , DelIntegrate a
         , DelIntegrate b
         , DelClose
         , DelOutcomeUnknown "timeout"
         , DelReconciled
         ]

approvedFor :: DeliveryState -> DeliveryInput -> Bool
approvedFor state input =
  case (state, input) of
    (Approved _ _ approved, DelIntegrate integrated) -> approved == integrated
    _ -> False
