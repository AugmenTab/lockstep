{- | The records of a coding transaction (contract C-P4.6 T5): one json-fleece
schema per record kind, used both to write a record and to read it back.

Each schema keeps the field names and order the records were written with
before, so a record's bytes (and its @body_digest@) are what the hand-built
JSON tree gave for the same values (checked by the lockstep-compliance suite).
The discovery and candidate records are written through the role-answer
schemas of "Lockstep.Effects.Roles" ('encodeDiscovery', 'encodeCandidate'),
which is how they are read.

Fields that the readers before this did not need (a finding's @grounded@, a
review's @invocation@) are optional when reading and always written.
-}
module Lockstep.Application.EngineRecords
  ( record
  , argvText
  , Started (..)
  , startedSchema
  , Halt (..)
  , haltSchema
  , InputRecord (..)
  , inputSchema
  , Resume (..)
  , resumeSchema
  , Completion (..)
  , completionSchema
  , Unfinished (..)
  , unfinishedSchema
  , Refusal (..)
  , refusalSchema
  , BasisRecord (..)
  , basisSchema
  , Reproduction (..)
  , reproductionSchema
  , Baseline (..)
  , baselineSchema
  , FindingRecord (..)
  , findingSchema
  , FreezeRecord (..)
  , freezeSchema
  , ContractRecord (..)
  , ContractCriterion (..)
  , ContractTest (..)
  , contractSchema
  , ImplementationRefused (..)
  , implementationRefusedSchema
  , ImplementationRecord (..)
  , implementationSchema
  , VerificationRun (..)
  , verificationSchema
  , VerificationSummary (..)
  , verificationSummarySchema
  , ReviewRecord (..)
  , reviewSchema
  , AcceptanceRecord (..)
  , acceptanceSchema
  ) where

import Data.Text qualified as T
import Fleece.Aeson qualified as FA
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude

import Lockstep.Foundation.Fleece (encodeText, nullableOf)
import Lockstep.Foundation.Json (Json (JRaw))

{- | A record body for the transaction's records: the document its schema
writes, kept as it is ('JRaw'), so a role's context can carry it verbatim.
-}
record :: FC.Schema FA.Encoder a -> a -> Json
record schema =
  JRaw . encodeText schema

-- | An invocation's argument vector, as stored with it: a JSON list of strings.
argvText :: [T.Text] -> T.Text
argvText =
  encodeText (FC.list FC.text)

-- | @started@: the transaction began for a Work Order.
data Started
  = Started
  { startedWorkOrder :: T.Text
  , startedEngineer :: T.Text
  , startedFolder :: T.Text
  }

startedSchema :: FC.Fleece t => FC.Schema t Started
startedSchema =
  FC.object $
    FC.constructor Started
      #+ FC.required "work_order" startedWorkOrder FC.text
      #+ FC.required "engineer" startedEngineer FC.text
      #+ FC.required "folder" startedFolder FC.text

-- | @halt@: the stage the transaction halted at and why.
data Halt
  = Halt
  { haltStage :: T.Text
  , haltCode :: T.Text
  }

haltSchema :: FC.Fleece t => FC.Schema t Halt
haltSchema =
  FC.object $
    FC.constructor Halt
      #+ FC.required "stage" haltStage FC.text
      #+ FC.required "code" haltCode FC.text

-- | @input@: the input applied and the state it led to.
data InputRecord
  = InputRecord
  { inputName :: T.Text
  , inputState :: T.Text
  }

inputSchema :: FC.Fleece t => FC.Schema t InputRecord
inputSchema =
  FC.object $
    FC.constructor InputRecord
      #+ FC.required "input" inputName FC.text
      #+ FC.required "state" inputState FC.text

-- | @resume@: a person's answer to a halt's request.
data Resume
  = Resume
  { resumeRequest :: T.Text
  , resumeChoice :: T.Text
  , resumeRevision :: Integer
  }

resumeSchema :: FC.Fleece t => FC.Schema t Resume
resumeSchema =
  FC.object $
    FC.constructor Resume
      #+ FC.required "request" resumeRequest FC.text
      #+ FC.required "choice" resumeChoice FC.text
      #+ FC.required "revision" resumeRevision FC.integer

-- | @completion@: a person's Done or not-done.
data Completion
  = Completion
  { completionChoice :: T.Text
  , completionChannel :: T.Text
  , completionEvidence :: T.Text
  }

completionSchema :: FC.Fleece t => FC.Schema t Completion
completionSchema =
  FC.object $
    FC.constructor Completion
      #+ FC.required "choice" completionChoice FC.text
      #+ FC.required "channel" completionChannel FC.text
      #+ FC.required "evidence" completionEvidence FC.text

-- | The role invocations found unfinished.
newtype Unfinished
  = Unfinished
  { unfinishedInvocations :: [T.Text]
  }

unfinishedSchema :: FC.Fleece t => FC.Schema t Unfinished
unfinishedSchema =
  FC.object $
    FC.constructor Unfinished
      #+ FC.required "invocations" unfinishedInvocations (FC.list FC.text)

-- | @basis-refused@, @candidate-rejected@: a refusal code alone.
newtype Refusal
  = Refusal
  { refusalCode :: T.Text
  }

refusalSchema :: FC.Fleece t => FC.Schema t Refusal
refusalSchema =
  FC.object $
    FC.constructor Refusal
      #+ FC.required "code" refusalCode FC.text

-- | @basis@: the commit, its tree and the Work Order's branch.
data BasisRecord
  = BasisRecord
  { basisCommit :: T.Text
  , basisTree :: T.Text
  , basisBranch :: T.Text
  }

basisSchema :: FC.Fleece t => FC.Schema t BasisRecord
basisSchema =
  FC.object $
    FC.constructor BasisRecord
      #+ FC.required "commit" basisCommit FC.text
      #+ FC.required "tree" basisTree FC.text
      #+ FC.required "branch" basisBranch FC.text

{- | @reproduction@: either no command (@{"command":null,"reproduced":false}@)
or the command's run: every field present, @exit@ @null@ when the command did
not exit.
-}
data Reproduction
  = Reproduction
  { reproductionCommand :: Maybe [T.Text]
  , reproductionSignature :: Maybe T.Text
  , reproductionOutcome :: Maybe T.Text
  , reproductionExit :: Maybe (Maybe Integer)
  , reproductionReproduced :: Bool
  , reproductionStdout :: Maybe T.Text
  , reproductionStderr :: Maybe T.Text
  , reproductionInvocation :: Maybe T.Text
  }

reproductionSchema :: FC.Fleece t => FC.Schema t Reproduction
reproductionSchema =
  FC.object $
    FC.constructor Reproduction
      #+ FC.required "command" reproductionCommand (nullableOf (FC.list FC.text))
      #+ FC.optional "signature" reproductionSignature FC.text
      #+ FC.optional "outcome" reproductionOutcome FC.text
      #+ FC.optional "exit" reproductionExit (nullableOf FC.integer)
      #+ FC.required "reproduced" reproductionReproduced FC.boolean
      #+ FC.optional "stdout_tail" reproductionStdout FC.text
      #+ FC.optional "stderr_tail" reproductionStderr FC.text
      #+ FC.optional "invocation" reproductionInvocation FC.text

-- | @baseline@: one candidate test's run at the basis and its class.
data Baseline
  = Baseline
  { baselinePath :: T.Text
  , baselineExpect :: T.Text
  , baselineClass :: T.Text
  , baselineOutcome :: T.Text
  , baselineStdout :: T.Text
  , baselineStderr :: T.Text
  }

baselineSchema :: FC.Fleece t => FC.Schema t Baseline
baselineSchema =
  FC.object $
    FC.constructor Baseline
      #+ FC.required "path" baselinePath FC.text
      #+ FC.required "expect" baselineExpect FC.text
      #+ FC.required "class" baselineClass FC.text
      #+ FC.required "outcome" baselineOutcome FC.text
      #+ FC.required "stdout_tail" baselineStdout FC.text
      #+ FC.required "stderr_tail" baselineStderr FC.text

-- | @finding@, @post-finding@: a finding as the Supervisor disposed of it.
data FindingRecord
  = FindingRecord
  { findingRecordRequirement :: T.Text
  , findingRecordClaim :: T.Text
  , findingRecordGrounded :: Maybe Bool
  , findingRecordMutant :: T.Text
  , findingRecordDisposition :: T.Text
  }

findingSchema :: FC.Fleece t => FC.Schema t FindingRecord
findingSchema =
  FC.object $
    FC.constructor FindingRecord
      #+ FC.required "requirement" findingRecordRequirement FC.text
      #+ FC.required "claim" findingRecordClaim FC.text
      #+ FC.optional "grounded" findingRecordGrounded FC.boolean
      #+ FC.required "mutant" findingRecordMutant FC.text
      #+ FC.required "disposition" findingRecordDisposition FC.text

-- | @freeze@: the freeze commit, its branch and the Contract's digest.
data FreezeRecord
  = FreezeRecord
  { freezeCommit :: T.Text
  , freezeBranch :: T.Text
  , freezeContractDigest :: T.Text
  }

freezeSchema :: FC.Fleece t => FC.Schema t FreezeRecord
freezeSchema =
  FC.object $
    FC.constructor FreezeRecord
      #+ FC.required "commit" freezeCommit FC.text
      #+ FC.required "branch" freezeBranch FC.text
      #+ FC.required "contract_digest" freezeContractDigest FC.text

{- | @contract@: the frozen Contract (C-P4.7-9 S3). Its exact bytes are what
@contract_digest@ is the SHA-256 of.
-}
data ContractRecord
  = ContractRecord
  { contractBasis :: T.Text
  , contractFreeze :: T.Text
  , contractCriteria :: [ContractCriterion]
  , contractAllowedPaths :: [T.Text]
  , contractVerification :: [[T.Text]]
  , contractTests :: [ContractTest]
  }

data ContractCriterion
  = ContractCriterion
  { contractCriterionId :: T.Text
  , contractCriterionText :: T.Text
  }

data ContractTest
  = ContractTest
  { contractTestPath :: T.Text
  , contractTestSha256 :: T.Text
  , contractTestArgv :: [T.Text]
  }

contractSchema :: FC.Fleece t => FC.Schema t ContractRecord
contractSchema =
  FC.object $
    FC.constructor ContractRecord
      #+ FC.required "basis" contractBasis FC.text
      #+ FC.required "freeze" contractFreeze FC.text
      #+ FC.required "criteria" contractCriteria (FC.list contractCriterionSchema)
      #+ FC.required "allowed_paths" contractAllowedPaths (FC.list FC.text)
      #+ FC.required "verification" contractVerification (FC.list (FC.list FC.text))
      #+ FC.required "tests" contractTests (FC.list contractTestSchema)

contractCriterionSchema :: FC.Fleece t => FC.Schema t ContractCriterion
contractCriterionSchema =
  FC.object $
    FC.constructor ContractCriterion
      #+ FC.required "id" contractCriterionId FC.text
      #+ FC.required "text" contractCriterionText FC.text

contractTestSchema :: FC.Fleece t => FC.Schema t ContractTest
contractTestSchema =
  FC.object $
    FC.constructor ContractTest
      #+ FC.required "path" contractTestPath FC.text
      #+ FC.required "sha256" contractTestSha256 FC.text
      #+ FC.required "argv" contractTestArgv (FC.list FC.text)

-- | @implementation-refused@: why an attempt was refused, the paths, the invocation.
data ImplementationRefused
  = ImplementationRefused
  { refusedCode :: T.Text
  , refusedPaths :: [T.Text]
  , refusedInvocation :: T.Text
  }

implementationRefusedSchema :: FC.Fleece t => FC.Schema t ImplementationRefused
implementationRefusedSchema =
  FC.object $
    FC.constructor ImplementationRefused
      #+ FC.required "code" refusedCode FC.text
      #+ FC.required "paths" refusedPaths (FC.list FC.text)
      #+ FC.required "invocation" refusedInvocation FC.text

-- | @implementation@: the Implementer's summary and the candidate commit made from its change.
data ImplementationRecord
  = ImplementationRecord
  { implementationSummary :: T.Text
  , implementationChanged :: [T.Text]
  , implementationCandidate :: T.Text
  , implementationAttempt :: Integer
  , implementationInvocation :: T.Text
  }

implementationSchema :: FC.Fleece t => FC.Schema t ImplementationRecord
implementationSchema =
  FC.object $
    FC.constructor ImplementationRecord
      #+ FC.required "summary" implementationSummary FC.text
      #+ FC.required "changed" implementationChanged (FC.list FC.text)
      #+ FC.required "candidate" implementationCandidate FC.text
      #+ FC.required "attempt" implementationAttempt FC.integer
      #+ FC.required "invocation" implementationInvocation FC.text

-- | @verification@: one command run on the candidate commit; @exit@ only when it exited.
data VerificationRun
  = VerificationRun
  { runCommand :: [T.Text]
  , runOutcome :: T.Text
  , runExit :: Maybe Integer
  , runStdout :: T.Text
  , runStderr :: T.Text
  }

verificationSchema :: FC.Fleece t => FC.Schema t VerificationRun
verificationSchema =
  FC.object $
    FC.constructor VerificationRun
      #+ FC.required "command" runCommand (FC.list FC.text)
      #+ FC.required "outcome" runOutcome FC.text
      #+ FC.optional "exit" runExit FC.integer
      #+ FC.required "stdout_tail" runStdout FC.text
      #+ FC.required "stderr_tail" runStderr FC.text

-- | @verification-summary@: the commit verified and whether every command passed.
data VerificationSummary
  = VerificationSummary
  { summaryCommit :: T.Text
  , summaryPassed :: Bool
  }

verificationSummarySchema :: FC.Fleece t => FC.Schema t VerificationSummary
verificationSummarySchema =
  FC.object $
    FC.constructor VerificationSummary
      #+ FC.required "commit" summaryCommit FC.text
      #+ FC.required "passed" summaryPassed FC.boolean

-- | @review@: the Reviewer's verdict on a commit, its reasons and the invocation.
data ReviewRecord
  = ReviewRecord
  { reviewCommit :: T.Text
  , reviewVerdict :: T.Text
  , reviewReasons :: [T.Text]
  , reviewInvocation :: Maybe T.Text
  }

reviewSchema :: FC.Fleece t => FC.Schema t ReviewRecord
reviewSchema =
  FC.object $
    FC.constructor ReviewRecord
      #+ FC.required "commit" reviewCommit FC.text
      #+ FC.required "verdict" reviewVerdict FC.text
      #+ FC.required "reasons" reviewReasons (FC.list FC.text)
      #+ FC.optional "invocation" reviewInvocation FC.text

-- | @acceptance@: the accepted commit, the branch it was put on, and the commit it moved from.
data AcceptanceRecord
  = AcceptanceRecord
  { acceptanceCommit :: T.Text
  , acceptanceBranch :: T.Text
  , acceptanceFrom :: T.Text
  }

acceptanceSchema :: FC.Fleece t => FC.Schema t AcceptanceRecord
acceptanceSchema =
  FC.object $
    FC.constructor AcceptanceRecord
      #+ FC.required "commit" acceptanceCommit FC.text
      #+ FC.required "branch" acceptanceBranch FC.text
      #+ FC.required "from" acceptanceFrom FC.text
