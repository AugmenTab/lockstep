{-# LANGUAGE OverloadedStrings #-}

{- | The project's Progress page as rendered (contract C-P6.2 C2, C4, C5, C7):
one task in every standing; technical acceptance is never Done, nothing is
published, every row links to its exact record, and no internal word reaches
the person.
-}
module Lockstep.Web.ProgressPageTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Progress (Placement (..), ProgressRow (..), ProgressView (..), WhereItRuns (..))
import Lockstep.Kernel.Identity (ProjectId (..), TaskId (..), parseUuid)
import Lockstep.Kernel.Progress (Publication (..), Standing (..), standingCode)
import Lockstep.Kernel.Transaction (Stage (..))
import Lockstep.Web.ProgressPage (progressPage)

projectUuid :: T.Text
projectUuid =
  "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

-- | The n-th task's identity, as text.
taskUuid :: Int -> T.Text
taskUuid n =
  "00000000-0000-4000-8000-" <> T.justifyRight 12 '0' (T.pack (show n))

commit :: T.Text
commit =
  "0123456789abcdef0123456789abcdef01234567"

standings :: [(T.Text, Standing)]
standings =
  [ ("Proposed task", StandingProposed)
  , ("Ready task", StandingReady)
  , ("Waiting task", StandingWaiting ["Ready task"])
  , ("Blocked task", StandingBlocked "a design is missing")
  , ("Orphaned task", StandingCannotStart ["Canceled task"])
  , ("Queued task", StandingQueued)
  , ("Active task", StandingActive StageImplement)
  , ("Halted task", StandingWaitingForYou StageVerify "verify-failed")
  , ("Verified task", StandingTechnicallyVerified (Just commit))
  , ("Done task", StandingHumanDone)
  , ("Stopped task", StandingStopped "stopped-by-person")
  , ("Canceled task", StandingCanceled)
  , ("Strange task", StandingUnknown "teleported")
  ]

viewWith :: WhereItRuns -> IO ProgressView
viewWith whereItRuns = do
  project <- either (const (assertFailure "project uuid")) (pure . ProjectId) (parseUuid projectUuid)
  rows <-
    traverse
      ( \(n, (title, standing)) -> do
          task <- either (const (assertFailure "task uuid")) (pure . TaskId) (parseUuid (taskUuid n))
          pure
            ProgressRow
              { rowTask = task
              , rowTitle = title
              , rowPriority = 500
              , rowSource = if title == "Ready task" then Just "jira https://acme.atlassian.net/projects/CAE CAE-7 @ 3" else Nothing
              , rowStanding = standing
              , rowPublication = NotPublished
              }
      )
      (L.zip [1 :: Int ..] standings)
  next <- either (const (assertFailure "task uuid")) (pure . TaskId) (parseUuid (taskUuid 2))
  pure
    ProgressView
      { progressProject = project
      , progressName = "Caesura"
      , progressRows = rows
      , progressNext = Just next
      , progressWhere = whereItRuns
      }

running :: WhereItRuns
running =
  RunsWith
    Placement
      { placementEngineer = "caesura-engineer"
      , placementFolder = "/Users/owner/projects/caesura"
      , placementChecks = "lockstep-bug-fix"
      , placementChecksVersion = 2
      , placementChecksDigest = "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12"
      }

rendered :: WhereItRuns -> IO T.Text
rendered w = do
  view <- viewWith w
  either (const (assertFailure "the page is not UTF-8")) pure (TE.decodeUtf8' (LBS.toStrict (progressPage view)))

-- | The table row whose standing is this code (from its @data-standing@ to its @</tr>@).
rowOf :: T.Text -> T.Text -> IO T.Text
rowOf page code =
  case T.breakOn ("data-standing=\"" <> code <> "\"") page of
    (_, rest)
      | T.null rest -> assertFailure ("no row with standing " <> T.unpack code)
      | otherwise -> pure (fst (T.breakOn "</tr>" rest))

has :: T.Text -> T.Text -> Assertion
has page needle =
  assertBool ("the page lacks " <> show needle) (needle `T.isInfixOf` page)

lacks :: T.Text -> T.Text -> Assertion
lacks page needle =
  assertBool ("the page has " <> show needle) (not (needle `T.isInfixOf` page))

tests :: TestTree
tests =
  testGroup
    "the project's Progress page (C-P6.2)"
    [ testCase "every task has one row with its standing code and a link to its own page (C4, C7)" $ do
        page <- rendered running
        traverse_ (\(n, (_, s)) -> rowOf page (standingCode s) >>= \row -> has row ("/app/tasks/" <> taskUuid n)) (L.zip [1 :: Int ..] standings)
        L.length (T.breakOnAll "data-standing=\"" page) @?= L.length standings
    , testCase "technically verified says committed locally and not Done; only the human-done row says Done (C2)" $ do
        page <- rendered running
        verified <- rowOf page "technically-verified"
        has verified "Checked and committed on its own work branch"
        has verified (T.take 12 commit)
        has verified "Not Done"
        lacks verified "you accepted it"
        done <- rowOf page "human-done"
        has done "Done: you accepted it"
        others <- traverse (rowOf page . standingCode . snd) (L.filter ((/= StandingHumanDone) . snd) standings)
        traverse_ (`lacks` "you accepted it") others
    , testCase "every row says it is not published; no row claims publication or integration (C2)" $ do
        page <- rendered running
        rows <- traverse (rowOf page . standingCode . snd) standings
        traverse_ (`has` "Not published") rows
        traverse_ (\row -> lacks row "Published:" >> lacks row "Integrated") rows
        has page "Lockstep never pushes"
    , testCase "the reasons are shown: what a task waits for, why it is blocked, the step and the stop (C1, C4)" $ do
        page <- rendered running
        rowOf page "waiting" >>= (`has` "Ready task")
        rowOf page "blocked" >>= (`has` "a design is missing")
        rowOf page "cannot-start" >>= (`has` "Canceled task")
        rowOf page "active" >>= (`has` "changing the code")
        rowOf page "waiting-for-you" >>= (`has` "running the checks")
        rowOf page "unknown" >>= (`has` "teleported")
    , testCase "waiting for you lists the stopped fix, linked to its page (C4)" $ do
        page <- rendered running
        let
          section = fst (T.breakOn "</section>" (snd (T.breakOn "id=\"waiting-for-you\"" page)))
        assertBool "no waiting-for-you section" (not (T.null section))
        has section "Halted task"
        has section ("/app/tasks/" <> taskUuid 8)
        lacks section "Verified task"
    , testCase "the next task to hand over is named; no approved plan is claimed (C3, C4)" $ do
        page <- rendered running
        has page "Next to hand over"
        has page "Ready task"
        has page "No approved plan"
    , testCase "who works where, under which checks; usage is not recorded, not invented (C4)" $ do
        page <- rendered running
        traverse_ (has page) ["caesura-engineer", "/Users/owner/projects/caesura", "lockstep-bug-fix", "version 2", "ab12cd34ef56"]
        has page "not recorded"
        lacks page "$"
        nowhere <- rendered (RunsNowhere "Lockstep may not work in this project yet.")
        has nowhere "Lockstep may not work in this project yet."
    , testCase "an imported task shows where it came from (C4)" $ do
        page <- rendered running
        rowOf page "ready" >>= (`has` "jira https://acme.atlassian.net/projects/CAE CAE-7 @ 3")
    , testCase "plain words, a read-only page: no internal names, no form; a table with column headers and a way back (C5, C6, C7)" $ do
        page <- rendered running
        traverse_ (lacks page) ["Ticket", "Work Order", "Work Unit", "work order", "<form"]
        has page "<th scope=\"col\">"
        has page ("/app/projects/" <> projectUuid)
        has page "<h1>"
    ]
