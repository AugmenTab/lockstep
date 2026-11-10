{- | The Capsule Runtime's vocabulary as typed values (Phase 5;
@docs/architecture/dev-capsules.md@ §6, §10, §12; contract C-P5.1 V1-V4).

The runtime (@scripts/capsule-runtime@) is deterministic infrastructure beneath
the Supervisor: it provisions and runs Dev Capsules and serves one
invocation's tool channel. The Supervisor speaks to it only in these words.
Each closed enumeration has one canonical text (its @…Text@ function), and its
parser is derived from it ('parseEnumText'), so the two cannot disagree. Those
texts are the runtime's own words; @lockstep-capsule@ checks them against the
script.
-}
module Lockstep.Kernel.Capsule
  ( -- * Names
    CapsuleName
  , parseCapsuleName
  , capsuleNameText
  , vmName

    -- * Roles and what they may do
  , CapsuleOperation (..)
  , capsuleOperationText
  , parseCapsuleOperation
  , roleOperations
  , operationMutates

    -- * Profiles
  , CapsuleProfile (..)
  , capsuleProfileText
  , parseCapsuleProfile
  , Resources (..)
  , profileResources

    -- * Lifecycle
  , LifecycleOperation (..)
  , lifecycleOperationText
  , VmStatus (..)
  , vmStatusText
  , parseVmStatus

    -- * Outcomes of a bridged call
  , HostOutcome (..)
  , hostOutcomeText
  , parseHostOutcome
  , RetryClass (..)
  , retryClass

    -- * Refusals
  , CapsuleRefusal (..)
  , capsuleRefusalText
  , parseCapsuleRefusal

    -- * Replies
  , ReplyResult (..)
  , replyResultText
  , RuntimeReply (..)
  , parseRuntimeReply
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Enum (parseEnumText)
import Lockstep.Kernel.Roles (Role (..))

{- | A capsule's name: 4–32 characters, lowercase ASCII letters, digits and
@-@, starting with a letter and not ending with @-@ (the runtime's
@re_capsule@). The VM's name is derived from it ('vmName'), never given.
-}
newtype CapsuleName
  = CapsuleName T.Text
  deriving (Eq, Ord, Show)

parseCapsuleName :: T.Text -> Maybe CapsuleName
parseCapsuleName text =
  case (T.uncons text, T.unsnoc text) of
    (Just (first, _), Just (_, final))
      | T.length text >= 4
      , T.length text <= 32
      , Char.isAsciiLower first
      , final /= '-'
      , T.all allowed text ->
          Just (CapsuleName text)
    _ -> Nothing
 where
  allowed c = Char.isAsciiLower c || Char.isDigit c || c == '-'

capsuleNameText :: CapsuleName -> T.Text
capsuleNameText (CapsuleName text) =
  text

-- | The VM's name: always @lockstep-@ and the capsule's name.
vmName :: CapsuleName -> T.Text
vmName (CapsuleName text) =
  T.pack "lockstep-" <> text

-- | One bridged tool call's operation (the runtime's binding vocabulary).
data CapsuleOperation
  = OpRead
  | OpList
  | OpSearch
  | OpWrite
  | OpEdit
  | OpExec
  | OpExecReadonly
  deriving (Eq, Ord, Show, Bounded, Enum)

capsuleOperationText :: CapsuleOperation -> T.Text
capsuleOperationText operation =
  T.pack $
    case operation of
      OpRead -> "read"
      OpList -> "list"
      OpSearch -> "search"
      OpWrite -> "write"
      OpEdit -> "edit"
      OpExec -> "exec"
      OpExecReadonly -> "exec_readonly"

parseCapsuleOperation :: T.Text -> Maybe CapsuleOperation
parseCapsuleOperation =
  parseEnumText capsuleOperationText

{- | What each role may do in its capsule (C-P5.1 V2; C-P5.6). Only the
Implementer writes or runs commands against the working state; the other
roles inspect, and run commands only against a disposable read-only view.
-}
roleOperations :: Role -> [CapsuleOperation]
roleOperations role =
  case role of
    Implementer -> [OpRead, OpList, OpSearch, OpWrite, OpEdit, OpExec]
    Planner -> readOnly
    Challenger -> readOnly
    Reviewer -> readOnly
 where
  readOnly = [OpRead, OpList, OpSearch, OpExecReadonly]

-- | Whether the operation can change the capsule's working state.
operationMutates :: CapsuleOperation -> Bool
operationMutates operation =
  operation `L.elem` [OpWrite, OpEdit, OpExec]

-- | A finite resource profile (C-P5.2 L5): never all of the host.
data CapsuleProfile
  = ProfileSmall
  | ProfileStandard
  | ProfileLarge
  deriving (Eq, Ord, Show, Bounded, Enum)

capsuleProfileText :: CapsuleProfile -> T.Text
capsuleProfileText profile =
  T.pack $
    case profile of
      ProfileSmall -> "small"
      ProfileStandard -> "standard"
      ProfileLarge -> "large"

parseCapsuleProfile :: T.Text -> Maybe CapsuleProfile
parseCapsuleProfile =
  parseEnumText capsuleProfileText

data Resources
  = Resources
  { resourceCpus :: Int
  , resourceMemoryGib :: Int
  , resourceDiskGib :: Int
  , resourceCommandSeconds :: Int
  }
  deriving (Eq, Show)

-- | The runtime's @profile_values@, the same numbers.
profileResources :: CapsuleProfile -> Resources
profileResources profile =
  case profile of
    ProfileSmall -> Resources 2 4 30 1800
    ProfileStandard -> Resources 4 8 60 3600
    ProfileLarge -> Resources 6 12 100 7200

-- | The runtime's allowlisted operations.
data LifecycleOperation
  = Provision
  | Start
  | Stop
  | Inspect
  | Destroy
  | Snapshot
  | Restore
  | Import
  | RunScript
  | Bind
  | Serve
  | Close
  deriving (Eq, Ord, Show, Bounded, Enum)

lifecycleOperationText :: LifecycleOperation -> T.Text
lifecycleOperationText operation =
  T.pack $
    case operation of
      Provision -> "provision"
      Start -> "start"
      Stop -> "stop"
      Inspect -> "inspect"
      Destroy -> "destroy"
      Snapshot -> "snapshot"
      Restore -> "restore"
      Import -> "import"
      RunScript -> "run"
      Bind -> "bind"
      Serve -> "serve"
      Close -> "close"

-- | A VM's status as the runtime reads it back from the backend every time.
data VmStatus
  = VmRunning
  | VmStopped
  | VmAbsent
  | VmBroken
  deriving (Eq, Ord, Show, Bounded, Enum)

vmStatusText :: VmStatus -> T.Text
vmStatusText status =
  T.pack $
    case status of
      VmRunning -> "Running"
      VmStopped -> "Stopped"
      VmAbsent -> "absent"
      VmBroken -> "Broken"

parseVmStatus :: T.Text -> Maybe VmStatus
parseVmStatus =
  parseEnumText vmStatusText

-- | The runtime's own outcome of one bridged call (the result's trusted line 1).
data HostOutcome
  = Completed
  | Refused
  | TimedOut
  | Cancelled
  | OutputLimit
  | CapsuleUnavailable
  | EffectUnknown
  deriving (Eq, Ord, Show, Bounded, Enum)

hostOutcomeText :: HostOutcome -> T.Text
hostOutcomeText outcome =
  T.pack $
    case outcome of
      Completed -> "completed"
      Refused -> "refused"
      TimedOut -> "timed-out"
      Cancelled -> "cancelled"
      OutputLimit -> "output-limit"
      CapsuleUnavailable -> "capsule-unavailable"
      EffectUnknown -> "effect-unknown"

parseHostOutcome :: T.Text -> Maybe HostOutcome
parseHostOutcome =
  parseEnumText hostOutcomeText

-- | How recovery may treat an outcome (C-P5.9 R1; dev-capsules.md §10).
data RetryClass
  = -- | Nothing ran: correct and retry.
    NothingRan
  | -- | Nothing ran: make the environment available, then retry.
    NeedsEnvironment
  | -- | It ran to an end Lockstep observed.
    Observed
  | -- | It may or may not have run: never replayed by itself.
    NeverReplay
  deriving (Eq, Ord, Show, Bounded, Enum)

retryClass :: HostOutcome -> RetryClass
retryClass outcome =
  case outcome of
    Refused -> NothingRan
    CapsuleUnavailable -> NeedsEnvironment
    Completed -> Observed
    TimedOut -> Observed
    Cancelled -> Observed
    OutputLimit -> Observed
    EffectUnknown -> NeverReplay

-- | Every refusal the runtime can give (its @reason=@ words).
data CapsuleRefusal
  = InvalidCapsuleId
  | InvalidProjectId
  | CapsuleUnknown
  | CapsuleOwnedByAnotherProject
  | InvalidProfile
  | NotDisposable
  | InvalidSnapshotName
  | SnapshotExists
  | SnapshotUnknown
  | NotSupportedByBackend
  | ScriptMissing
  | InvalidLimit
  | BundleMissing
  | BundleInvalid
  | InvalidInvocationId
  | InvalidTransactionId
  | InvalidRole
  | InvocationExists
  | WriterAlreadyActive
  | InvocationUnknown
  | InvocationClosed
  | OpNotAuthorizedForRole
  deriving (Eq, Ord, Show, Bounded, Enum)

capsuleRefusalText :: CapsuleRefusal -> T.Text
capsuleRefusalText refusal =
  T.pack $
    case refusal of
      InvalidCapsuleId -> "invalid-capsule-id"
      InvalidProjectId -> "invalid-project-id"
      CapsuleUnknown -> "capsule-unknown"
      CapsuleOwnedByAnotherProject -> "capsule-owned-by-another-project"
      InvalidProfile -> "invalid-profile"
      NotDisposable -> "not-disposable"
      InvalidSnapshotName -> "invalid-snapshot-name"
      SnapshotExists -> "snapshot-exists"
      SnapshotUnknown -> "snapshot-unknown"
      NotSupportedByBackend -> "not-supported-by-backend"
      ScriptMissing -> "script-missing"
      InvalidLimit -> "invalid-limit"
      BundleMissing -> "bundle-missing"
      BundleInvalid -> "bundle-invalid"
      InvalidInvocationId -> "invalid-invocation-id"
      InvalidTransactionId -> "invalid-transaction-id"
      InvalidRole -> "invalid-role"
      InvocationExists -> "invocation-exists"
      WriterAlreadyActive -> "writer-already-active"
      InvocationUnknown -> "invocation-unknown"
      InvocationClosed -> "invocation-closed"
      OpNotAuthorizedForRole -> "op-not-authorized-for-role"

parseCapsuleRefusal :: T.Text -> Maybe CapsuleRefusal
parseCapsuleRefusal =
  parseEnumText capsuleRefusalText

data ReplyResult
  = ReplyOk
  | ReplyRefused
  | ReplyUnavailable
  | ReplyFailed
  | ReplyExited
  deriving (Eq, Ord, Show, Bounded, Enum)

replyResultText :: ReplyResult -> T.Text
replyResultText result =
  T.pack $
    case result of
      ReplyOk -> "ok"
      ReplyRefused -> "refused"
      ReplyUnavailable -> "unavailable"
      ReplyFailed -> "failed"
      ReplyExited -> "exited"

-- | The runtime's one-line reply: @capsule-runtime 1 OP RESULT key=value …@.
data RuntimeReply
  = RuntimeReply
  { replyOperation :: LifecycleOperation
  , replyResult :: ReplyResult
  , replyFields :: [(T.Text, T.Text)]
  }
  deriving (Eq, Show)

{- | Reads a reply; nothing for any line that is not exactly one: the version
must be 1, the operation and result known, and every field @key=value@ with
a non-empty key.
-}
parseRuntimeReply :: T.Text -> Maybe RuntimeReply
parseRuntimeReply line =
  case T.words line of
    tag : version : operation : result : fields
      | tag == T.pack "capsule-runtime"
      , version == T.pack "1" -> do
          op <- parseEnumText lifecycleOperationText operation
          res <- parseEnumText replyResultText result
          pairs <- traverse field fields
          Just (RuntimeReply op res pairs)
    _ -> Nothing
 where
  field text =
    case T.breakOn (T.pack "=") text of
      (key, rest)
        | not (T.null key)
        , Just ('=', value) <- T.uncons rest ->
            Just (key, value)
      _ -> Nothing
