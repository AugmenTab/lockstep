-- | C-P2.8 §5 unit cases: parsing the operator commands.
module Lockstep.Foundation.CliLedgerTest
  ( tests
  ) where

import Data.List qualified as L
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Foundation.Cli
  ( CliError (..)
  , Command (..)
  , EffectChoice (..)
  , EvidenceArgs (..)
  , ExecuteArgs (..)
  , WorkOrderArgs (..)
  , parseArgs
  )

tests :: TestTree
tests =
  testGroup
    "Operator ledger commands (C-P2.8)"
    [ testGroup "ledger, ticket, schedule, sandbox" simpleCases
    , testGroup "work orders and work units" orderCases
    , testGroup "supervisor" supervisorCases
    , testGroup "effects" effectCases
    ]

hex :: String
hex =
  L.replicate 64 'a'

simpleCases :: [TestTree]
simpleCases =
  [ testCase "ledger show" $ parseArgs ["ledger", "show"] @?= Right LedgerShow
  , testCase "ledger needs a subcommand" $ parseArgs ["ledger"] @?= Left (MissingSubcommand "ledger")
  , testCase "ledger show takes no argument" $ parseArgs ["ledger", "show", "x"] @?= Left (UnexpectedArgument "x")
  , testCase "ticket create" $ parseArgs ["ticket", "create", "Fix login"] @?= Right (TicketCreate "Fix login")
  , testCase "ticket create needs a title" $ parseArgs ["ticket", "create"] @?= Left (MissingArgument "TITLE")
  , testCase "ticket accept" $
      parseArgs ["ticket", "accept", "T", "--expected-revision", "1"] @?= Right (TicketAccept "T" 1)
  , testCase "ticket accept, option first" $
      parseArgs ["ticket", "accept", "--expected-revision", "1", "T"] @?= Right (TicketAccept "T" 1)
  , testCase "ticket accept needs the revision" $
      parseArgs ["ticket", "accept", "T"] @?= Left (MissingOption "--expected-revision")
  , testCase "ticket accept needs a number" $
      parseArgs ["ticket", "accept", "T", "--expected-revision", "x"] @?= Left (InvalidNumber "--expected-revision" "x")
  , testCase "ticket accept needs the option's value" $
      parseArgs ["ticket", "accept", "T", "--expected-revision"] @?= Left (MissingOptionValue "--expected-revision")
  , testCase "ticket accept needs the ticket" $
      parseArgs ["ticket", "accept", "--expected-revision", "1"] @?= Left (MissingArgument "TICKET")
  , testCase "an unknown option" $
      parseArgs ["ticket", "accept", "T", "--expected-revision", "1", "--bogus", "x"] @?= Left (UnknownOption "--bogus")
  , testCase "schedule run-once" $ parseArgs ["schedule", "run-once"] @?= Right ScheduleRunOnce
  , testCase "sandbox show" $ parseArgs ["sandbox", "show"] @?= Right SandboxShow
  ]

orderCases :: [TestTree]
orderCases =
  [ testCase "work-order create with defaults" $
      parseArgs ["work-order", "create", "--ticket", "T", "--engineer", "alice", "--priority", "5", "--path-class", "source", "--path-class", "test", "--class", "c1"]
        @?= Right (WorkOrderCreate (WorkOrderArgs "T" "alice" 5 "engineering" ["c1"] ["source", "test"] Nothing))
  , testCase "work-order create with a kind and a rationale" $
      parseArgs ["work-order", "create", "--ticket", "T", "--engineer", "alice", "--priority", "0", "--kind", "investigation", "--non-behavioural", "docs only"]
        @?= Right (WorkOrderCreate (WorkOrderArgs "T" "alice" 0 "investigation" [] [] (Just "docs only")))
  , testCase "work-order create needs a priority" $
      parseArgs ["work-order", "create", "--ticket", "T", "--engineer", "alice"] @?= Left (MissingOption "--priority")
  , testCase "work-order create refuses a repeated ticket" $
      parseArgs ["work-order", "create", "--ticket", "T", "--ticket", "U", "--engineer", "alice", "--priority", "1"] @?= Left (DuplicateOption "--ticket")
  , testCase "work-order evidence" $
      parseArgs ["work-order", "evidence", "W", "--artifact", "impact-assessment", "--digest", hex, "--verifier", "human-inspection", "--verifier", "deterministic-command", "--approval", "supervisor"]
        @?= Right (WorkOrderEvidence (EvidenceArgs "W" "impact-assessment" hex ["human-inspection", "deterministic-command"] "supervisor"))
  , testCase "work-order evidence needs a verifier" $
      parseArgs ["work-order", "evidence", "W", "--artifact", "impact-assessment", "--digest", hex, "--approval", "none"] @?= Left (MissingOption "--verifier")
  , testCase "work-order halt" $
      parseArgs ["work-order", "halt", "W", "--expected-revision", "4", "--reason", "stop now"] @?= Right (WorkOrderHalt "W" 4 "stop now")
  , testCase "work-order requeue" $
      parseArgs ["work-order", "requeue", "W", "--expected-revision", "5"] @?= Right (WorkOrderRequeue "W" 5)
  , testCase "work-unit admit" $ parseArgs ["work-unit", "admit", "W"] @?= Right (WorkUnitAdmit "W" Nothing)
  , testCase "work-unit admit with a plan reference" $
      parseArgs ["work-unit", "admit", "W", "--plan-ref", "plan-7"] @?= Right (WorkUnitAdmit "W" (Just "plan-7"))
  ]

supervisorCases :: [TestTree]
supervisorCases =
  [ testCase "supervisor start with effects, in order" $
      parseArgs ["supervisor", "start", "W", "--expected-revision", "3", "--effect", "sandbox-repeatable", "--effect", "sandbox-unqueryable:hang"]
        @?= Right (SupervisorStart "W" 3 ["sandbox-repeatable", "sandbox-unqueryable:hang"])
  , testCase "supervisor start without effects" $
      parseArgs ["supervisor", "start", "W", "--expected-revision", "3"] @?= Right (SupervisorStart "W" 3 [])
  , testCase "supervisor execute-once defaults" $
      parseArgs ["supervisor", "execute-once"] @?= Right (SupervisorExecuteOnce (ExecuteArgs "supervisor" 60 30000))
  , testCase "supervisor execute-once options" $
      parseArgs ["supervisor", "execute-once", "--owner", "w2", "--lease-seconds", "5", "--timeout-ms", "1500"]
        @?= Right (SupervisorExecuteOnce (ExecuteArgs "w2" 5 1500))
  , testCase "supervisor reconcile-once" $ parseArgs ["supervisor", "reconcile-once"] @?= Right SupervisorReconcileOnce
  , testCase "supervisor needs a subcommand" $ parseArgs ["supervisor"] @?= Left (MissingSubcommand "supervisor")
  ]

effectCases :: [TestTree]
effectCases =
  [ testCase "effects resolve: attest applied" $
      parseArgs ["effects", "resolve", "OP", "--generation", "1", "--attest-applied", "saw it"] @?= Right (EffectsResolve "OP" 1 (ChooseAttestApplied "saw it"))
  , testCase "effects resolve: attest not applied" $
      parseArgs ["effects", "resolve", "OP", "--generation", "2", "--attest-not-applied", "nothing"] @?= Right (EffectsResolve "OP" 2 (ChooseAttestNotApplied "nothing"))
  , testCase "effects resolve: an acknowledged retry" $
      parseArgs ["effects", "resolve", "OP", "--generation", "1", "--retry", "--acknowledge-duplication-risk"] @?= Right (EffectsResolve "OP" 1 ChooseRetryAcknowledged)
  , testCase "effects resolve needs a choice" $
      parseArgs ["effects", "resolve", "OP", "--generation", "1"] @?= Left (MissingOption "--attest-applied")
  , testCase "effects resolve takes one choice" $
      parseArgs ["effects", "resolve", "OP", "--generation", "1", "--attest-applied", "a", "--attest-not-applied", "b"]
        @?= Left (ConflictingOptions "--attest-applied" "--attest-not-applied")
  , testCase "a retry needs the acknowledgement" $
      parseArgs ["effects", "resolve", "OP", "--generation", "1", "--retry"] @?= Left (MissingOption "--acknowledge-duplication-risk")
  , testCase "the acknowledgement belongs to a retry" $
      parseArgs ["effects", "resolve", "OP", "--generation", "1", "--attest-applied", "a", "--acknowledge-duplication-risk"]
        @?= Left (UnexpectedArgument "--acknowledge-duplication-risk")
  , testCase "effects resolve needs the generation" $
      parseArgs ["effects", "resolve", "OP", "--attest-applied", "a"] @?= Left (MissingOption "--generation")
  , testCase "effects abandon" $
      parseArgs ["effects", "abandon", "OP", "--reason", "operator stop"] @?= Right (EffectsAbandon "OP" "operator stop")
  ]
