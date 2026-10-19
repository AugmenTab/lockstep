{-# LANGUAGE RoleAnnotations #-}

{- | Shared transition vocabulary for the four lifecycles (contract C-P2.2 T1–T3):
typed principals, typed refusals and deterministic replay.

An 'Agent' is never an accepted principal. An agent's or model's claim
becomes evidence only after the Supervisor has validated it into a typed
observation, which the Supervisor then submits.
-}
module Lockstep.Kernel.Transition
  ( Principal (..)
  , Command (..)
  , TransitionRefusal (..)
  , transitionRefusalCode
  , TraceStep (..)
  , replay
  , replayTrace
  , Cell (..)
  , decide
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

data Principal
  = Human
  | Supervisor
  | Scheduler
  | DeliveryAdapter
  | Agent
  deriving (Eq, Ord, Show, Enum, Bounded)

type role Command representational
data Command i
  = Command
  { commandPrincipal :: Principal
  , commandInput :: i
  }
  deriving (Eq, Show)

data TransitionRefusal
  = AgentAssertion
  | AlreadyTerminal T.Text
  | NotAuthorized Principal T.Text
  | IllegalTransition T.Text T.Text
  | ClaimMismatch
  | BasisMismatch T.Text
  | KindForbids T.Text
  | AttemptBudgetExhausted
  | GatesPending
  deriving (Eq, Show)

transitionRefusalCode :: TransitionRefusal -> T.Text
transitionRefusalCode refusal =
  T.pack $
    case refusal of
      AgentAssertion -> "agent-assertion"
      AlreadyTerminal _ -> "already-terminal"
      NotAuthorized _ _ -> "not-authorized"
      IllegalTransition _ _ -> "illegal-transition"
      ClaimMismatch -> "claim-mismatch"
      BasisMismatch _ -> "basis-mismatch"
      KindForbids _ -> "kind-forbids"
      AttemptBudgetExhausted -> "attempt-budget-exhausted"
      GatesPending -> "gates-pending"

{- | One table cell (§3): the principals permitted for this (state, input)
pair and the outcome once authorization holds (an evidence refusal or the
next state).
-}
type role Cell representational

data Cell s
  = Cell [Principal] (Either TransitionRefusal s)

{- | The common check order (T2): agent, terminal state, legality of the pair
(a cell exists), authorization for the pair, then the cell's own evidence
outcome.
-}
decide :: Principal -> T.Text -> Bool -> T.Text -> Maybe (Cell s) -> Either TransitionRefusal s
decide principal stateName terminal inputName cell
  | principal == Agent = Left AgentAssertion
  | terminal = Left (AlreadyTerminal stateName)
  | otherwise =
      case cell of
        Nothing -> Left (IllegalTransition stateName inputName)
        Just (Cell permitted outcome)
          | principal `L.notElem` permitted -> Left (NotAuthorized principal inputName)
          | otherwise -> outcome

type role TraceStep representational representational
data TraceStep s i
  = StepAccepted s (Command i) s
  | StepRefused s (Command i) TransitionRefusal
  deriving (Eq, Show)

-- | Applies the commands in order; stops at the first refusal and returns its index.
replay :: (s -> Command i -> Either TransitionRefusal s) -> s -> [Command i] -> Either (Int, TransitionRefusal) s
replay step =
  go 0
 where
  go index state commands =
    case commands of
      [] -> Right state
      command : rest ->
        case step state command of
          Left refusal -> Left (index, refusal)
          Right next -> go (index + 1) next rest

-- | Applies every command; a refused one leaves the state unchanged and is recorded.
replayTrace :: (s -> Command i -> Either TransitionRefusal s) -> s -> [Command i] -> (s, [TraceStep s i])
replayTrace step start commands =
  let
    go (state, acc) command =
      case step state command of
        Left refusal -> (state, StepRefused state command refusal : acc)
        Right next -> (next, StepAccepted state command next : acc)
    (final, reversed) = L.foldl' go (start, []) commands
  in
    (final, L.reverse reversed)
