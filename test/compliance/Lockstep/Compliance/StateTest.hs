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

import Control.Exception (SomeException, try)
import Control.Monad (foldM)
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Compliance.Support (executeSql, identity, withMigrated)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectClass (..)
  , Intent (..)
  , IntentInput (..)
  , IntentRequest (..)
  , IntentState (..)
  , IntentStateName (..)
  , LookupTerms (..)
  , Observation (..)
  , OperationId (..)
  , Provenance (..)
  , Reason (..)
  , Settlement (..)
  , SubjectRef (..)
  , attestedReasonText
  , effectClassName
  , intentStateNameOf
  , intentStateNameText
  , mkEffectKey
  , mkEffectSpec
  , newIntents
  , parseEffectClass
  , parseIntentStateName
  , reasonOf
  , stepIntent
  )
import Lockstep.Kernel.EffectView (EffectStatus (..), StatusFacts (..), effectStatus)
import Lockstep.Kernel.Execution (admissionBlock)
import Lockstep.Kernel.Identity (TransactionId (..), WorkOrderId (..), identityText, uuidFromWords)
import Lockstep.Kernel.Profile (LayerLevel (..), layerName)
import Lockstep.Kernel.Reconciliation
  ( LookupResult (..)
  , ReconcileInput (..)
  , Resolution (..)
  , ResolutionBasis (..)
  , attestsApplied
  , parseResolutionBasis
  , reconcileIntent
  , renderResolution
  , resolutionBasisText
  , resolveIntent
  )
import Lockstep.Kernel.Runner (CommandEnding (..), OutcomeKind (..), RoleEnding (..), commandEndingText, roleEndingFromText, roleEndingText)
import Lockstep.Kernel.Task (DependencyFact (..), TaskFacts (..), TaskReadiness (..), TaskState (..), parseTaskState, readinessWords, taskReadiness, taskStateName)
import Lockstep.Kernel.Transaction
  ( BaselineClass (..)
  , Counters (..)
  , Disposition (..)
  , HaltCode (..)
  , RecordKind (..)
  , Stage (..)
  , StateName (..)
  , Transaction (..)
  , TxInput (..)
  , TxState (..)
  , fixedHaltText
  , haltCodeFromText
  , haltCodeText
  , maxAttempts
  , maxCorrections
  , mkPlainCode
  , newTransaction
  , noCodingAgent
  , noCounters
  , parseRecordKind
  , parseStateName
  , plainCodeText
  , recordKindText
  , stateColumns
  , stateFromColumns
  , stateNameText
  , stateStage
  , stepTransaction
  , txStateName
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Persistence.Fields (codeField)
import Lockstep.Persistence.Jobs (JobState (..), jobStateCode, parseJobState)
import Lockstep.Persistence.Ledger (durableLevel)
import Lockstep.Persistence.Transactions (TransactionRow (..), findTransaction)

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
        , testCase "L9: through PostgreSQL, a transaction row whose columns hold no state fails to read; it is not taken for a state" $
            withMigrated $ \run -> do
              txId <- identity "c9c9c9c9-c9c9-4c9c-8c9c-c9c9c9c9c9c9" :: IO TransactionId
              -- The row needs no work order or task here, and the combination check is the one under test.
              traverse_
                (run . executeSql . ("ALTER TABLE lockstep_transactions DROP CONSTRAINT " <>))
                ["lockstep_transactions_work_order_id_fkey", "lockstep_transactions_task_id_fkey", "lockstep_transactions_check"]
              run
                ( executeSql
                    ( "INSERT INTO lockstep_transactions (id, work_order_id, task_id, engineer_name, folder, state, stage, revision) VALUES ('"
                        <> T.unpack (identityText txId)
                        <> "', gen_random_uuid(), gen_random_uuid(), 'compliance-engineer', '/f', 'running', 'basis', 1)"
                    )
                )
              control <- run (findTransaction txId)
              fmap txRowState control @?= Just (Running StageBasis)
              let
                corrupt assignment = do
                  run (executeSql ("UPDATE lockstep_transactions SET " <> assignment))
                  found <- try (run (findTransaction txId)) :: IO (Either SomeException (Maybe TransactionRow))
                  case found of
                    Left e -> assertBool ("the failure names the columns: " <> show e) ("state, stage and halt_code" `T.isInfixOf` T.pack (show e))
                    Right row -> assertFailure ("read as " <> show (fmap txRowState row))
              corrupt "halt_code = 'x'"
              corrupt "state = 'halted', halt_code = NULL"
              corrupt "state = 'accepted', stage = 'verify', halt_code = NULL"
        ]
    , testGroup
        "1b. halt codes"
        [ testCase "the parameterised halt codes are the concatenations written before; the fixed ones their literal texts" $ do
            haltCodeText (HaltRoleFailed "malformed-output") @?= "role-failed " <> "malformed-output"
            haltCodeText (HaltUncertainInvocation "helper-no-result") @?= "uncertain-invocation " <> "helper-no-result"
            haltCodeText (HaltSupervisorFailed "branch-moved") @?= "supervisor-failed " <> "branch-moved"
            haltCodeText (HaltRoleFailed noCodingAgent) @?= "role-failed no-coding-agent"
            fmap fixedHaltText [minBound .. maxBound] @?= formerFixedCodes
        , testCase "the Kernel halts with those bytes" $ do
            haltOf [BasisReady, RoleFailed "role-crashed"] @?= Just "role-failed role-crashed"
            haltOf [BasisReady, RoleUncertain "helper-no-result"] @?= Just "uncertain-invocation helper-no-result"
            haltOf [BasisReady, SupervisorFailed "basis-missing"] @?= Just "supervisor-failed basis-missing"
            haltOf [BasisRefused "repository-dirty"] @?= Just "repository-dirty"
        , testCase "every halt and stop code the Kernel makes reads back as the code it is, and a fixed rule's never as a refusal" $
            traverse_
              ( \(input, code) -> do
                  haltCodeText (haltCodeFromText code) @?= code
                  assertBool
                    ("a rule's own code read as a refusal: " <> T.unpack code)
                    (carriesRefusal input || not (isRefused (haltCodeFromText code)))
              )
              kernelCodes
        , testCase "the encoder is injective: every value of every kind reads back as itself" $ do
            traverse_ (\h -> haltCodeFromText (haltCodeText h) @?= h) (haltValues sampleTexts)
            -- and decoding then encoding is the identity on any text
            traverse_ (\t -> haltCodeText (haltCodeFromText t) @?= t) sampleTexts
        , testCase "a refusal code that another kind spells is not a plain code" $ do
            fmap (fmap plainCodeText . mkPlainCode) ["role-failed x", "uncertain-invocation y", "supervisor-failed z", "reproduction-missing", "stopped by a person"]
              @?= [Nothing, Nothing, Nothing, Nothing, Nothing]
            fmap plainCodeText (mkPlainCode "tests-overlap-allowed") @?= Just "tests-overlap-allowed"
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
        , testCase "a command's ending is the text written before (it is never read back)" $ do
            commandEndingText CommandInterrupted @?= "interrupted"
            commandEndingText CommandRunnerFailed @?= "runner-failed"
            fmap (commandEndingText . CommandRan) [minBound .. maxBound :: OutcomeKind]
              @?= ["exited", "timed-out", "output-limit", "output-held", "cancelled", "launch-failed", "provider-stopped"]
        ]
    , testGroup
        "record kinds"
        [ testCase "record kinds are the texts stored before, and read back; an unknown kind does not decode" $ do
            fmap recordKindText [minBound .. maxBound]
              @?= [ "started"
                  , "halt"
                  , "input"
                  , "resume"
                  , "completion"
                  , "uncertain"
                  , "basis-refused"
                  , "basis"
                  , "discovery"
                  , "reproduction"
                  , "candidate"
                  , "candidate-rejected"
                  , "baseline"
                  , "finding"
                  , "contract"
                  , "freeze"
                  , "implementation-refused"
                  , "implementation"
                  , "verification"
                  , "verification-summary"
                  , "post-finding"
                  , "review"
                  , "acceptance"
                  ]
            let
              field = codeField "record kind" recordKindText parseRecordKind "kind"
              decode = O.sqlTypeFromSql (O.fieldType field) . SqlValue.fromText
            traverse_ (\k -> decode (recordKindText k) @?= Right k) [minBound .. maxBound :: RecordKind]
            assertBool "an unknown kind is a decoding failure" (isLeft (decode "note"))
        ]
    , testGroup
        "profile source levels"
        [ testCase "a stored level is one of the three durable levels; an override or an unknown level does not decode" $ do
            fmap layerName [LayerBaseline, LayerRepositoryDefault, LayerSpecialization] @?= ["baseline", "repository-default", "specialization"]
            let
              field = codeField "profile source level" layerName durableLevel "level"
              decode = O.sqlTypeFromSql (O.fieldType field) . SqlValue.fromText
            traverse_ (\l -> decode (layerName l) @?= Right l) [LayerBaseline, LayerRepositoryDefault, LayerSpecialization]
            assertBool "an override is not a stored level" (isLeft (decode "override"))
            assertBool "an unknown level is a decoding failure" (isLeft (decode "default"))
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
        , -- The Kernel's resolveIntent writes exactly this text (pinned by the frozen ReconciliationTest).
          testCase "H1: a destination's answer carrying the marker is a malformed answer, never an attested outcome" $ do
            let
              forged = "human-attested: nobody asked"
            notApplied <- observedWith TermsUnqueryable (DestinationNotApplied forged)
            intentState notApplied @?= IntentUnknown "malformed-answer"
            applied <- observedWith TermsUnqueryable (DestinationApplied forged)
            intentState applied @?= IntentUnknown "malformed-answer"
            noAnswer <- observedWith TermsUnqueryable (NoAnswer forged)
            intentState noAnswer @?= IntentUnknown "malformed-answer"
            effectStatus (StatusFacts t0 True False) notApplied @?= StatusUnknown
            -- A lookup's result is the destination's too.
            lookedUp <- dispatchedWith (TermsQueryable (LookupTerms True True))
            fmap intentState (reconcileIntent lookedUp (Command Supervisor (ReconcileInput (at 120) (LookupFound forged))))
              @?= Right (IntentUnknown "malformed-answer")
        , testCase "H1: an ordinary destination answer is kept as it came" $ do
            notApplied <- observedWith TermsRepeatable (DestinationNotApplied "busy")
            intentState notApplied @?= IntentNotApplied "busy"
            effectStatus (StatusFacts t0 True False) notApplied @?= StatusNotApplied
        , testCase "H1: a person's attestation still is attested" $ do
            unknown <- observedWith TermsUnqueryable (NoAnswer "timeout")
            settled <- either (assertFailure . show) pure (resolveIntent unknown (Command Human (intentGeneration unknown, AttestApplied "seen")))
            intentState settled @?= IntentSettled (SettledApplied "human-attested: seen")
            effectStatus (StatusFacts t0 True False) settled @?= StatusAttested
        , testCase "an attestation record is read as applied only from its own leading word" $ do
            attestsApplied (renderResolution (AttestApplied "seen")) @?= True
            attestsApplied (renderResolution (AttestNotApplied "seen")) @?= False
            attestsApplied (renderResolution (RetryAcknowledgingDuplication True)) @?= False
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

-- | The fixed codes as the code spelt them before Increment C (the oracle), in 'FixedHalt' order.
formerFixedCodes :: [T.Text]
formerFixedCodes =
  [ "reproduction-missing"
  , "baseline-run-failed"
  , "candidates-exhausted"
  , "green-regression-failed"
  , "finding-needs-human"
  , "attempts-exhausted"
  , "review-needs-human"
  , "stopped by a person"
  , "not accepted by a person"
  , "verification-environment-missing"
  , "verification-run-failed"
  , "protected-test-changed"
  , "repository-dirty"
  , "repository-missing"
  , "not-a-repository"
  ]

-- | Texts of every shape: plain, empty, each structured word, each fixed code, and codes nested in words.
sampleTexts :: [T.Text]
sampleTexts =
  ["", "x", "tests-overlap-allowed", "role-failed", "role-failed ", "role-failed reproduction-missing", "uncertain-invocation role-failed x", "supervisor-failed  two spaces", "Role-failed x"]
    <> formerFixedCodes
    <> fmap (<> " ") formerFixedCodes

-- | Every value of every kind: each fixed code, each structured kind over every sample payload, and every plain code the samples allow.
haltValues :: [T.Text] -> [HaltCode]
haltValues payloads =
  fmap HaltFixed [minBound .. maxBound]
    <> [k p | k <- [HaltRoleFailed, HaltUncertainInvocation, HaltSupervisorFailed], p <- payloads]
    <> [HaltRefused p | Just p <- fmap mkPlainCode payloads]

-- | Every halt or stop the Kernel makes: each input, from each stage, at the budgets' edges, then a person's stop of each halt.
kernelCodes :: [(TxInput, T.Text)]
kernelCodes =
  [ (input, code)
  | stage <- [minBound .. maxBound]
  , counters <- [Counters 0 0, Counters maxCorrections 0, Counters (maxCorrections + 1) (maxAttempts - 1), Counters 9 9]
  , input <- supervisorInputs
  , Right next <- [stepTransaction Supervisor input (Transaction (Running stage) counters)]
  , code <- codesOf next
  ]
    <> [ (HumanStop, code)
       | stage <- [minBound .. maxBound]
       , input <- supervisorInputs
       , Right halted <- [stepTransaction Supervisor input (Transaction (Running stage) (Counters 9 9))]
       , Right stopped <- [stepTransaction Human HumanStop halted]
       , code <- codesOf stopped
       ]
    <> [(HumanStop, code) | Right stopped <- [stepTransaction Human HumanStop (Transaction Accepted noCounters)], code <- codesOf stopped]
    <> [(HumanStop, code) | Right stopped <- [stepTransaction Human HumanStop (Transaction (Running StageBasis) noCounters)], code <- codesOf stopped]
 where
  codesOf tx =
    case txState tx of
      Halted _ c -> [c]
      Stopped c -> [c]
      _ -> []

supervisorInputs :: [TxInput]
supervisorInputs =
  [ BasisReady
  , BasisRefused "repository-dirty"
  , DiscoveryAnswered
  , Reproduced
  , NotReproduced
  , CandidateClassified [RedConfirmed]
  , CandidateClassified [RunFailed]
  , CandidateClassified [RedWrongReason]
  , CandidateRejected "criterion-not-grounded"
  , RegressionFailed
  , ChallengeDisposed [Confirmed]
  , ChallengeDisposed [NeedsHumanFinding]
  , ChallengeDisposed []
  , TestsFrozen
  , Implemented
  , ImplementationRefused "no-change"
  , VerificationPassed
  , VerificationFailed
  , VerificationInconclusive "verification-environment-missing"
  , ReviewApproved
  , ReviewRejected
  , ReviewNeedsHuman
  , CommitAccepted
  , RoleFailed "role-crashed"
  , RoleUncertain "helper-no-result"
  , SupervisorFailed "branch-moved"
  , ScopeRefused "tests-overlap-allowed"
  ]

-- | An input whose halt code is a refusal code it carries (so it may read as any kind).
carriesRefusal :: TxInput -> Bool
carriesRefusal input =
  case input of
    BasisRefused _ -> True
    VerificationInconclusive _ -> True
    ScopeRefused _ -> True
    HumanStop -> True
    _ -> False

isRefused :: HaltCode -> Bool
isRefused code =
  case code of
    HaltRefused _ -> True
    _ -> False

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 19) (secondsToDiffTime 0)

at :: Integer -> UTCTime
at n =
  addUTCTime (fromInteger n) t0

-- | A dispatched intent of these terms (claimed until 60 s, dispatched at 1 s), as the frozen unit fixtures build one.
dispatchedWith :: ClassTerms -> IO Intent
dispatchedWith terms = do
  spec <- either (assertFailure . show) pure (mkEffectSpec "step" terms 0)
  key <- either (assertFailure . show) pure (mkEffectKey "first")
  intents <- either (assertFailure . show) pure (newIntents sha256Hasher (SubjectWorkOrder (WorkOrderId (uuidFromWords 2 1))) 4 [(OperationId (uuidFromWords 4 1), IntentRequest key spec "p=1")])
  pending <-
    case intents of
      [i] -> pure i
      _ -> assertFailure "one intent"
  either (assertFailure . show) pure (foldM stepIntent pending [Command Supervisor (IntentClaim "w1" t0 (at 60)), Command Supervisor (IntentDispatch 1 (at 1))])

observedWith :: ClassTerms -> Observation -> IO Intent
observedWith terms observation = do
  dispatched <- dispatchedWith terms
  either (assertFailure . show) pure (stepIntent dispatched (Command Supervisor (IntentObserve 1 observation)))

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
