{-# LANGUAGE OverloadedStrings #-}

{- | Review remediation of C-P6.2 (R-P6.2-1, R-P6.2-3): a task waiting on one
whose fix is Done or committed says why it still waits; a fix's halt and stop
codes reach the person in words, as on the task page, never as codes.
-}
module Lockstep.Web.ProgressReviewTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Progress (ProgressRow (..), ProgressView (..), WhereItRuns (..))
import Lockstep.Kernel.Identity (ProjectId (..), TaskId (..), parseUuid)
import Lockstep.Kernel.Progress (Publication (..), Standing (..), explainWaiting)
import Lockstep.Kernel.Transaction (Stage (..))
import Lockstep.Web.ProgressPage (progressPage)

pageOf :: [(T.Text, Standing)] -> IO T.Text
pageOf standings = do
  project <- either (const (assertFailure "uuid")) (pure . ProjectId) (parseUuid "3f2504e0-4f89-41d3-9a0c-0305e82c3301")
  task <- either (const (assertFailure "uuid")) (pure . TaskId) (parseUuid "00000000-0000-4000-8000-000000000001")
  let
    view =
      ProgressView
        { progressProject = project
        , progressName = "Caesura"
        , progressRows = [ProgressRow task title 500 Nothing standing NotPublished | (title, standing) <- standings]
        , progressNext = Nothing
        , progressWhere = RunsNowhere "Lockstep may not work in this project yet."
        }
  either (const (assertFailure "not UTF-8")) pure (TE.decodeUtf8' (LBS.toStrict (progressPage view)))

tests :: TestTree
tests =
  testGroup
    "Progress page review remediation (C-P6.2 R-P6.2-1, R-P6.2-3)"
    [ testCase "a task waiting on one whose fix is Done or committed says why it still waits (R-P6.2-1)" $ do
        let
          others = [("Base", StandingHumanDone), ("Side", StandingTechnicallyVerified Nothing), ("Other", StandingActive StageImplement)]
        explainWaiting others (StandingWaiting ["Base", "Side", "Other"])
          @?= StandingWaiting
            [ "Base (its fix is Done, but Lockstep does not yet close the task itself, so this one still waits)"
            , "Side (checked and committed, not Done yet)"
            , "Other"
            ]
    , testCase "only a waiting standing is explained; others are unchanged (R-P6.2-1)" $ do
        let
          others = [("Base", StandingHumanDone)]
        explainWaiting others StandingReady @?= StandingReady
        explainWaiting others (StandingBlocked "Base") @?= StandingBlocked "Base"
        explainWaiting [] (StandingWaiting ["Base"]) @?= StandingWaiting ["Base"]
    , testCase "a halt and a stop are worded as on the task page, never shown as codes (R-P6.2-3)" $ do
        page <-
          pageOf
            [ ("Halted task", StandingWaitingForYou StageVerify "role-failed provider-auth-rejected")
            , ("Stopped task", StandingStopped "role-failed no-coding-agent")
            ]
        assertBool ("a halt code reached the page: " <> show page) (not ("role-failed" `T.isInfixOf` page))
        assertBool "the halt is not worded" ("Anthropic did not accept your Claude subscription sign-in" `T.isInfixOf` page)
        assertBool "the stop is not worded" ("No coding helper is set up for Lockstep." `T.isInfixOf` page)
    ]
