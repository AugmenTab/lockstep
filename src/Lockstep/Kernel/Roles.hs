{- | The roles' typed documents and their rules (contract C-P4.5 A1, A2). A
role's answer is data: every field that could widen what happens next
(a path, a command, a test, a list of files someone may change) is checked
here, and an answer that fails any rule is refused whole. Text a role writes
is kept as text and never acted on.
-}
module Lockstep.Kernel.Roles
  ( Role (..)
  , roleName
  , Citation (..)
  , Check (..)
  , Discovery (..)
  , Expectation (..)
  , expectationName
  , CandidateTest (..)
  , Criterion (..)
  , Candidate (..)
  , FileContent (..)
  , Finding (..)
  , FindingHint (..)
  , Challenge (..)
  , Implementation (..)
  , Verdict (..)
  , verdictName
  , Review (..)
  , RoleAnswer (..)
  , checkAnswer
  , textValid
  , criterionIdValid
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.GitBasis (treePathValid)

data Role
  = Planner
  | Challenger
  | Implementer
  | Reviewer
  deriving (Eq, Show)

roleName :: Role -> T.Text
roleName role =
  T.pack $
    case role of
      Planner -> "planner"
      Challenger -> "challenger"
      Implementer -> "implementer"
      Reviewer -> "reviewer"

-- | A place in the source at the basis: a path and an inclusive line range.
data Citation
  = Citation
  { citationPath :: T.Text
  , citationFirst :: Int
  , citationLast :: Int
  }
  deriving (Eq, Show)

-- | A command and the text its failing output must contain.
data Check
  = Check
  { checkArgv :: [T.Text]
  , checkSignature :: T.Text
  }
  deriving (Eq, Show)

-- | The Planner's first answer (P4.6).
data Discovery
  = Discovery
  { discoverySummary :: T.Text
  , discoveryHypothesis :: T.Text
  , discoveryCitations :: [Citation]
  , discoveryReproduction :: Maybe Check
  , discoveryAllowedPaths :: [T.Text]
  }
  deriving (Eq, Show)

data Expectation
  = ExpectRed
  | ExpectGreen
  deriving (Eq, Show, Enum, Bounded)

expectationName :: Expectation -> T.Text
expectationName expectation =
  T.pack $
    case expectation of
      ExpectRed -> "red"
      ExpectGreen -> "green"

data CandidateTest
  = CandidateTest
  { testPath :: T.Text
  , testContent :: T.Text
  , testExpectation :: Expectation
  , testArgv :: [T.Text]
  , testSignature :: Maybe T.Text
  }
  deriving (Eq, Show)

data Criterion
  = Criterion
  { criterionId :: T.Text
  , criterionText :: T.Text
  , criterionTicketQuote :: T.Text
  , criterionCitations :: [Citation]
  }
  deriving (Eq, Show)

-- | The Planner's Contract and candidate tests (P4.8).
data Candidate
  = Candidate
  { candidateCriteria :: [Criterion]
  , candidateAllowedPaths :: [T.Text]
  , candidateVerification :: [[T.Text]]
  , candidateTests :: [CandidateTest]
  }
  deriving (Eq, Show)

data FileContent
  = FileContent
  { filePath :: T.Text
  , fileText :: T.Text
  }
  deriving (Eq, Show)

data FindingHint
  = HintNone
  | HintNeedsHuman
  | HintInconclusive
  deriving (Eq, Show)

-- | One challenger finding (P4.7, P4.12).
data Finding
  = Finding
  { findingRequirement :: T.Text
  , findingClaim :: T.Text
  , findingBasis :: [Citation]
  , findingMutant :: [FileContent]
  , findingDemonstration :: Maybe Check
  , findingTest :: Maybe (FileContent, Check)
  , findingHint :: FindingHint
  }
  deriving (Eq, Show)

newtype Challenge
  = Challenge
  { challengeFindings :: [Finding]
  }
  deriving (Eq, Show)

-- | The Implementer's account; what it changed is observed, not claimed.
newtype Implementation
  = Implementation
  { implementationSummary :: T.Text
  }
  deriving (Eq, Show)

data Verdict
  = Approve
  | Reject
  | NeedsHuman
  deriving (Eq, Show, Enum, Bounded)

verdictName :: Verdict -> T.Text
verdictName verdict =
  T.pack $
    case verdict of
      Approve -> "approve"
      Reject -> "reject"
      NeedsHuman -> "needs-human"

data Review
  = Review
  { reviewVerdict :: Verdict
  , reviewReasons :: [T.Text]
  }
  deriving (Eq, Show)

data RoleAnswer
  = AnswerDiscovery Discovery
  | AnswerCandidate Candidate
  | AnswerChallenge Challenge
  | AnswerImplementation Implementation
  | AnswerReview Review
  deriving (Eq, Show)

-- | 1–4000 characters, not only spaces; new lines and tabs, no other control character.
textValid :: T.Text -> Bool
textValid text =
  not (T.null (T.strip text))
    && T.length text <= 4000
    && not (T.any (\c -> Char.isControl c && c /= '\n' && c /= '\t') text)

criterionIdValid :: T.Text -> Bool
criterionIdValid text =
  case T.uncons text of
    Just (c, rest) ->
      Char.isAsciiLower c
        && T.length rest <= 39
        && T.all (\x -> Char.isAsciiLower x || Char.isDigit x || x == '-') rest
    Nothing -> False

signatureValid :: T.Text -> Bool
signatureValid text =
  not (T.null text) && T.length text <= 200 && T.all (\c -> c >= ' ' && c <= '~') text

argvValid :: [T.Text] -> Bool
argvValid argv =
  not (L.null argv)
    && L.length argv <= 64
    && L.all (\a -> T.length a <= 4096 && not (T.any (== '\NUL') a)) argv
    && not (L.any T.null (L.take 1 argv))

citationValid :: Citation -> Bool
citationValid c =
  treePathValid (citationPath c)
    && citationFirst c >= 1
    && citationLast c >= citationFirst c
    && citationLast c - citationFirst c <= 200

checkValid :: Check -> Bool
checkValid c =
  argvValid (checkArgv c) && signatureValid (checkSignature c)

pathsValid :: Int -> [T.Text] -> Bool
pathsValid most paths =
  not (L.null paths) && L.length paths <= most && L.all treePathValid paths && L.nub paths == paths

contentValid :: T.Text -> Bool
contentValid text =
  T.length text <= 262144 && not (T.any (== '\NUL') text)

{- | A2: the rules each answer must meet, with the first failing rule's code.
The role that was asked must be the role that answered (@wrong-kind@).
-}
checkAnswer :: Role -> RoleAnswer -> Either T.Text RoleAnswer
checkAnswer role answer =
  case (role, answer) of
    (Planner, AnswerDiscovery d) -> answer <$ discovery d
    (Planner, AnswerCandidate c) -> answer <$ candidate c
    (Challenger, AnswerChallenge c) -> answer <$ challenge c
    (Implementer, AnswerImplementation i) -> answer <$ rule "summary-invalid" (textValid (implementationSummary i))
    (Reviewer, AnswerReview r) -> answer <$ review r
    _ -> Left (T.pack "wrong-kind")
 where
  rule code ok =
    if ok then Right () else Left (T.pack code)
  discovery d = do
    rule "summary-invalid" (textValid (discoverySummary d) && textValid (discoveryHypothesis d))
    rule "citations-invalid" (not (L.null (discoveryCitations d)) && L.length (discoveryCitations d) <= 50 && L.all citationValid (discoveryCitations d))
    rule "reproduction-invalid" (maybe True checkValid (discoveryReproduction d))
    rule "paths-invalid" (pathsValid 50 (discoveryAllowedPaths d))
  candidate c = do
    let
      criteria = candidateCriteria c
      ids = fmap criterionId criteria
      tests = candidateTests c
      testPaths = fmap testPath tests
    rule "criteria-invalid" $
      not (L.null criteria)
        && L.length criteria <= 30
        && L.all criterionIdValid ids
        && L.nub ids == ids
        && L.all (\x -> textValid (criterionText x) && textValid (criterionTicketQuote x)) criteria
        && L.all (\x -> not (L.null (criterionCitations x)) && L.length (criterionCitations x) <= 20 && L.all citationValid (criterionCitations x)) criteria
    rule "paths-invalid" (pathsValid 50 (candidateAllowedPaths c))
    rule "verification-invalid" (not (L.null (candidateVerification c)) && L.length (candidateVerification c) <= 10 && L.all argvValid (candidateVerification c))
    rule "tests-invalid" $
      not (L.null tests)
        && L.length tests <= 20
        && pathsValid 20 testPaths
        && L.all (\t -> contentValid (testContent t) && argvValid (testArgv t) && maybe True signatureValid (testSignature t)) tests
    rule "red-without-signature" (L.all (\t -> testExpectation t /= ExpectRed || isJust (testSignature t)) tests)
    rule "tests-overlap-allowed" (L.all (`L.notElem` candidateAllowedPaths c) testPaths)
  challenge c = do
    let
      findings = challengeFindings c
    rule "findings-invalid" (L.length findings <= 20)
    traverse_ finding findings
  finding f = do
    rule "requirement-invalid" (criterionIdValid (findingRequirement f))
    rule "claim-invalid" (textValid (findingClaim f))
    rule "basis-invalid" (not (L.null (findingBasis f)) && L.length (findingBasis f) <= 20 && L.all citationValid (findingBasis f))
    rule "mutant-invalid" $
      L.length (findingMutant f) <= 10
        && L.all (\m -> treePathValid (filePath m) && contentValid (fileText m)) (findingMutant f)
        && L.nub (fmap filePath (findingMutant f)) == fmap filePath (findingMutant f)
    rule "demonstration-invalid" (maybe True checkValid (findingDemonstration f))
    rule "test-invalid" (maybe True (\(t, k) -> treePathValid (filePath t) && contentValid (fileText t) && checkValid k) (findingTest f))
  review r = do
    rule "reasons-invalid" (not (L.null (reviewReasons r)) && L.length (reviewReasons r) <= 20 && L.all textValid (reviewReasons r))
