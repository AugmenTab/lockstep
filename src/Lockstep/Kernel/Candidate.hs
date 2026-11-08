{- | The rules of candidate tests and their challenge (contract C-P4.7–9 K1–K4;
DG-06 D-6.1–D-6.3 as clarified, DG-07 D-7.2–D-7.3 as clarified). Pure: how a
test's run at the basis is classified, when a criterion is grounded in the
Ticket, and what a challenger's finding is, from what the Supervisor
observed — never from what a role claimed.
-}
module Lockstep.Kernel.Candidate
  ( classifyTest
  , testStem
  , quoteGrounded
  , MutantRun (..)
  , disposeFinding
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Roles (Expectation (..), FindingHint (..))
import Lockstep.Kernel.Runner (RunOutcome (..))
import Lockstep.Kernel.Transaction (BaselineClass (..), Disposition (..))

{- | The name a test's output carries: the file name without its directory or
extension (@tests/test_discount.py@ → @test_discount@).
-}
testStem :: T.Text -> T.Text
testStem path =
  let
    name =
      case L.reverse (T.splitOn (T.pack "/") path) of
        n : _ -> n
        [] -> path
  in
    case T.breakOnEnd (T.pack ".") name of
      (before, _) | T.length before > 1 -> T.dropEnd 1 before
      _ -> name

{- | K1 (D-6.1 as clarified): a RED test must fail — not with the shell's 126
or 127 — and show both its signature and its own name; passing is
@red-unexpectedly-passed@, failing otherwise @red-wrong-reason@. A GREEN test
must pass, else @green-candidate-failed@ (a defective new fixture, never
relabelled RED). A run that timed out, printed too much, was cut off or did
not launch is @run-failed@ whatever it expected.
-}
classifyTest :: Expectation -> T.Text -> Maybe T.Text -> RunOutcome -> T.Text -> T.Text -> BaselineClass
classifyTest expectation path signature outcome out err =
  case outcome of
    Exited code ->
      case expectation of
        ExpectGreen
          | code == 0 -> GreenConfirmed
          | otherwise -> GreenCandidateFailed
        ExpectRed
          | code == 0 -> RedUnexpectedlyPassed
          | code == 126 || code == 127 -> RedWrongReason
          | maybe False shown signature && shown (testStem path) -> RedConfirmed
          | otherwise -> RedWrongReason
    _ -> RunFailed
 where
  shown text =
    not (T.null text) && (text `T.isInfixOf` out || text `T.isInfixOf` err)

{- | K2 (D-6.3): a criterion's quote is grounded when it appears in the Ticket
(its title or what done looks like), ignoring letter case and runs of white
space.
-}
quoteGrounded :: [T.Text] -> T.Text -> Bool
quoteGrounded ticket quote =
  let
    norm = T.unwords . T.words . T.toLower
    q = norm quote
  in
    not (T.null q) && L.any ((q `T.isInfixOf`) . norm) ticket

-- | What the Supervisor saw when it ran a finding's mutant.
data MutantRun
  = NoMutant
  | -- | the mutant changes a path that is not an allowed implementation path
    MutantOutsideScope
  | -- | at least one candidate test failed on the mutant
    MutantKilled
  | -- | every candidate test passed; the flag: its demonstration failed on the mutant with its signature
    MutantSurvived Bool
  deriving (Eq, Show)

{- | K3 (DG-07 as clarified): @CONFIRMED@ needs both a surviving mutant (or a
failing counterexample) and a demonstration grounded in a named requirement;
a killed mutant is @DISPROVED@; anything else is @NEEDS_HUMAN@ when the
challenger asked for a person, otherwise @INCONCLUSIVE@. A challenger's word
alone never confirms or disproves anything.
-}
disposeFinding :: Bool -> MutantRun -> FindingHint -> Disposition
disposeFinding grounded run hint =
  case run of
    MutantKilled -> Disproved
    MutantSurvived True | grounded -> Confirmed
    _ ->
      case hint of
        HintNeedsHuman -> NeedsHumanFinding
        _ -> Inconclusive
