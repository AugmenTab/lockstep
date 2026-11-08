{- | The documents of the candidate, its challenge and the freeze (contract
C-P4.7–9 S1–S3): how a candidate, a baseline result, a finding and the frozen
Contract are recorded, and how they are read back. The stages themselves are
in 'Lockstep.Application.Engine'.
-}
module Lockstep.Application.EngineCandidate
  ( recordedCandidate
  , candidateJson
  , testFiles
  , baselineJson
  , unchangedAtBasis
  , findingJson
  , frozenContract
  ) where

import Crypto.Hash (SHA256 (SHA256), hashWith)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude

import Lockstep.Application.EngineRecords
  ( Baseline (..)
  , ContractCriterion (..)
  , ContractRecord (..)
  , ContractTest (..)
  , FindingRecord (..)
  , baselineSchema
  , contractSchema
  , findingSchema
  , record
  )
import Lockstep.Effects.GitSupervisor (blobId)
import Lockstep.Effects.Roles (decodeAnswer, encodeCandidate)
import Lockstep.Foundation.Json (Json (JRaw))
import Lockstep.Kernel.Candidate (MutantRun (..))
import Lockstep.Kernel.GitBasis (TreeEntry (..))
import Lockstep.Kernel.Roles
  ( Candidate (..)
  , CandidateTest (..)
  , Criterion (..)
  , Finding (..)
  , RoleAnswer (..)
  , expectationName
  )
import Lockstep.Kernel.Transaction (BaselineClass, Disposition, baselineClassName, dispositionName)

-- | The candidate a record holds, read back through the answer decoder.
recordedCandidate :: T.Text -> Maybe Candidate
recordedCandidate body =
  case decodeAnswer (TE.encodeUtf8 body) of
    Right (AnswerCandidate c) -> Just c
    _ -> Nothing

-- | A candidate in its answer form, through the answer schema (so 'recordedCandidate' reads it back).
candidateJson :: Candidate -> Json
candidateJson =
  JRaw . encodeCandidate

-- | The files a candidate adds to a tree: its tests.
testFiles :: Candidate -> [(T.Text, BS.ByteString)]
testFiles c =
  [(testPath t, TE.encodeUtf8 (testContent t)) | t <- candidateTests c]

-- | One test's baseline result: its class and what the run showed.
baselineJson :: CandidateTest -> BaselineClass -> T.Text -> T.Text -> T.Text -> Json
baselineJson t cls outcome out err =
  record baselineSchema (Baseline (testPath t) (expectationName (testExpectation t)) (baselineClassName cls) outcome out err)

-- | The test is already in the basis with exactly these bytes (a pre-existing test).
unchangedAtBasis :: [TreeEntry] -> CandidateTest -> Bool
unchangedAtBasis entries t =
  L.any (\e -> entryPath e == testPath t && entryBlob e == blobId (TE.encodeUtf8 (testContent t))) entries

-- | A finding as the Supervisor disposed of it.
findingJson :: Finding -> Bool -> MutantRun -> Disposition -> Json
findingJson f grounded run disposition =
  record findingSchema (FindingRecord (findingRequirement f) (findingClaim f) (Just grounded) (mutantName run) (dispositionName disposition))

mutantName :: MutantRun -> T.Text
mutantName run =
  T.pack $
    case run of
      NoMutant -> "none"
      MutantOutsideScope -> "outside-scope"
      MutantKilled -> "killed"
      MutantSurvived True -> "survived-demonstrated"
      MutantSurvived False -> "survived-not-demonstrated"

{- | The frozen Contract: the basis, the freeze commit, the criteria, the allowed
implementation paths, the verification commands, and each test's path,
SHA-256 and command.
-}
frozenContract :: T.Text -> T.Text -> Candidate -> Json
frozenContract basis freeze c =
  record
    contractSchema
    ContractRecord
      { contractBasis = basis
      , contractFreeze = freeze
      , contractCriteria = [ContractCriterion (criterionId x) (criterionText x) | x <- candidateCriteria c]
      , contractAllowedPaths = candidateAllowedPaths c
      , contractVerification = candidateVerification c
      , contractTests = [ContractTest (testPath t) (sha256Text (testContent t)) (testArgv t) | t <- candidateTests c]
      }

sha256Text :: T.Text -> T.Text
sha256Text text =
  TE.decodeLatin1 (convertToBase Base16 (hashWith SHA256 (TE.encodeUtf8 text)))
