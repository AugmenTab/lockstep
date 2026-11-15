{- | The evidence-linked summary of a project (contract C-P6.8 E1–E6): which
category each task is in, the outcomes of its fix's verification and review
as recorded (never assumed), the evidence each claim rests on, whether a
person's intervention was necessary or avoidable, the token usage helpers
reported, and whether a summary still describes the plan in effect. Pure: the
application reads the records.
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

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Task (TaskReadiness (..))

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
categoryCode c =
  T.pack $
    case c of
      CategoryPlanned -> "planned"
      CategoryEligible -> "eligible"
      CategoryActive -> "active"
      CategoryAwaitingPerson -> "awaiting-person"
      CategoryVerified -> "verified"
      CategoryDone -> "done"
      CategoryInvalidated -> "invalidated"
      CategoryUncertain -> "uncertain"
      CategoryStopped -> "stopped"
      CategoryCanceled -> "canceled"
      CategoryWaiting -> "waiting"

-- | E2: a fix's verification, as its latest record says; none is not-run, never passed.
data Checks
  = ChecksPassed
  | ChecksFailed
  | ChecksNotRun
  deriving (Eq, Show, Enum, Bounded)

checksCode :: Checks -> T.Text
checksCode c =
  T.pack $
    case c of
      ChecksPassed -> "passed"
      ChecksFailed -> "failed"
      ChecksNotRun -> "not-run"

-- | E2: a fix's review, as its latest record says; none, or one that needs a person, is never approved.
data ReviewOutcome
  = ReviewSaidApprove
  | ReviewSaidReject
  | ReviewSaidNeedsPerson
  | ReviewNotRun
  deriving (Eq, Show, Enum, Bounded)

reviewOutcomeCode :: ReviewOutcome -> T.Text
reviewOutcomeCode r =
  T.pack $
    case r of
      ReviewSaidApprove -> "approved"
      ReviewSaidReject -> "rejected"
      ReviewSaidNeedsPerson -> "needs-person"
      ReviewNotRun -> "not-run"

-- | E3: a canonical row or commit a claim rests on.
data Evidence
  = OfFix T.Text
  | -- | A record of a fix: the fix and the record's sequence.
    OfRecord T.Text Int
  | OfCommit T.Text
  | -- | The fix whose invalidation it is.
    OfInvalidation T.Text
  | OfRequest T.Text
  deriving (Eq, Show)

evidenceCode :: Evidence -> T.Text
evidenceCode e =
  T.pack $
    case e of
      OfFix _ -> "fix"
      OfRecord _ _ -> "record"
      OfCommit _ -> "commit"
      OfInvalidation _ -> "invalidation"
      OfRequest _ -> "request"

-- | A task's latest fix, as its records say.
data FixSummary
  = FixSummary
  { fixId :: T.Text
  , fixState :: T.Text
  -- ^ The state's name: running, halted, accepted, done or stopped.
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
  -- ^ A unit of the plan in effect.
  , itemReadiness :: TaskReadiness
  , itemFix :: Maybe FixSummary
  }
  deriving (Eq, Show)

-- | E1: the one category a task is in.
categoryOf :: ItemFacts -> Category
categoryOf item =
  case itemFix item of
    Just f
      | state == "done" -> CategoryDone
      | state == "stopped" -> CategoryStopped
      | fixInvalidated f -> CategoryInvalidated
      | state == "halted" && maybe False (T.isPrefixOf (T.pack "uncertain-invocation ")) (fixHalt f) -> CategoryUncertain
      | state == "halted" -> CategoryAwaitingPerson
      | state == "running" -> CategoryActive
      | state == "accepted" -> CategoryVerified
      | otherwise -> CategoryWaiting
     where
      state = T.unpack (fixState f)
    Nothing ->
      case itemReadiness item of
        TaskCanceled -> CategoryCanceled
        Finished -> CategoryDone
        ReadyToWork -> CategoryEligible
        _
          | itemPlanned item -> CategoryPlanned
          | otherwise -> CategoryWaiting

data Intervention
  = NecessaryIntervention
  | AvoidableIntervention
  | UnclassifiedIntervention
  deriving (Eq, Show, Enum, Bounded)

interventionCode :: Intervention -> T.Text
interventionCode i =
  T.pack $
    case i of
      NecessaryIntervention -> "necessary"
      AvoidableIntervention -> "avoidable"
      UnclassifiedIntervention -> "unclassified"

{- | E4: a person's answer to a halt (by its code), or their Done or Not done
(@done@, @not-done@): necessary when only a person may decide it, avoidable when
the environment or a role failed; anything else unclassified, never guessed.
-}
interventionOf :: T.Text -> Intervention
interventionOf code
  | code `L.elem` necessary = NecessaryIntervention
  | code `L.elem` avoidable || L.any (`T.isPrefixOf` code) avoidablePrefixes = AvoidableIntervention
  | otherwise = UnclassifiedIntervention
 where
  necessary =
    fmap
      T.pack
      [ "done"
      , "not-done"
      , "reproduction-missing"
      , "review-needs-human"
      , "finding-needs-human"
      , "attempts-exhausted"
      , "candidates-exhausted"
      , "green-regression-failed"
      , "protected-test-changed"
      , "ancestor-rejected"
      , "plan-changed"
      , "basis-stale"
      , "basis-ambiguous"
      , "prerequisite-unsatisfied"
      , "supervisor-failed behaviour-in-documentation"
      ]
  avoidable =
    fmap T.pack ["verification-environment-missing", "verification-run-failed", "baseline-run-failed", "repository-dirty", "repository-missing", "not-a-repository"]
  avoidablePrefixes = fmap T.pack ["role-failed ", "uncertain-invocation ", "supervisor-failed "]

-- | E5: token counts a helper reported, per class; Nothing is unknown, never zero.
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

-- | Totals of the known counts, class by class; a class no run reported stays unknown.
addUsage :: Usage -> Usage -> Usage
addUsage a b =
  Usage
    { usageInput = plus (usageInput a) (usageInput b)
    , usageOutput = plus (usageOutput a) (usageOutput b)
    , usageCacheCreation = plus (usageCacheCreation a) (usageCacheCreation b)
    , usageCacheRead = plus (usageCacheRead a) (usageCacheRead b)
    }
 where
  plus x y =
    case (x, y) of
      (Just m, Just n) -> Just (m + n)
      (Just m, Nothing) -> Just m
      (Nothing, Just n) -> Just n
      (Nothing, Nothing) -> Nothing

-- | Whether any class is known.
usageKnown :: Usage -> Bool
usageKnown u =
  u /= noUsage

-- | E6: a summary made for one revision (its digest, if any) is stale once another is in effect.
summaryStale :: Maybe T.Text -> Maybe T.Text -> Bool
summaryStale madeFor inEffect =
  madeFor /= inEffect
