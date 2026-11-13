{- | P5.10: the operator's view of the Dev Capsule (contract C-P5.10 U1-U4).
The helper's status file is read exactly (the format @helper-capsule.sh@
writes), or not at all; the project page's section shows readiness, the step
under way with a stop control only then, the last step and the last failure.
-}
module Lockstep.CapsuleStatusTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Lockstep.Application.CapsuleStatus (CapsuleStatus (..), parseCapsuleStatus)
import Lockstep.Kernel.Identity (ProjectId (..), identityText, uuidFromWords)
import Lockstep.Web.ExecutionPages (capsuleSection)
import Lockstep.Web.Fragment (fragment)

tests :: TestTree
tests =
  testGroup
    "C-P5.10 the operator's view of the Dev Capsule"
    [ testCase "U1 the helper's status is read exactly" $
        parseCapsuleStatus (TE.encodeUtf8 running) @?= Just runningStatus
    , testCase "U1 the status names the project it belongs to (the page shows it, and accepts a stop, for that project only)" $
        fmap statusProject (parseCapsuleStatus (TE.encodeUtf8 running)) @?= Just (Just (identityText project))
    , testCase "U1 an idle status has no run under way" $
        fmap statusActiveRun (parseCapsuleStatus (TE.encodeUtf8 idle)) @?= Just Nothing
    , testCase "U2 a malformed status reads as unavailable, never partly" $
        fmap
          (parseCapsuleStatus . TE.encodeUtf8 . T.pack)
          [ "lockstep-capsule-status 2\n"
          , T.unpack (T.replace (T.pack "active-run 0123") (T.pack "active-run ../x") running)
          , T.unpack (T.replace (T.pack "vm Running\n") (T.pack "") running)
          , T.unpack (T.replace (T.pack "\n") (T.pack "\r\n") running)
          , T.unpack (T.dropEnd 1 running)
          ]
          @?= L.replicate 5 Nothing
    , testCase "U3 with a step under way the page offers to stop exactly that run" $ do
        let
          page = render runningStatus
        assertBool "ready" (T.isInfixOf (T.pack "): ready.") page)
        assertBool "stop control" (T.isInfixOf (T.pack "Stop the running step") page)
        assertBool "names the run" (T.isInfixOf (T.pack "0123456789abcdef0123456789abcdef") page)
        assertBool "the verification machine" (T.isInfixOf (T.pack "vmv1") page)
        assertBool "the last failure" (T.isInfixOf (T.pack "Last problem: run-verify: timed-out") page)
    , testCase "U3 with nothing under way there is no stop control" $ do
        let
          page = render idleStatus
        assertBool "no stop" (not (T.isInfixOf (T.pack "Stop the running step") page))
        assertBool "says so" (T.isInfixOf (T.pack "Nothing is running in it now.") page)
    , testCase "U4 a refused configuration or an old template is shown as not ready, with its reason" $ do
        let
          refused = render idleStatus {statusAudit = T.pack "host-loopback-not-disabled"}
          stale = render idleStatus {statusTemplate = T.pack "stale"}
        assertBool "refused" (T.isInfixOf (T.pack "not ready: its configuration is refused (host-loopback-not-disabled)") refused)
        assertBool "stale" (T.isInfixOf (T.pack "older template") stale)
    , testCase "U4 no verification machine is said plainly" $
        assertBool "no verify" (T.isInfixOf (T.pack "refuse to check work") (render idleStatus {statusVerify = Nothing}))
    ]
 where
  render status =
    TE.decodeUtf8 (LBS.toStrict (fragment (capsuleSection project status)))

project :: ProjectId
project =
  ProjectId (uuidFromWords 1 2)

running :: T.Text
running =
  T.unlines
    ( fmap
        T.pack
        [ "lockstep-capsule-status 1"
        , "capsule vmq1"
        , "project 00000000-0000-0001-0000-000000000002"
        , "verify vmv1"
        , "vm Running"
        , "audit ok"
        , "template current"
        , "active-run 0123456789abcdef0123456789abcdef"
        , "active-op run-live-write"
        , "last-run run-verify timed-out exit 124"
        , "last-failure run-verify: timed-out"
        , "updated 2026-11-10T19:00:00Z"
        ]
    )

idle :: T.Text
idle =
  T.replace (T.pack "active-op run-live-write") (T.pack "active-op -") $
    T.replace (T.pack "active-run 0123456789abcdef0123456789abcdef") (T.pack "active-run -") running

runningStatus :: CapsuleStatus
runningStatus =
  CapsuleStatus
    { statusCapsule = T.pack "vmq1"
    , statusProject = Just (identityText project)
    , statusVerify = Just (T.pack "vmv1")
    , statusVm = T.pack "Running"
    , statusAudit = T.pack "ok"
    , statusTemplate = T.pack "current"
    , statusActiveRun = Just (T.pack "0123456789abcdef0123456789abcdef")
    , statusActiveOp = Just (T.pack "run-live-write")
    , statusLastRun = Just (T.pack "run-verify timed-out exit 124")
    , statusLastFailure = Just (T.pack "run-verify: timed-out")
    , statusUpdated = T.pack "2026-11-10T19:00:00Z"
    }

idleStatus :: CapsuleStatus
idleStatus =
  runningStatus {statusActiveRun = Nothing, statusActiveOp = Nothing}
