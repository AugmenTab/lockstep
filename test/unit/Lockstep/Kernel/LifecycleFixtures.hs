{-# LANGUAGE OverloadedStrings #-}

{- | Shared fixtures for the C-P2.2 lifecycle tests. Evidence is obtained only
the legitimate way, by running the lifecycles: an AcceptedWorkUnit comes from
an Accepted Work Unit and IntegrationEvidence from an Integrated Delivery.
-}
module Lockstep.Kernel.LifecycleFixtures
  ( Fixtures (..)
  , fixtures
  , withFixtures
  , commitA
  , commitB
  , admitted
  , engineerA
  , engineerB
  , claimA
  , claimB
  , attempt
  , passing
  , verificationWith
  , Expect (..)
  , Row (..)
  , row
  , rows
  , exhaustive
  , allPrincipals
  ) where

import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty.HUnit (Assertion, assertFailure)
import Text.Show (Show, show)

import Lockstep.Kernel.Delivery (DeliveryInput (..), DeliveryMode (..), IntegrationEvidence, integrationEvidence, newDelivery, stepDelivery)
import Lockstep.Kernel.Evidence (CommitId, HumanSignoff, mkCommitId, mkHumanSignoff)
import Lockstep.Kernel.Identity
  ( AttemptId (..)
  , ContractId (..)
  , EngineerId (..)
  , RepositoryId (..)
  , TicketId (..)
  , WorkOrderId (..)
  , WorkUnitId (..)
  , uuidFromWords
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..), TransitionRefusal, replay, transitionRefusalCode)
import Lockstep.Kernel.WorkOrder (Claim (..))
import Lockstep.Kernel.WorkUnit (AdmittedWorkUnit (..), WorkUnitRequest (..))
import Lockstep.Kernel.WorkUnitLifecycle
  ( AcceptedWorkUnit
  , Attempt (..)
  , CheckOutcome (..)
  , FrozenContract
  , ReviewVerdict (..)
  , Verification (..)
  , WorkUnitInput (..)
  , acceptedWorkUnit
  , mkFrozenContract
  , newWorkUnit
  , stepWorkUnit
  )

data Fixtures
  = Fixtures
  { fxCommitA :: CommitId
  , fxCommitB :: CommitId
  , fxGated :: FrozenContract
  -- ^ budget 2, one post-verification gate "challenge"
  , fxPlain :: FrozenContract
  -- ^ budget 2, no gates
  , fxTight :: FrozenContract
  -- ^ budget 1, no gates
  , fxAcceptedA :: AcceptedWorkUnit
  -- ^ Work Unit 1 accepted at commit A
  , fxAcceptedB :: AcceptedWorkUnit
  -- ^ Work Unit 2 accepted at commit B
  , fxIntegratedA :: IntegrationEvidence
  -- ^ covers Work Unit 1 only
  , fxIntegratedB :: IntegrationEvidence
  -- ^ covers Work Unit 2 only
  , fxSignoff :: HumanSignoff
  }

commitA :: T.Text
commitA =
  T.replicate 40 "a"

commitB :: T.Text
commitB =
  T.replicate 40 "b"

engineerA :: EngineerId
engineerA =
  EngineerId (uuidFromWords 2 1)

engineerB :: EngineerId
engineerB =
  EngineerId (uuidFromWords 2 2)

claimA :: Claim
claimA =
  Claim engineerA 1

claimB :: Claim
claimB =
  Claim engineerB 2

-- | The n-th admitted Work Unit identity (Ticket-originated, no plan reference).
admitted :: Word64 -> AdmittedWorkUnit
admitted n =
  AdmittedWorkUnit
    { admittedRequest =
        WorkUnitRequest
          { wuId = WorkUnitId (uuidFromWords 4 n)
          , wuRepository = RepositoryId (uuidFromWords 1 1)
          , wuTicket = TicketId (uuidFromWords 3 1)
          , wuWorkOrder = WorkOrderId (uuidFromWords 5 1)
          , wuPlanRef = Nothing
          }
    , admittedEngineer = engineerA
    }

attempt :: Int -> Attempt
attempt n =
  Attempt (AttemptId (uuidFromWords 6 (fromIntegral n))) n

passing :: CommitId -> Verification
passing commit =
  verificationWith commit [CheckPassed]

verificationWith :: CommitId -> [CheckOutcome] -> Verification
verificationWith commit outcomes =
  Verification
    commit
    ( case L.zipWith (\i o -> (T.pack ("check-" <> show i), o)) [1 :: Int ..] outcomes of
        [] -> ("check-1", CheckPassed) :| []
        x : xs -> x :| xs
    )

fixtures :: Maybe Fixtures
fixtures = do
  a <- mkCommitId commitA
  b <- mkCommitId commitB
  let
    digest = T.replicate 64 "d"
    contract = ContractId (uuidFromWords 7 1)
  gated <- mkFrozenContract contract digest 2 ["challenge"]
  plain <- mkFrozenContract contract digest 2 []
  tight <- mkFrozenContract contract digest 1 []
  acceptedA <- acceptedAt plain (admitted 1) a
  acceptedB <- acceptedAt plain (admitted 2) b
  integratedA <- integratedAt acceptedA a
  integratedB <- integratedAt acceptedB b
  signoff <- mkHumanSignoff "owner signoff 2026-10-18"
  pure (Fixtures a b gated plain tight acceptedA acceptedB integratedA integratedB signoff)

acceptedAt :: FrozenContract -> AdmittedWorkUnit -> CommitId -> Maybe AcceptedWorkUnit
acceptedAt contract identity commit =
  either (const Nothing) acceptedWorkUnit $
    replay
      stepWorkUnit
      (newWorkUnit identity)
      ( fmap
          (Command Supervisor)
          [ WuFreeze contract
          , WuStartAttempt (attempt 1)
          , WuImplementationObserved commit
          , WuVerificationObserved (passing commit)
          , WuReviewObserved ReviewApproved
          ]
      )

integratedAt :: AcceptedWorkUnit -> CommitId -> Maybe IntegrationEvidence
integratedAt accepted commit =
  either (const Nothing) integrationEvidence $
    replay stepDelivery (newDelivery LocalOnly (accepted :| [])) [Command Supervisor (DelIntegrate commit)]

withFixtures :: (Fixtures -> Assertion) -> Assertion
withFixtures action =
  maybe (assertFailure "fixtures could not be built (smart constructors or the lifecycles refused them)") action fixtures

allPrincipals :: [Principal]
allPrincipals =
  [minBound .. maxBound]

data Expect
  = To T.Text
  | Refuse T.Text
  deriving (Eq, Show)

-- | One §3 table cell: a labelled state, a labelled input, the permitted principals and the outcome.
data Row
  = Row
  { rowState :: T.Text
  , rowInput :: T.Text
  , rowPrincipals :: [Principal]
  , rowExpect :: Expect
  }

row :: T.Text -> T.Text -> [Principal] -> Expect -> Row
row =
  Row

-- | The same cell for several states.
rows :: [T.Text] -> T.Text -> [Principal] -> Expect -> [Row]
rows states input principals expect =
  fmap (\s -> Row s input principals expect) states

{- | Compares every labelled state × labelled input × principal with the rows
(C-P2.2 §6 "Exhaustive tables"); fails listing every mismatch.
-}
exhaustive ::
  (s -> Command i -> Either TransitionRefusal s) ->
  (s -> T.Text) ->
  [(T.Text, s)] ->
  [(T.Text, i)] ->
  [T.Text] ->
  [Row] ->
  Assertion
exhaustive step name states inputs terminals table = do
  let
    keys = fmap (\r -> (rowState r, rowInput r)) table
    duplicates = keys L.\\ L.nub keys
    unknownStates = L.filter (`L.notElem` fmap fst states) (fmap rowState table)
    unknownInputs = L.filter (`L.notElem` fmap fst inputs) (fmap rowInput table)
    expected stateLabel inputLabel principal
      | principal == Agent = Refuse "agent-assertion"
      | stateLabel `L.elem` terminals = Refuse "already-terminal"
      | otherwise =
          case L.find (\r -> rowState r == stateLabel && rowInput r == inputLabel) table of
            Nothing -> Refuse "illegal-transition"
            Just r
              | principal `L.notElem` rowPrincipals r -> Refuse "not-authorized"
              | otherwise -> rowExpect r
    actual s i principal =
      either (Refuse . transitionRefusalCode) (To . name) (step s (Command principal i))
    mismatches =
      [ T.unpack stateLabel <> " / " <> T.unpack inputLabel <> " / " <> show principal <> ": expected " <> show e <> ", got " <> show a
      | (stateLabel, s) <- states
      , (inputLabel, i) <- inputs
      , principal <- allPrincipals
      , let
          e = expected stateLabel inputLabel principal
          a = actual s i principal
      , e /= a
      ]
  if not (L.null duplicates) || not (L.null unknownStates) || not (L.null unknownInputs)
    then assertFailure ("malformed table: duplicates " <> show duplicates <> ", unknown states " <> show unknownStates <> ", unknown inputs " <> show unknownInputs)
    else
      if L.null mismatches
        then pure ()
        else assertFailure (show (L.length mismatches) <> " mismatches:\n" <> L.unlines (L.take 40 mismatches))
