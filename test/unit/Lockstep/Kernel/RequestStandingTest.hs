{-# LANGUAGE OverloadedStrings #-}

{- | Update 2 R6.3: where a Human Request stands — the current actionable one,
superseded, resolved, invalidated, or answered with its effect not yet taken —
from its stored state, the Supervisor's withdrawal and its fix; and the
Decisions page, which keeps the closed ones visible as records with their
standing.
-}
module Lockstep.Kernel.RequestStandingTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Lockstep.Application.Inbox (RequestRecord (..))
import Lockstep.Kernel.Identity (TaskId (..), parseIdentity)
import Lockstep.Kernel.Inbox
  ( RequestFacts (..)
  , RequestStanding (..)
  , WithdrawalReason (..)
  , requestStanding
  , requestStandingCode
  , requestStandingWords
  , withdrawalText
  )
import Lockstep.Web.DecisionPages (decisionsOverview)

facts :: RequestFacts
facts =
  RequestFacts
    { requestFactState = "open"
    , requestFactWithdrawal = Nothing
    , requestFactFixInvalidated = False
    , requestFactCurrent = True
    , requestFactActedOn = False
    }

tests :: TestTree
tests =
  testGroup
    "R6.3 where a Human Request stands"
    [ testCase "an open request on its fix's current halt is the current, actionable one" $
        requestStanding facts @?= StandingCurrent
    , testCase "an older open request whose fix no longer counts is invalidated; the fix's own Stop-only request is the current one" $ do
        requestStanding facts {requestFactFixInvalidated = True, requestFactCurrent = False} @?= StandingInvalidated
        requestStanding facts {requestFactFixInvalidated = True} @?= StandingCurrent
    , testCase "an open request its fix has moved past is superseded" $
        requestStanding facts {requestFactCurrent = False} @?= StandingSuperseded
    , testCase "an answer the fix acted on is resolved; one it has not acted on yet is not called resolved" $ do
        requestStanding facts {requestFactState = "answered", requestFactActedOn = True} @?= StandingResolved
        requestStanding facts {requestFactState = "answered", requestFactCurrent = True} @?= StandingAwaitingEffect
    , testCase "a withdrawal says why: invalidated, superseded (also by a cancel), or only withdrawn" $ do
        let
          withdrawn reason = requestStanding facts {requestFactState = "withdrawn", requestFactCurrent = False, requestFactWithdrawal = Just (withdrawalText reason)}
        withdrawn (WithdrawnInvalidated "ancestor-rejected") @?= StandingInvalidated
        withdrawn (WithdrawnSuperseded "ancestor-rejected") @?= StandingSuperseded
        withdrawn WithdrawnCanceled @?= StandingSuperseded
        requestStanding facts {requestFactState = "withdrawn", requestFactCurrent = False, requestFactWithdrawal = Just "withdrawn by a person"} @?= StandingWithdrawn
    , testCase "each standing has its own code and words" $ do
        let
          all' = [minBound .. maxBound] :: [RequestStanding]
        L.length (L.nub (fmap requestStandingCode all')) @?= L.length all'
        assertBool "a standing without words" (not (L.any (T.null . requestStandingWords) all'))
    , testCase "the withdrawal text names the cause and keeps the request as a record" $ do
        assertBool "no cause" ("ancestor-rejected" `T.isInfixOf` withdrawalText (WithdrawnInvalidated "ancestor-rejected"))
        assertBool "not kept" (L.all (("record" `T.isInfixOf`) . withdrawalText) [WithdrawnInvalidated "plan-changed", WithdrawnSuperseded "x", WithdrawnCanceled])
    , testCase "the Decisions page lists closed requests with their standing" $ do
        task <- maybe (assertFailure "no task id") pure (parseIdentity "00000000-0000-4000-8000-000000000001" :: Maybe TaskId)
        let
          record standing =
            RequestRecord
              { recordRequest = "00000000-0000-4000-8000-000000000002"
              , recordTask = task
              , recordTaskTitle = "Make f2 return 2"
              , recordProjectName = "values"
              , recordQuestion = "What should happen next?"
              , recordStanding = standing
              , recordNote = Just (withdrawalText (WithdrawnInvalidated "ancestor-rejected"))
              }
          page = TE.decodeUtf8 (LBS.toStrict (decisionsOverview (Just []) (Just []) (Just [record StandingInvalidated, record StandingResolved])))
        assertBool "no closed section" ("Earlier requests" `T.isInfixOf` page)
        assertBool "no invalidated standing" (requestStandingWords StandingInvalidated `T.isInfixOf` page)
        assertBool "no resolved standing" (requestStandingWords StandingResolved `T.isInfixOf` page)
        assertBool "a closed request offered as a form" (not ("<form" `T.isInfixOf` page))
    ]
