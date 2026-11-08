{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.8 §7 unit cases: the canonical rendering (§4) and the ledger page (V3).
module Lockstep.Web.LedgerPageTest
  ( tests
  ) where

import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Control.Monad (foldM)
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Ledger (StoredObservation (..), StoredRecovery (..), StoredResolution (..))
import Lockstep.Application.LedgerView
  ( EffectLine (..)
  , LedgerProjection (..)
  , OrderLine (..)
  , RefusalLine (..)
  , TicketLine (..)
  , renderProjection
  )
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , Intent (..)
  , IntentInput (..)
  , IntentRequest (..)
  , Observation (..)
  , OperationId (..)
  , SubjectRef (..)
  , mkEffectKey
  , mkEffectSpec
  , newIntents
  , stepIntent
  )
import Lockstep.Kernel.EffectView (EffectStatus (..))
import Lockstep.Kernel.Identity (EngineerId (..), TicketId (..), WorkOrderId (..), uuidFromWords, uuidText)
import Lockstep.Kernel.Reconciliation (Resolution (..), resolveIntent)
import Lockstep.Kernel.Recovery (RecoveryInput (..), recoverIntent, recoveryIntent)
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (Claim (..), WorkOrderState (..))
import Lockstep.Web.LedgerPage (ledgerFailurePage, ledgerPage)

tests :: TestTree
tests =
  testGroup
    "Ledger projection rendering and page (C-P2.8)"
    [ testCase "the fixture builds through the real Kernel" $ do
        p <- fixture
        fmap (L.length . orderLineEffects) (projectionOrders p) @?= [4]
    , testCase "renderProjection is the §4 canonical text" $ do
        p <- fixture
        renderProjection p @?= expected
    , testCase "the page shows every status as text with its class, marks refusals, and has no form" $ do
        html <- pageText <$> fixture
        traverse_
          (\needle -> assertBool ("missing: " <> T.unpack needle) (needle `T.isInfixOf` html))
          [ "class=\"ls-effect-passed\">PASSED<"
          , "class=\"ls-effect-attested\">ATTESTED<"
          , "class=\"ls-effect-unknown\">UNKNOWN<"
          , "class=\"ls-effect-not-run\">NOT_RUN<"
          , "REFUSED (stale-claim)"
          , "human-attested"
          , "stale-revision"
          , T.replicate 64 "d"
          ]
        T.count "PASSED" html @?= 1
        assertBool "a form on a read-only page" (not ("<form" `T.isInfixOf` html))
    , testCase "the failure page says so and shows nothing partial" $ do
        let
          html = TE.decodeUtf8 (LBS.toStrict (renderLazyHTML ledgerFailurePage))
        assertBool "no notice" ("could not be shown" `T.isInfixOf` html)
        assertBool "a status on the failure page" (not ("ls-effect-" `T.isInfixOf` html))
    ]

pageText :: LedgerProjection -> T.Text
pageText =
  TE.decodeUtf8 . LBS.toStrict . renderLazyHTML . ledgerPage

-- Fixture --------------------------------------------------------------------

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 19) (secondsToDiffTime 0)

at :: Integer -> UTCTime
at n =
  addUTCTime (fromInteger n) t0

ticketId :: TicketId
ticketId =
  TicketId (uuidFromWords 1 1)

orderId :: WorkOrderId
orderId =
  WorkOrderId (uuidFromWords 2 1)

op :: Word64 -> OperationId
op n =
  OperationId (uuidFromWords 4 n)

intentOf :: Word64 -> T.Text -> ClassTerms -> Int -> [Command IntentInput] -> IO Intent
intentOf n key terms budget commands = do
  spec <- either (assertFailure . show) pure (mkEffectSpec "step" terms budget)
  k <- either (assertFailure . show) pure (mkEffectKey key)
  intents <- either (assertFailure . show) pure (newIntents sha256Hasher (SubjectWorkOrder orderId) 4 [(op n, IntentRequest k spec "p=1")])
  i <- case intents of
    [i] -> pure i
    _ -> assertFailure "one intent"
  either (assertFailure . show) pure (foldM stepIntent i commands)

sup :: IntentInput -> Command IntentInput
sup =
  Command Supervisor

fixture :: IO LedgerProjection
fixture = do
  verified <- intentOf 1 "e1" TermsRepeatable 1 [sup (IntentClaim "w1" t0 (at 60)), sup (IntentDispatch 1 (at 1)), sup (IntentObserve 1 (DestinationApplied "ok")), sup (IntentSettle 1)]
  unknownD <- intentOf 2 "e2" TermsUnqueryable 0 [sup (IntentClaim "w1" t0 (at 60)), sup (IntentDispatch 1 (at 1)), sup (IntentObserve 1 (NoAnswer "timeout"))]
  attested <- either (assertFailure . show) pure (resolveIntent unknownD (Command Human (1, AttestApplied "seen")))
  dispatched <- intentOf 3 "e3" TermsUnqueryable 0 [sup (IntentClaim "w1" t0 (at 60)), sup (IntentDispatch 1 (at 1))]
  recovered <- either (assertFailure . show) (pure . recoveryIntent) (recoverIntent dispatched (Command Supervisor (RecoveryInput "w2" (at 60) (at 120) True)))
  pending <- intentOf 4 "e4" TermsRepeatable 1 []
  pure
    LedgerProjection
      { projectionTime = at 100
      , projectionTickets = [TicketLine ticketId "Fix \"login\"" "ready" 2]
      , projectionOrders =
          [ OrderLine
              { orderLineId = orderId
              , orderLineTicket = ticketId
              , orderLineState = Active (Claim (EngineerId (uuidFromWords 3 1)) 1)
              , orderLineRevision = 4
              , orderLineBinding = T.replicate 64 "b"
              , orderLineEffects =
                  [ EffectLine verified StatusPassed "applied: ok" [StoredObservation 1 "applied result=\"ok\"" True Nothing] [] []
                  , EffectLine
                      attested
                      StatusAttested
                      "attested by a human, not observed: human-attested: seen"
                      [StoredObservation 1 "no-answer reason=\"timeout\"" True Nothing]
                      []
                      [StoredResolution 1 "human-attested" "attested-applied evidence=\"seen\"" False]
                  , EffectLine
                      recovered
                      StatusUnknown
                      "outcome unknown, a human must resolve it: dispatch-interrupted: unqueryable effect"
                      [StoredObservation 1 "applied result=\"late\"" False (Just "stale-claim")]
                      [StoredRecovery 1 "unknown reason=\"dispatch-interrupted: unqueryable effect\""]
                      []
                  , EffectLine pending StatusNotRun "not dispatched" [] [] []
                  ]
              }
          ]
      , projectionRefusals = [RefusalLine (uuidText (uuidFromWords 1 1)) 1 "human" "accept" "stale-revision"]
      , projectionSchedule = Just ("schedule rendering", T.replicate 64 "d")
      }

expected :: T.Text
expected =
  T.unlines
    [ "ticket " <> t <> " state=ready revision=2 title=\"Fix \\\"login\\\"\""
    , "work-order " <> o <> " ticket=" <> t <> " state=active revision=4 binding=" <> T.replicate 64 "b"
    , "  effect " <> opText 1 <> " key=e1 spec=step class=repeatable state=settled generation=1 dispatches=1 budget=1 status=PASSED reason=\"applied: ok\""
    , "    observation generation=1 accepted=true refusal=none applied result=\"ok\""
    , "  effect " <> opText 2 <> " key=e2 spec=step class=unqueryable state=settled generation=1 dispatches=1 budget=0 status=ATTESTED reason=\"attested by a human, not observed: human-attested: seen\""
    , "    observation generation=1 accepted=true refusal=none no-answer reason=\"timeout\""
    , "    resolution generation=1 basis=human-attested acknowledged=false attested-applied evidence=\"seen\""
    , "  effect " <> opText 3 <> " key=e3 spec=step class=unqueryable state=outcome-unknown generation=1 dispatches=1 budget=0 status=UNKNOWN reason=\"outcome unknown, a human must resolve it: dispatch-interrupted: unqueryable effect\""
    , "    observation generation=1 accepted=false refusal=stale-claim applied result=\"late\""
    , "    recovery generation=1 unknown reason=\"dispatch-interrupted: unqueryable effect\""
    , "  effect " <> opText 4 <> " key=e4 spec=step class=repeatable state=pending generation=0 dispatches=0 budget=1 status=NOT_RUN reason=\"not dispatched\""
    , "refusal subject=" <> t <> " expected=1 principal=human code=stale-revision command=\"accept\""
    , "schedule digest=" <> T.replicate 64 "d"
    ]
 where
  t = uuidText (uuidFromWords 1 1)
  o = uuidText (uuidFromWords 2 1)

opText :: Word64 -> T.Text
opText n =
  uuidText (uuidFromWords 4 n)
