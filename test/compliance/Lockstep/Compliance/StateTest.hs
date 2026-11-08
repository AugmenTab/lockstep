{-# LANGUAGE OverloadedStrings #-}

{- | Increment C of the type-discipline remediation (2026-11-08): typed state at
the persistence boundary. Each check pins that a typed encoder writes exactly
the text the string-built code wrote before (the old expressions are kept here
as the oracle), that its one decoder reads every such text back, and that a
stored text no value has is refused rather than defaulted.
-}
module Lockstep.Compliance.StateTest
  ( tests
  ) where

import Control.Monad (foldM)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Lockstep.Kernel.Effect
  ( EffectClass (..)
  , IntentState (..)
  , IntentStateName (..)
  , Provenance (..)
  , Reason (..)
  , Settlement (..)
  , attestedReasonText
  , effectClassName
  , intentStateNameOf
  , intentStateNameText
  , parseEffectClass
  , parseIntentStateName
  , reasonOf
  )
import Lockstep.Kernel.Execution (admissionBlock)
import Lockstep.Kernel.Reconciliation (ResolutionBasis (..), parseResolutionBasis, resolutionBasisText)
import Lockstep.Kernel.Runner (CommandEnding (..), OutcomeKind (..), RoleEnding (..), commandEndingFromText, commandEndingText, roleEndingFromText, roleEndingText)
import Lockstep.Kernel.Task (DependencyFact (..), TaskFacts (..), TaskReadiness (..), TaskState (..), parseTaskState, readinessWords, taskReadiness, taskStateName)
import Lockstep.Kernel.Transaction
  ( HaltCode (..)
  , Stage (..)
  , StateName (..)
  , TxInput (..)
  , TxState (..)
  , haltCodeFromText
  , haltCodeText
  , newTransaction
  , parseStateName
  , stateColumns
  , stateFromColumns
  , stateNameText
  , stateStage
  , stepTransaction
  , txState
  , txStateName
  )
import Lockstep.Kernel.Transition (Principal (..))
import Lockstep.Persistence.Fields (codeField)
import Lockstep.Persistence.Jobs (JobState (..), jobStateCode, parseJobState)

tests :: TestTree
tests =
  testGroup
    "type-discipline Increment C: typed state, the same stored bytes"
    [ testGroup
        "1. transaction state columns"
        [ testCase "state names are the texts stored before, and a name no state has is a decoding failure" $ do
            fmap stateNameText [minBound .. maxBound] @?= ["running", "halted", "accepted", "done", "stopped"]
            fmap txStateName [Running StageVerify, Halted StageVerify "x", Accepted, Done, Stopped "x"] @?= ["running", "halted", "accepted", "done", "stopped"]
            let
              field = codeField "transaction state" stateNameText parseStateName "state"
              decode = O.sqlTypeFromSql (O.fieldType field) . SqlValue.fromText
            traverse_ (\n -> decode (stateNameText n) @?= Right n) [minBound .. maxBound :: StateName]
            assertBool "an unknown state name is a decoding failure" (isLeft (decode "paused"))
        , testCase "every state's columns read back as that state, and the stage column is derived once" $
            traverse_
              ( \(state, lastStage) -> do
                  let
                    (name, code) = stateColumns state
                  stateFromColumns name (stateStage lastStage state) code @?= Just state
              )
              [ (Running StageBasis, StageBasis)
              , (Running StageReview, StageVerify)
              , (Halted StageCandidate "candidates-exhausted", StageCandidate)
              , (Accepted, StageAccept)
              , (Done, StageAccept)
              , (Stopped "stopped by a person", StageFreeze)
              ]
        , testCase "a stopped transaction keeps the stage it was last at; the others store their own" $ do
            stateStage StageFreeze (Stopped "x") @?= StageFreeze
            stateStage StageFreeze (Running StageVerify) @?= StageVerify
            stateStage StageFreeze (Halted StageReview "x") @?= StageReview
            stateStage StageFreeze Accepted @?= StageAccept
            stateStage StageFreeze Done @?= StageAccept
        , testCase "a combination of columns no state has does not read" $ do
            stateFromColumns StateRunning StageBasis (Just "x") @?= Nothing
            stateFromColumns StateHalted StageBasis Nothing @?= Nothing
            stateFromColumns StateStopped StageBasis Nothing @?= Nothing
            stateFromColumns StateAccepted StageAccept (Just "x") @?= Nothing
            stateFromColumns StateDone StageAccept (Just "x") @?= Nothing
            stateFromColumns StateAccepted StageVerify Nothing @?= Nothing
            stateFromColumns StateDone StageBasis Nothing @?= Nothing
        ]
    , testGroup
        "1b. halt codes"
        [ testCase "the parameterised halt codes are the concatenations written before" $ do
            haltCodeText (HaltRoleFailed "malformed-output") @?= "role-failed " <> "malformed-output"
            haltCodeText (HaltUncertainInvocation "helper-no-result") @?= "uncertain-invocation " <> "helper-no-result"
            haltCodeText (HaltSupervisorFailed "branch-moved") @?= "supervisor-failed " <> "branch-moved"
            haltCodeText (HaltPlain "reproduction-missing") @?= "reproduction-missing"
        , testCase "the Kernel halts with those bytes" $ do
            haltOf [BasisReady, RoleFailed "role-crashed"] @?= Just "role-failed role-crashed"
            haltOf [BasisReady, RoleUncertain "helper-no-result"] @?= Just "uncertain-invocation helper-no-result"
            haltOf [BasisReady, SupervisorFailed "basis-missing"] @?= Just "supervisor-failed basis-missing"
            haltOf [BasisRefused "repository-dirty"] @?= Just "repository-dirty"
        , testCase "the one decoder inverts the encoder for every code Lockstep makes" $ do
            traverse_
              (\h -> haltCodeFromText (haltCodeText h) @?= h)
              ( [HaltRoleFailed c | c <- ["malformed-output", "answer-invalid tests-invalid", "provider-stopped budget-exhausted", "no-coding-agent"]]
                  <> [HaltUncertainInvocation c | c <- ["unfinished-invocation", "helper-no-result", "answer-not-recoverable"]]
                  <> [HaltSupervisorFailed c | c <- ["branch-moved", "snapshot-failed"]]
                  <> fmap HaltPlain plainCodes
              )
        ]
    , testGroup
        "4. invocation endings"
        [ testCase "a role's ending is the text written before (\"answered\", \"uncertain\", \"uncertain \" <> code, the code)" $ do
            roleEndingText RoleEndedAnswered @?= "answered"
            roleEndingText RoleEndedUnsettled @?= "uncertain"
            roleEndingText (RoleEndedUncertain "answer-unstable") @?= "uncertain " <> "answer-unstable"
            roleEndingText (RoleEndedFailed "role-crashed") @?= "role-crashed"
        , testCase "the one decoder reads every stored role ending as the former prefix rules did" $
            traverse_
              (\text -> roleEndingFromText text @?= formerRoleDecoding text)
              ["answered", "uncertain", "uncertain answer-unstable", "uncertain helper-no-result", "role-crashed", "runner-refused helper-refused busy", "answer-invalid paths-invalid", "provider-stopped budget-exhausted", ""]
        , testCase "a command's ending is the text written before, and reads back; any other text is refused" $ do
            commandEndingText CommandInterrupted @?= "interrupted"
            commandEndingText CommandRunnerFailed @?= "runner-failed"
            fmap (commandEndingText . CommandRan) [minBound .. maxBound]
              @?= ["exited", "timed-out", "output-limit", "output-held", "cancelled", "launch-failed", "provider-stopped"]
            traverse_ (\e -> commandEndingFromText (commandEndingText e) @?= Just e) ([CommandInterrupted, CommandRunnerFailed] <> fmap CommandRan [minBound .. maxBound :: OutcomeKind])
            commandEndingFromText "answered" @?= Nothing
        ]
    , testGroup
        "2. task state"
        [ testCase "the state names are the Ticket's names, and read back" $ do
            fmap taskStateName [minBound .. maxBound]
              @?= ["proposed", "ready", "in-progress", "code-complete", "awaiting-review", "ready-for-signoff", "done", "canceled", "blocked"]
            traverse_ (\s -> parseTaskState (taskStateName s) @?= Just s) [minBound .. maxBound :: TaskState]
        , testCase "a state no Ticket has is shown as unrecognised, never as being worked on" $ do
            taskReadiness (TaskFacts "in-progres" Nothing []) @?= StateUnrecognised "in-progres"
            taskReadiness (TaskFacts "ready" Nothing [DependencyFact "A" "finished"]) @?= StateUnrecognised "finished"
            admissionBlock (StateUnrecognised "x") @?= Just "task-not-ready"
            assertBool "the words name the state" ("in-progres" `T.isInfixOf` readinessWords (StateUnrecognised "in-progres"))
        , testCase "every state between ready and done is being worked on, as before" $
            traverse_ (\s -> taskReadiness (TaskFacts s Nothing []) @?= BeingWorkedOn) ["in-progress", "code-complete", "awaiting-review", "ready-for-signoff"]
        ]
    , testGroup
        "3. effect intent state and class columns"
        [ testCase "intent state names are the texts stored before, and read back; an unknown name does not decode" $ do
            fmap intentStateNameText [minBound .. maxBound]
              @?= ["pending", "claimed", "dispatched", "confirmed-applied", "confirmed-not-applied", "outcome-unknown", "settled", "abandoned"]
            let
              field = codeField "effect intent state" intentStateNameText parseIntentStateName "state"
              decode = O.sqlTypeFromSql (O.fieldType field) . SqlValue.fromText
            traverse_ (\n -> decode (intentStateNameText n) @?= Right n) [minBound .. maxBound :: IntentStateName]
            assertBool "an unknown intent state is a decoding failure" (isLeft (decode "running"))
            fmap (intentStateNameText . intentStateNameOf) [IntentPending, IntentApplied "r", IntentSettled (SettledNotApplied "r"), IntentAbandoned "r"]
              @?= ["pending", "confirmed-applied", "settled", "abandoned"]
        , testCase "effect class names read back; an unknown class does not decode" $ do
            let
              field = codeField "effect class" effectClassName parseEffectClass "effect_class"
              decode = O.sqlTypeFromSql (O.fieldType field) . SqlValue.fromText
            fmap effectClassName [minBound .. maxBound] @?= ["repeatable", "idempotent", "queryable", "unqueryable"]
            traverse_ (\c -> decode (effectClassName c) @?= Right c) [minBound .. maxBound :: EffectClass]
            assertBool "an unknown class is a decoding failure" (isLeft (decode "maybe"))
        ]
    , testGroup
        "6. attested provenance"
        [ testCase "an attestation's stored reason is the marked text written before, and reads back as attested" $ do
            attestedReasonText "seen" @?= "human-attested: " <> "seen"
            reasonOf (attestedReasonText "seen") @?= Reason HumanAttested "human-attested: seen"
            reasonOf "lookup: not found" @?= Reason Observed "lookup: not found"
            -- The Kernel's resolveIntent writes exactly this text (pinned by the frozen ReconciliationTest).
        ]
    , testGroup
        "7. resolution bases"
        [ testCase "the bases are the texts the migration's CHECK allows, and read back; an unknown basis does not decode" $ do
            fmap resolutionBasisText [minBound .. maxBound]
              @?= ["lookup", "human-attested", "human-retry", "late-observation", "human-abandon", "human-carry"]
            let
              field = codeField "resolution basis" resolutionBasisText parseResolutionBasis "basis"
              decode = O.sqlTypeFromSql (O.fieldType field) . SqlValue.fromText
            traverse_ (\b -> decode (resolutionBasisText b) @?= Right b) [minBound .. maxBound :: ResolutionBasis]
            assertBool "an unknown basis is a decoding failure" (isLeft (decode "human"))
        ]
    , testGroup
        "9. job state"
        [ testCase "job states are the codes stored before, and read back; an unknown state does not decode" $ do
            fmap jobStateCode [minBound .. maxBound] @?= ["queued", "running", "succeeded", "failed"]
            let
              field = codeField "job state" jobStateCode parseJobState "state"
              decode = O.sqlTypeFromSql (O.fieldType field) . SqlValue.fromText
            traverse_ (\s -> decode (jobStateCode s) @?= Right s) [minBound .. maxBound :: JobState]
            assertBool "an unknown job state is a decoding failure" (isLeft (decode "paused"))
        ]
    ]

-- | Plain halt codes the Kernel and the engine make; none begins with a parameterised code's word.
plainCodes :: [T.Text]
plainCodes =
  [ "reproduction-missing"
  , "candidates-exhausted"
  , "baseline-run-failed"
  , "green-regression-failed"
  , "finding-needs-human"
  , "attempts-exhausted"
  , "review-needs-human"
  , "verification-environment-missing"
  , "verification-run-failed"
  , "protected-test-changed"
  , "repository-dirty"
  , "tests-overlap-allowed"
  , "stopped by a person"
  , "not accepted by a person"
  ]

haltOf :: [TxInput] -> Maybe T.Text
haltOf inputs =
  case txState <$> foldM (flip (stepTransaction Supervisor)) newTransaction inputs of
    Right (Halted _ code) -> Just code
    _ -> Nothing

-- | The former decoding in the engine's recovery ('invokeRecorded' before Increment C), as the oracle.
formerRoleDecoding :: T.Text -> RoleEnding
formerRoleDecoding o
  | o == "answered" = RoleEndedAnswered
  | o == "uncertain" = RoleEndedUnsettled
  | Just c <- T.stripPrefix "uncertain " o = RoleEndedUncertain c
  | otherwise = RoleEndedFailed o
