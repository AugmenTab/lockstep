{-# LANGUAGE OverloadedStrings #-}

{- | Increment D of the type-discipline remediation (2026-11-08): typed
failures. Each check pins that a typed refusal or encoder gives exactly the
bytes the string-built code gave before (the old expressions are kept here as
the oracle), and that the decisions made on a refusal follow its constructor.
-}
module Lockstep.Compliance.FailureTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Decisions (ReceiptOutcome (..), receiptOutcomeCode)
import Lockstep.Application.Ledger (LedgerFailure (..), createTicket, showTicket)
import Lockstep.Application.LedgerRefusal
  ( EvidenceRule (..)
  , FactsRule (..)
  , InactiveFor (..)
  , KeyExpiry (..)
  , LedgerRefusal (..)
  , OwnershipLoss (..)
  , RecordRule (..)
  , StaleSubject (..)
  , ledgerRefusalCode
  , ledgerRefusalMessage
  , refusalFailure
  )
import Lockstep.Application.ProjectChecks (ChecksRefusal (..), checksRefusalCode)
import Lockstep.Application.Repositories (Refused (..), RepositoryRefusal (..), refusedCode, refusedMessage)
import Lockstep.Application.Sandbox (sandboxRequest)
import Lockstep.Compliance.Support (executeSql, identity, withMigratedRuntime)
import Lockstep.Kernel.Activation (CarryRefusal (CarryConflict), carryRefusalCode)
import Lockstep.Kernel.Conversation (RequestInput (HumanSays), messagePayloadText)
import Lockstep.Kernel.Effect (EffectRefusal (StaleClaim), OperationId (..), effectRefusalCode)
import Lockstep.Kernel.Identity (TicketId (..), identityText)
import Lockstep.Kernel.Profile (LayerLevel (..), ProfileRefusal (BindingNotAuthorized, UntrustedClassification), layerName, profileRefusalCode, renderProfileRefusal)
import Lockstep.Kernel.Reconciliation (ReconcileRefusal (ReconcileStaleClaim), reconcileRefusalCode)
import Lockstep.Kernel.Recovery (RecoveryRefusal (RecoveryLeaseActive), recoveryRefusalCode)
import Lockstep.Kernel.Repository (RegistrationRefusal (AuthoritativeRemoteAmbiguous, AuthoritativeRemoteUnknown, NotAGitRepository), refusalCode, renderRefusal)
import Lockstep.Kernel.Scheduler (SchedulerRefusal (InvalidPriority), schedulerRefusalCode)
import Lockstep.Kernel.Transition (Principal (..), TransitionRefusal (IllegalTransition), principalLabel, transitionRefusalCode)
import Lockstep.Persistence.Ledger (SubjectKind (..), subjectKindCode, subjectKindField)

tests :: TestTree
tests =
  testGroup
    "type-discipline Increment D: typed failures, the same codes and bytes"
    [ testCase "1. every Ledger refusal renders the code and words the string-built refusal had" $
        traverse_ (\(refusal, code, message) -> refusalFailure refusal @?= LedgerRefused code message) ledgerRefusals
    , testCase "1a. the oracle covers every value of every rule a refusal carries" $ do
        [r | (InvalidRecord r, _, _) <- ledgerRefusals] @?= [minBound .. maxBound]
        [s | (StaleRevision s, _, _) <- ledgerRefusals] @?= [minBound .. maxBound]
        [r | (InvalidFacts r, _, _) <- ledgerRefusals] @?= [minBound .. maxBound]
        [r | (GateEvidenceInvalid r, _, _) <- ledgerRefusals] @?= [minBound .. maxBound]
        [r | (RepositoryNotOwned r, _, _) <- ledgerRefusals] @?= [minBound .. maxBound]
        [r | (SubjectNotActive r, _, _) <- ledgerRefusals] @?= [minBound .. maxBound]
        [r | (IdempotencyKeyExpired r, _, _) <- ledgerRefusals] @?= [minBound .. maxBound]
    , testCase "1b. the effect-key and sandbox refusals build their words as the old expressions did" $ do
        holders <- traverse identity ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"] :: IO [OperationId]
        refusalFailure (EffectKeyInUse holders)
          @?= LedgerRefused
            "effect-key-in-use"
            ( T.pack
                ( "the same effect key is held by "
                    <> T.unpack (T.intercalate (T.pack ", ") (fmap identityText holders))
                    <> "; abandon one (with --acknowledge-duplication-risk if it was dispatched), requeue without declaring the key again, and carry the other"
                )
            )
        let
          catalogue = ["sandbox-repeatable", "sandbox-idempotent", "sandbox-queryable", "sandbox-unqueryable"] :: [String]
          text = "nope:apply"
        sandboxRequest (T.pack text)
          @?= Left
            ( LedgerRefused
                (T.pack "unknown-sandbox-effect")
                (T.pack ("no sandbox effect " <> text <> "; known: " <> L.intercalate ", " catalogue <> ", each with an optional :apply, :refuse, :hang or :apply-then-hang"))
            )
        refusalFailure (InvalidKind "deploy") @?= LedgerRefused "invalid-kind" (T.pack ("no work order kind " <> "deploy"))
    , testCase "2. a Kernel refusal keeps the Kernel's own code; its words are explicit, no longer its Show text" $ do
        let
          kernel =
            [ (TransitionRefused (IllegalTransition "pending" "accept"), transitionRefusalCode (IllegalTransition "pending" "accept"), T.pack (show (IllegalTransition "pending" "accept")))
            , (EffectRefused StaleClaim, effectRefusalCode StaleClaim, T.pack (show StaleClaim))
            , (SchedulerRefused (InvalidPriority 1000), schedulerRefusalCode (InvalidPriority 1000), T.pack (show (InvalidPriority 1000)))
            , (RecoveryRefused RecoveryLeaseActive, recoveryRefusalCode RecoveryLeaseActive, T.pack (show RecoveryLeaseActive))
            , (ReconcileRefused ReconcileStaleClaim, reconcileRefusalCode ReconcileStaleClaim, T.pack (show ReconcileStaleClaim))
            , (CarryRefused CarryConflict, carryRefusalCode CarryConflict, T.pack (show CarryConflict))
            , (ProfileRuleRefused (BindingNotAuthorized Agent), profileRefusalCode (BindingNotAuthorized Agent), "")
            ]
        traverse_
          ( \(refusal, code, shown) -> do
              ledgerRefusalCode refusal @?= code
              assertBool ("words, not the Show text: " <> T.unpack (ledgerRefusalMessage refusal)) (ledgerRefusalMessage refusal /= shown && not (T.null (ledgerRefusalMessage refusal)))
          )
          kernel
        -- The stale-claim refusal stored with an observation is the Kernel's code.
        ledgerRefusalCode (EffectRefused StaleClaim) @?= "stale-claim"
        ledgerRefusalCode LookupOutdated @?= "stale-claim"
    , testCase "3. the principal's constructor spelling is the bytes 'show' gave: message rows, the H5 canonical text, transaction records" $ do
        traverse_ (\p -> principalLabel p @?= T.pack (show p)) [minBound .. maxBound :: Principal]
        traverse_ (\p -> T.toLower (principalLabel p) @?= T.toLower (T.pack (show p))) [minBound .. maxBound :: Principal]
        T.toLower (principalLabel DeliveryAdapter) @?= "deliveryadapter"
        traverse_
          ( \p ->
              assertBool
                "the canonical message text names the principal as before"
                (("\nprincipal " <> T.pack (show p) <> "\n") `T.isInfixOf` messagePayloadText "r" p "e" (HumanSays 1 "t"))
          )
          [minBound .. maxBound :: Principal]
    , testCase "3b. a Profile refusal naming a principal renders the bytes 'show' gave" $
        traverse_
          ( \p -> do
              renderProfileRefusal (UntrustedClassification p) @?= "only a human may classify work, not " <> T.pack (show p)
              renderProfileRefusal (BindingNotAuthorized p) @?= "not authorized: " <> T.pack (show p)
          )
          [minBound .. maxBound :: Principal]
    , testCase "4. the subject kind is a typed column with the stored codes; an unknown kind is a decoding failure" $ do
        fmap subjectKindCode [minBound .. maxBound :: SubjectKind] @?= ["ticket", "work-order"]
        let
          decode = O.sqlTypeFromSql (O.fieldType subjectKindField) . SqlValue.fromText
        O.fieldNameToString (O.fieldName subjectKindField) @?= "kind"
        traverse_ (\k -> decode (subjectKindCode k) @?= Right k) [minBound .. maxBound :: SubjectKind]
        assertBool "an unknown kind does not decode" (isLeft (decode "task"))
    , testCase "4b. through the Ledger, a subject whose kind is corrupt is an integrity failure, not an unknown ticket" $
        withMigratedRuntime $ \runtime run -> do
          created <- createTicket runtime "Compliance ticket"
          TicketId u <- either (assertFailure . show) pure created
          run (executeSql "ALTER TABLE lockstep_subjects DROP CONSTRAINT lockstep_subjects_kind_check")
          run (executeSql ("UPDATE lockstep_subjects SET kind = 'bogus' WHERE id = '" <> T.unpack (identityText (TicketId u)) <> "'"))
          shown <- showTicket runtime (TicketId u)
          case shown of
            Left (LedgerIntegrity detail) -> assertBool ("names the column and value: " <> T.unpack detail) ("kind" `T.isInfixOf` detail && "bogus" `T.isInfixOf` detail)
            other -> assertFailure ("not an integrity failure: " <> show other)
    , testCase "5. the project checks page's source levels are the Kernel's layer names, the bytes levelText wrote" $
        fmap layerName [LayerBaseline, LayerRepositoryDefault, LayerSpecialization, LayerOverride] @?= ["baseline", "repository-default", "specialization", "override"]
    , testCase "6. the checks and repository refusals keep their codes and words" $ do
        fmap receiptOutcomeCode [minBound .. maxBound :: ReceiptOutcome] @?= ["applied", "refused"]
        fmap checksRefusalCode [minBound .. maxBound :: ChecksRefusal]
          @?= ["unknown-project", "checks-changed", "profile-unknown", "profile-integrity", "fewer-checks-unconfirmed", "project-has-no-folder"]
        let
          refused r = Refused r 1
        fmap (\r -> (refusedCode (refused r), refusedMessage (refused r))) [EngineerNameInvalid, EngineerNameTaken, EngineerUnknown]
          @?= [ ("engineer-name-invalid", "an Engineer name is a-z followed by up to 39 of a-z, 0-9 and -")
              , ("engineer-name-taken", "an Engineer with this name exists")
              , ("unknown-engineer", "there is no Engineer with this name")
              ]
        traverse_
          (\r -> (refusedCode (refused (RegistrationRefused r)), refusedMessage (refused (RegistrationRefused r))) @?= (refusalCode r, renderRefusal r))
          [AuthoritativeRemoteAmbiguous ["origin", "upstream"], AuthoritativeRemoteUnknown "origin", NotAGitRepository]
    ]

-- | Each refusal with the code and words the string-built code gave (copied from it).
ledgerRefusals :: [(LedgerRefusal, T.Text, T.Text)]
ledgerRefusals =
  [ (RevisionOutOfRange, "revision-out-of-range", "a revision or generation is outside the range of a stored integer")
  , (InvalidRecord TitleRule, "invalid-record", "a title has 1 to 200 characters and no control characters")
  , (InvalidRecord ReasonRule, "invalid-record", "a reason is 1-4096 characters without control characters")
  , (InvalidRecord LeaseRule, "invalid-record", "a lease lasts 1 to 3600 seconds")
  , (InvalidRecord ClaimOwnerRule, "invalid-record", "a claim needs an owner")
  , (InvalidRecord RecoveryOwnerRule, "invalid-record", "a recovery needs an owner")
  , (InvalidRecord PlanReferenceRule, "invalid-record", "a plan reference has 1 to 200 characters and no control characters")
  , (InvalidRecord ExecutorRule, "invalid-record", "an executor needs an owner, a lease of 1-3600 s, a timeout below the lease, and one adapter per spec")
  , (InvalidRecord ReconciliationRule, "invalid-record", "a reconciliation needs a timeout of 1-600000 ms and one reconciler per spec")
  , (NotDurable "the codec's reason", "not-durable", "the codec's reason")
  , (UnknownTicket, "unknown-ticket", "there is no such ticket")
  , (StaleRevision StaleTicket, "stale-revision", "the ticket has moved on; re-read it")
  , (StaleRevision StaleWorkOrder, "stale-revision", "the work order has moved on; re-read it")
  , (StaleRevision StaleStep, "stale-revision", "the step changed since the page was shown")
  , (TicketNotReady, "ticket-not-ready", "a work order needs a ready or in-progress ticket")
  , (UnknownEngineer, "unknown-engineer", "there is no Engineer with this name")
  , (EngineerHasNoRepository, "engineer-has-no-repository", "the Engineer owns no repository")
  , (RepositoryDefaultProfileUnset, "repository-default-profile-unset", "the repository has no default profile; see repository set-profile")
  , (UnknownDependency, "unknown-dependency", "a dependency is not a known work order")
  , (InvalidFacts ClassTagRule, "invalid-facts", "not a valid class tag")
  , (InvalidFacts PathClassRule, "invalid-facts", "not a valid path class")
  , (InvalidFacts RationaleRule, "invalid-facts", "not a valid non-behavioural rationale")
  , (UnknownWorkOrder, "unknown-work-order", "there is no such work order")
  , (IntentsNotAuthorized, "intents-not-authorized", "only a Supervisor's start or resume may authorize effect intents")
  , (EvidenceNotAuthorized, "not-authorized", "only a human or the Supervisor records gate evidence")
  , (GateEvidenceInvalid UnknownArtifact, "invalid-evidence", "an unknown artifact")
  , (GateEvidenceInvalid DigestRule, "invalid-evidence", "a digest must be 64 lowercase hex characters")
  , (GateEvidenceInvalid UnknownVerifier, "invalid-evidence", "an unknown verifier")
  , (GateEvidenceInvalid UnknownApproval, "invalid-evidence", "an unknown approval (none, supervisor or human)")
  , (WorkOrderNotActive, "work-order-not-active", "a work unit is admitted only for a claimed or active work order")
  , (WorkOrderNotClaimed, "work-order-not-claimed", "only a claimed work order can be started")
  , (RepositoryNotOwned NoActiveOwner, "repository-not-owned", "the work order's repository has no active owner")
  , (RepositoryNotOwned ClaimantNoLongerOwns, "repository-not-owned", "the claiming Engineer no longer owns the order's repository")
  , (UnknownIntent, "unknown-intent", "there is no such effect intent")
  , (SubjectNotActive InactiveForDispatch, "subject-not-active", "the work order is not active; nothing may be dispatched for it")
  , (SubjectNotActive InactiveForCarry, "subject-not-active", "the work order is not active")
  , (ActivationSuperseded, "activation-superseded", "the intent belongs to an earlier activation of its work order; a Human must carry it first")
  , (IdempotencyKeyExpired ExpiredAtDispatch, "idempotency-key-expired", "the idempotency key's guarantee has ended; the earlier dispatch may still apply, so nothing was sent")
  ,
    ( IdempotencyKeyExpired ExpiredAtRetry
    , "idempotency-key-expired"
    , "the idempotency key's guarantee has ended; attest that it applied, or abandon the effect with --acknowledge-duplication-risk (a not-applied attestation would only be refused again at dispatch)"
    )
  , (LookupOutdated, "stale-claim", "the intent moved on while it was looked up")
  , (NoAdapter, "no-adapter", "this executor has no adapter for the effect")
  , (AdapterMismatch, "adapter-mismatch", "the adapter implements another spec than the intent declares")
  , (NoReconciler, "no-reconciler", "no reconciler serves the effect")
  , (ReconcilerMismatch, "reconciler-mismatch", "the reconciler serves another spec than the intent declares")
  , (LookupNotQueryable, "not-queryable", "only a queryable effect can be looked up at its destination")
  ]
