{-# LANGUAGE OverloadedStrings #-}

{- | The pure task rules (contract C-P3.6 K3, K4, K7): titles, acceptance,
priority, readiness, the most important ready task, dependency cycles, and the
plain words shown for each.
-}
module Lockstep.Kernel.TaskTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Task
  ( DependencyFact (..)
  , Priority (..)
  , TaskFacts (..)
  , TaskReadiness (..)
  , TaskRuleError (..)
  , createsCycle
  , mkAcceptance
  , mkTaskTitle
  , mostImportantReady
  , parsePriority
  , priorityCode
  , priorityOf
  , priorityValue
  , priorityWords
  , readinessWords
  , taskReadiness
  , taskRefusalCodes
  , taskRefusalWords
  , taskRuleCode
  , taskTitleText
  )

facts :: T.Text -> [(T.Text, T.Text)] -> TaskFacts
facts state deps =
  TaskFacts state Nothing (fmap (uncurry DependencyFact) deps)

jargon :: [T.Text]
jargon =
  ["ticket", "work order", "work-order", "engineer", "schedul", "eligib", "dispatch", "subject"]

noJargon :: String -> T.Text -> IO ()
noJargon label text =
  traverse_
    (\j -> assertBool (label <> " says " <> T.unpack j <> ": " <> T.unpack text) (not (j `T.isInfixOf` T.toLower text)))
    jargon

tests :: TestTree
tests =
  testGroup
    "Task rules (C-P3.6)"
    [ testCase "a title is 1 to 200 characters after trimming, without control characters" $ do
        fmap taskTitleText (mkTaskTitle "  Write the menu  ") @?= Right "Write the menu"
        fmap taskTitleText (mkTaskTitle (T.replicate 200 "t")) @?= Right (T.replicate 200 "t")
        mkTaskTitle "" @?= Left TitleEmpty
        mkTaskTitle "  " @?= Left TitleEmpty
        mkTaskTitle (T.replicate 201 "t") @?= Left TitleTooLong
        mkTaskTitle "one\ntwo" @?= Left TitleHasControl
    , testCase "what done looks like is at most 4000 characters; new lines and tabs are kept" $ do
        mkAcceptance "" @?= Right ""
        mkAcceptance "  The menu is printed.\r\nEveryone has a copy.\t  " @?= Right "The menu is printed.\nEveryone has a copy."
        mkAcceptance (T.replicate 4000 "a") @?= Right (T.replicate 4000 "a")
        mkAcceptance (T.replicate 4001 "a") @?= Left AcceptanceTooLong
        mkAcceptance "bell\a" @?= Left AcceptanceHasControl
    , testCase "rule errors have stable codes" $
        fmap taskRuleCode [TitleEmpty, TitleTooLong, TitleHasControl, AcceptanceTooLong, AcceptanceHasControl]
          @?= ["title-empty", "title-too-long", "title-control", "acceptance-too-long", "acceptance-control"]
    , testCase "priority is High 800, Normal 500, Low 200, and stored values read back by band" $ do
        fmap priorityValue [High, Normal, Low] @?= [800, 500, 200]
        fmap priorityCode [High, Normal, Low] @?= ["high", "normal", "low"]
        fmap priorityWords [High, Normal, Low] @?= ["High", "Normal", "Low"]
        fmap parsePriority ["high", "normal", "low", "urgent", "High", ""] @?= [Just High, Just Normal, Just Low, Nothing, Nothing, Nothing]
        fmap priorityOf [999, 700, 699, 400, 399, 0] @?= [High, High, Normal, Normal, Low, Low]
    , testCase "readiness follows the contract's order for every state" $ do
        taskReadiness (facts "canceled" [("A", "blocked")]) @?= TaskCanceled
        taskReadiness (facts "done" [("A", "proposed")]) @?= Finished
        taskReadiness (TaskFacts "blocked" (Just "waiting for the printer") [DependencyFact "A" "canceled"]) @?= BlockedBecause "waiting for the printer"
        taskReadiness (facts "ready" [("A", "done"), ("B", "canceled"), ("C", "ready")]) @?= CannotStart ["B"]
        taskReadiness (facts "proposed" [("A", "ready")]) @?= NotYetReady
        taskReadiness (facts "proposed" []) @?= NotYetReady
        taskReadiness (facts "ready" [("A", "done"), ("B", "ready"), ("C", "blocked")]) @?= WaitingFor ["B", "C"]
        taskReadiness (facts "ready" [("A", "done")]) @?= ReadyToWork
        taskReadiness (facts "ready" []) @?= ReadyToWork
        taskReadiness (facts "in-progress" []) @?= BeingWorkedOn
        taskReadiness (facts "awaiting-review" []) @?= BeingWorkedOn
    , testCase "a blocked task keeps its reason; an unknown reason still says blocked" $
        taskReadiness (TaskFacts "blocked" Nothing []) @?= BlockedBecause ""
    , testCase "the most important ready task is never a blocked or waiting one" $ do
        mostImportantReady [("a" :: T.Text, 800, 1, BlockedBecause "x"), ("b", 500, 2, ReadyToWork), ("c", 200, 3, ReadyToWork)] @?= Just "b"
        mostImportantReady [("a" :: T.Text, 800, 1, WaitingFor ["b"]), ("b", 200, 2, ReadyToWork)] @?= Just "b"
        mostImportantReady [("a" :: T.Text, 500, 2, ReadyToWork), ("b", 500, 1, ReadyToWork)] @?= Just "b"
        mostImportantReady [("a" :: T.Text, 500, 1, NotYetReady), ("b", 800, 2, Finished)] @?= Nothing
        mostImportantReady ([] :: [(T.Text, Int, Int, TaskReadiness)]) @?= Nothing
    , testCase "a dependency that would close a loop is a cycle; others are not" $ do
        let
          edges = [("b", "a"), ("c", "b")]
        createsCycle edges "a" ["c"] @?= True
        createsCycle edges "a" ["b"] @?= True
        createsCycle edges "c" ["a"] @?= False
        createsCycle edges "d" ["c", "a"] @?= False
        createsCycle edges "a" ["a"] @?= True
        createsCycle [("b", "a")] "b" [] @?= False
    , testCase "every refusal and every readiness has plain words without internal vocabulary" $ do
        let
          fallback = taskRefusalWords "no-such-code"
        traverse_
          (\c -> assertBool (T.unpack c <> " missing") (c `L.elem` taskRefusalCodes))
          [ "title-empty"
          , "title-too-long"
          , "title-control"
          , "acceptance-too-long"
          , "acceptance-control"
          , "unknown-priority"
          , "unknown-dependency"
          , "dependency-self"
          , "dependency-cycle"
          , "too-many-dependencies"
          , "stale-revision"
          , "unknown-task"
          , "unknown-project"
          , "not-allowed-now"
          , "reason-empty"
          ]
        traverse_
          ( \c -> do
              assertBool (T.unpack c <> " has no words of its own") (taskRefusalWords c /= fallback && not (T.null (taskRefusalWords c)))
              noJargon (T.unpack c) (taskRefusalWords c)
          )
          taskRefusalCodes
        traverse_
          ( \r -> do
              assertBool (show r <> " has no words") (not (T.null (readinessWords r)))
              noJargon (show r) (readinessWords r)
          )
          [NotYetReady, ReadyToWork, WaitingFor ["Buy paper"], BlockedBecause "no printer", CannotStart ["Buy paper"], Finished, TaskCanceled, BeingWorkedOn]
    , testCase "readiness words name what they depend on" $ do
        assertBool "waiting" ("Buy paper" `T.isInfixOf` readinessWords (WaitingFor ["Buy paper"]))
        assertBool "blocked" ("no printer" `T.isInfixOf` readinessWords (BlockedBecause "no printer"))
        assertBool "cannot start" ("Buy paper" `T.isInfixOf` readinessWords (CannotStart ["Buy paper"]))
        readinessWords ReadyToWork @?= "Ready to work on."
        readinessWords NotYetReady @?= "Not yet ready to work on."
    ]
