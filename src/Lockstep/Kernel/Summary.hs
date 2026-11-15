{- | The evidence-linked summary of a project (contract C-P6.8 E1–E6). Stub
(the freeze's RED baseline).
-}
module Lockstep.Kernel.Summary
  ( Category (..)
  , categoryCode
  , Checks (..)
  , checksCode
  , ReviewOutcome (..)
  , reviewOutcomeCode
  , Evidence (..)
  , evidenceCode
  , FixSummary (..)
  , ItemFacts (..)
  , categoryOf
  , Intervention (..)
  , interventionCode
  , interventionOf
  , Usage (..)
  , noUsage
  , addUsage
  , usageKnown
  , summaryStale
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Task (TaskReadiness)

data Category
  = CategoryPlanned
  | CategoryEligible
  | CategoryActive
  | CategoryAwaitingPerson
  | CategoryVerified
  | CategoryDone
  | CategoryInvalidated
  | CategoryUncertain
  | CategoryStopped
  | CategoryCanceled
  | CategoryWaiting
  deriving (Eq, Show, Enum, Bounded)

categoryCode :: Category -> T.Text
categoryCode _ =
  T.empty

data Checks
  = ChecksPassed
  | ChecksFailed
  | ChecksNotRun
  deriving (Eq, Show, Enum, Bounded)

checksCode :: Checks -> T.Text
checksCode _ =
  T.empty

data ReviewOutcome
  = ReviewSaidApprove
  | ReviewSaidReject
  | ReviewSaidNeedsPerson
  | ReviewNotRun
  deriving (Eq, Show, Enum, Bounded)

reviewOutcomeCode :: ReviewOutcome -> T.Text
reviewOutcomeCode _ =
  T.empty

data Evidence
  = OfFix T.Text
  | OfRecord T.Text Int
  | OfCommit T.Text
  | OfInvalidation T.Text
  | OfRequest T.Text
  deriving (Eq, Show)

evidenceCode :: Evidence -> T.Text
evidenceCode _ =
  T.empty

data FixSummary
  = FixSummary
  { fixId :: T.Text
  , fixState :: T.Text
  , fixHalt :: Maybe T.Text
  , fixInvalidated :: Bool
  , fixChecks :: Checks
  , fixChecksRecord :: Maybe Int
  , fixReview :: ReviewOutcome
  , fixReviewRecord :: Maybe Int
  , fixCommit :: Maybe T.Text
  }
  deriving (Eq, Show)

data ItemFacts
  = ItemFacts
  { itemPlanned :: Bool
  , itemReadiness :: TaskReadiness
  , itemFix :: Maybe FixSummary
  }
  deriving (Eq, Show)

categoryOf :: ItemFacts -> Category
categoryOf _ =
  CategoryWaiting

data Intervention
  = NecessaryIntervention
  | AvoidableIntervention
  | UnclassifiedIntervention
  deriving (Eq, Show, Enum, Bounded)

interventionCode :: Intervention -> T.Text
interventionCode _ =
  T.empty

interventionOf :: T.Text -> Intervention
interventionOf _ =
  UnclassifiedIntervention

data Usage
  = Usage
  { usageInput :: Maybe Integer
  , usageOutput :: Maybe Integer
  , usageCacheCreation :: Maybe Integer
  , usageCacheRead :: Maybe Integer
  }
  deriving (Eq, Show)

noUsage :: Usage
noUsage =
  Usage Nothing Nothing Nothing Nothing

addUsage :: Usage -> Usage -> Usage
addUsage _ _ =
  noUsage

usageKnown :: Usage -> Bool
usageKnown _ =
  False

summaryStale :: Maybe T.Text -> Maybe T.Text -> Bool
summaryStale _ _ =
  False
