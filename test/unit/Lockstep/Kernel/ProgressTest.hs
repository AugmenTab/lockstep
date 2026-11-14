{-# LANGUAGE OverloadedStrings #-}

{- | Where each piece of a project's work stands (contract C-P6.2 C1–C3):
technical acceptance is not Done, priority never makes a waiting task next, and
a state Lockstep does not recognise is never shown as another.
-}
module Lockstep.Kernel.ProgressTest
  ( tests
  ) where

import Data.List qualified as L
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Lockstep.Kernel.Progress
  ( Publication (..)
  , Standing (..)
  , WorkFacts (..)
  , nextToHandOver
  , publicationCode
  , standingCode
  , standingOf
  )
import Lockstep.Kernel.Task (TaskReadiness (..))
import Lockstep.Kernel.Transaction (Stage (..), TxState (..))

facts :: TaskReadiness -> WorkFacts
facts readiness =
  WorkFacts {factReadiness = readiness, factHandedOver = False, factFix = Nothing, factAcceptedCommit = Nothing}

handed :: TaskReadiness -> Maybe TxState -> WorkFacts
handed readiness fix =
  (facts readiness) {factHandedOver = True, factFix = fix}

everyStanding :: [Standing]
everyStanding =
  [ StandingProposed
  , StandingReady
  , StandingWaiting ["Play a track"]
  , StandingBlocked "waiting for a design"
  , StandingCannotStart ["Old task"]
  , StandingQueued
  , StandingActive StageImplement
  , StandingWaitingForYou StageVerify "verify-failed"
  , StandingTechnicallyVerified (Just "0123456789abcdef0123456789abcdef01234567")
  , StandingHumanDone
  , StandingStopped "stopped-by-person"
  , StandingCanceled
  , StandingUnknown "teleported"
  ]

tests :: TestTree
tests =
  testGroup
    "where each piece of work stands (C-P6.2)"
    [ testCase "before it is handed over, a task stands where its readiness says (C1)" $ do
        standingOf (facts NotYetReady) @?= StandingProposed
        standingOf (facts ReadyToWork) @?= StandingReady
        standingOf (facts (WaitingFor ["A", "B"])) @?= StandingWaiting ["A", "B"]
        standingOf (facts (BlockedBecause "a design is missing")) @?= StandingBlocked "a design is missing"
        standingOf (facts (CannotStart ["Old"])) @?= StandingCannotStart ["Old"]
        standingOf (facts Finished) @?= StandingHumanDone
        standingOf (facts TaskCanceled) @?= StandingCanceled
        standingOf (facts (StateUnrecognised "teleported")) @?= StandingUnknown "teleported"
    , testCase "handed over and not started is queued, not active (C1)" $ do
        standingOf (handed ReadyToWork Nothing) @?= StandingQueued
        standingOf (handed BeingWorkedOn Nothing) @?= StandingQueued
    , testCase "once its fix exists, the fix's state decides (C1)" $ do
        standingOf (handed ReadyToWork (Just (Running StageImplement))) @?= StandingActive StageImplement
        standingOf (handed ReadyToWork (Just (Halted StageVerify "verify-failed"))) @?= StandingWaitingForYou StageVerify "verify-failed"
        standingOf (handed ReadyToWork (Just (Stopped "stopped-by-person"))) @?= StandingStopped "stopped-by-person"
        standingOf (handed ReadyToWork (Just Done)) @?= StandingHumanDone
    , testCase "an accepted fix is technically verified with its commit, never Done (C2)" $ do
        let
          accepted = (handed ReadyToWork (Just Accepted)) {factAcceptedCommit = Just "0123456789abcdef0123456789abcdef01234567"}
        standingOf accepted @?= StandingTechnicallyVerified (Just "0123456789abcdef0123456789abcdef01234567")
        standingOf accepted {factAcceptedCommit = Nothing} @?= StandingTechnicallyVerified Nothing
        assertBool "technically verified is human-done" (standingCode (standingOf accepted) /= standingCode StandingHumanDone)
    , testCase "a canceled task is canceled whatever its fix says (C1)" $
        standingOf (handed TaskCanceled (Just (Running StageImplement))) @?= StandingCanceled
    , testCase "every standing has its own stable code; only one says human-done (C1, C2, C5)" $ do
        fmap standingCode everyStanding
          @?= [ "proposed"
              , "ready"
              , "waiting"
              , "blocked"
              , "cannot-start"
              , "queued"
              , "active"
              , "waiting-for-you"
              , "technically-verified"
              , "human-done"
              , "stopped"
              , "canceled"
              , "unknown"
              ]
        L.length (L.filter ((== "human-done") . standingCode) everyStanding) @?= 1
    , testCase "nothing is published in Phase 6 (C2)" $
        publicationCode NotPublished @?= "not-published"
    , testCase "priority never makes a waiting, blocked or proposed task next (C3)" $ do
        let
          tasks =
            [ ("high but waiting", 800, StandingWaiting ["low ready"])
            , ("high but blocked", 800, StandingBlocked "no design")
            , ("high but proposed", 800, StandingProposed)
            , ("low ready", 200, StandingReady)
            , ("normal ready", 500, StandingReady)
            , ("high but queued", 800, StandingQueued)
            ]
        nextToHandOver tasks @?= Just ("normal ready" :: String)
        nextToHandOver (L.filter (\(_, _, s) -> s /= StandingReady) tasks) @?= Nothing
    , testCase "between equally important ready tasks the earlier is next (C3)" $
        nextToHandOver [("first" :: String, 500, StandingReady), ("second", 500, StandingReady)] @?= Just "first"
    ]
