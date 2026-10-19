{- | Recovery of an interrupted dispatch (contract C-P2.6 X7, §3; DG-04 D-4.5,
binding requirements 3 and 5). A dispatched intent whose lease has ended may
or may not have taken effect. What may follow depends only on its class:
re-executing a repeatable effect is harmless, and an idempotent destination
deduplicates the same operation id, so both may be dispatched again within
their budget under a new generation. Anything else becomes an unknown
outcome, which halts for reconciliation or a human. Nothing here performs an
effect.
-}
module Lockstep.Kernel.Recovery
  ( RecoveryInput (..)
  , Recovery (..)
  , recoveryIntent
  , recoverIntent
  , renderRecovery
  , RecoveryRefusal (..)
  , recoveryRefusalCode
  ) where

import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Effect
  ( EffectClass (..)
  , Intent (..)
  , IntentState (..)
  , Lease (..)
  , effectSpecBudget
  , effectSpecClass
  , intentStateName
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..))

data RecoveryInput
  = RecoveryInput
  { recoveryOwner :: T.Text
  , recoveryNow :: UTCTime
  , recoveryLeaseUntil :: UTCTime
  , recoverySubjectActive :: Bool
  }
  deriving (Eq, Show)

data Recovery
  = RecoverRedispatch Intent
  | RecoverUnknown Intent
  deriving (Eq, Show)

recoveryIntent :: Recovery -> Intent
recoveryIntent recovery =
  case recovery of
    RecoverRedispatch i -> i
    RecoverUnknown i -> i

{- | X7. Check order: an Agent; a settled or abandoned intent; the
principal; an intent that is not dispatched; a lease that has not ended;
then the §3 table.
-}
recoverIntent :: Intent -> Command RecoveryInput -> Either RecoveryRefusal Recovery
recoverIntent intent (Command principal input)
  | principal == Agent = Left RecoveryAgentAssertion
  | terminal (intentState intent) = Left RecoveryAlreadySettled
  | principal /= Supervisor = Left (RecoveryNotAuthorized principal)
  | otherwise =
      case intentState intent of
        IntentDispatched lease
          | recoveryNow input < leaseUntil lease -> Left RecoveryLeaseActive
          | otherwise -> Right (decide intent input)
        state -> Left (NothingToRecover (intentStateName state))

terminal :: IntentState -> Bool
terminal state =
  case state of
    IntentSettled _ -> True
    IntentAbandoned _ -> True
    _ -> False

decide :: Intent -> RecoveryInput -> Recovery
decide intent input
  | not (recoverySubjectActive input) = unknown "dispatch-interrupted: subject not active"
  | otherwise =
      case effectSpecClass (intentSpec intent) of
        Repeatable -> redispatchWithinBudget
        Idempotent -> redispatchWithinBudget
        Queryable -> unknown "dispatch-interrupted: lookup not available"
        Unqueryable -> unknown "dispatch-interrupted: unqueryable effect"
 where
  unknown reason =
    RecoverUnknown intent {intentState = IntentUnknown (T.pack reason)}
  redispatchWithinBudget
    | intentDispatches intent <= effectSpecBudget (intentSpec intent) =
        let
          next = intentGeneration intent + 1
        in
          RecoverRedispatch
            intent
              { intentState = IntentClaimed (Lease (recoveryOwner input) next (recoveryLeaseUntil input))
              , intentGeneration = next
              }
    | otherwise = unknown "dispatch-interrupted: no retry left"

-- | §4: the recovery record's canonical text.
renderRecovery :: Recovery -> T.Text
renderRecovery recovery =
  case recovery of
    RecoverRedispatch i ->
      case intentState i of
        IntentClaimed lease ->
          T.pack ("redispatch generation=" <> show (intentGeneration i) <> " owner=") <> quoted (leaseOwner lease)
        state -> T.pack "redispatch state=" <> intentStateName state
    RecoverUnknown i ->
      case intentState i of
        IntentUnknown reason -> T.pack "unknown reason=" <> quoted reason
        state -> T.pack "unknown state=" <> intentStateName state

quoted :: T.Text -> T.Text
quoted text =
  T.pack "\"" <> T.concatMap escape text <> T.pack "\""
 where
  escape c =
    case c of
      '\\' -> T.pack "\\\\"
      '"' -> T.pack "\\\""
      _ -> T.singleton c

data RecoveryRefusal
  = RecoveryAgentAssertion
  | RecoveryAlreadySettled
  | RecoveryNotAuthorized Principal
  | NothingToRecover T.Text
  | RecoveryLeaseActive
  deriving (Eq, Show)

recoveryRefusalCode :: RecoveryRefusal -> T.Text
recoveryRefusalCode refusal =
  T.pack $
    case refusal of
      RecoveryAgentAssertion -> "agent-assertion"
      RecoveryAlreadySettled -> "already-settled"
      RecoveryNotAuthorized _ -> "not-authorized"
      NothingToRecover _ -> "nothing-to-recover"
      RecoveryLeaseActive -> "lease-active"
