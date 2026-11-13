{-# LANGUAGE OverloadedStrings #-}

{- | Stabilization S3 (post-Phase-5 handoff §4): the Planner is told to follow
the project's own test conventions and to test the behavior; the Reviewer is
told to read the whole change and say what it read; an approval that did not
read the whole change is never taken for a comprehensive review.
-}
module Lockstep.Effects.ReviewScopeTest
  ( tests
  ) where

import Data.Maybe (isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Lockstep.Effects.Provider.Claude (capsuleRoleInstructions, roleInstructions)
import Lockstep.Effects.Roles (View (..), decodeAnswer, reviewInspected)
import Lockstep.Kernel.Roles (Review (..), Role (..), RoleAnswer (..), Verdict (..), changedPaths, reviewScopeGap)

tests :: TestTree
tests =
  testGroup
    "S3 test conventions, test breadth and the whole change reviewed"
    [ testCase "the Planner is directed to the project's own test suite, conventions and behavior (container and capsule)" $
        traverse_
          ( \told -> do
              let
                planner = told Planner
              traverse_
                (\needle -> assertBool (T.unpack needle) (needle `T.isInfixOf` planner))
                [ "learn how this project tests itself"
                , "test framework"
                , "registered and run"
                , "Never a"
                , "standalone script or a runner of your own"
                , "give its full current text"
                , "several representative inputs, the boundaries"
                , "property-based test"
                , "special-cased your example"
                , "no padding"
                , "\"command\": null"
                ]
          )
          [(`roleInstructions` view), (`capsuleRoleInstructions` view)]
    , testCase "the Reviewer is told to read every changed file, tests included, and to list what it read" $
        traverse_
          ( \told -> do
              let
                reviewer = told Reviewer
              traverse_
                (\needle -> assertBool (T.unpack needle) (needle `T.isInfixOf` reviewer))
                [ "change.files lists every file the change touches"
                , "the tests"
                , "\"inspected\""
                , "Never list a file you did not read."
                , "does not accept an approval that did not read the"
                ]
          )
          [(`roleInstructions` view), (`capsuleRoleInstructions` view)]
    , testCase "a review answer may say what it read; the Kernel's review is unchanged" $ do
        let
          answer = "{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"ok\"],\"inspected\":[\"calc.py\",\"test_calc.py\"]}"
        decodeAnswer answer @?= Right (AnswerReview (Review Approve ["ok"]))
        reviewInspected answer @?= Right (Just ["calc.py", "test_calc.py"])
        reviewInspected "{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"ok\"]}" @?= Right Nothing
        assertBool "a bad path is malformed" (either (const True) (const False) (decodeAnswer "{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"ok\"],\"inspected\":[\"../x\"]}"))
    , testCase "the change is every added, changed and removed file" $
        changedPaths [("a", "1"), ("b", "2"), ("c", "3")] [("a", "1"), ("b", "9"), ("d", "4")] @?= ["b", "c", "d"]
    , testCase "an approval stands only with a declared scope covering the whole change" $ do
        let
          changed = ["calc.py", "test/Spec.hs"]
          tree = ["calc.py", "test/Spec.hs", "README"]
        reviewScopeGap True changed tree (Just ["calc.py", "test/Spec.hs", "README"]) @?= Nothing
        assertBool "a changed test unread" (isJust (reviewScopeGap True changed tree (Just ["calc.py"])))
        assertBool "the gap names the file" (maybe False ("test/Spec.hs" `T.isInfixOf`) (reviewScopeGap True changed tree (Just ["calc.py"])))
        assertBool "nothing declared, by a provider-backed Reviewer" (isJust (reviewScopeGap True changed tree Nothing))
        reviewScopeGap False changed tree Nothing @?= Nothing
        assertBool "a file that is not there" (isJust (reviewScopeGap True changed tree (Just ["calc.py", "test/Spec.hs", "ghost.hs"])))
        reviewScopeGap True [] tree (Just []) @?= Nothing
    , testCase "an empty scope list reads back as declared and empty" $
        reviewInspected "{\"kind\":\"review\",\"verdict\":\"reject\",\"reasons\":[\"x\"],\"inspected\":[]}" @?= Right (Just [])
    ]

view :: View
view =
  View "/work/tree" "/input" "/output"
