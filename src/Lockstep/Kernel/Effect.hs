{- | Effect intents (contract C-P2.5; DG-04 D-4.1 to D-4.4, D-4.7 and binding
requirements 1, 2, 3, 4 and 7). An intent is a durable, uniquely identified
authorization for one external effect. Its lifecycle (§3) is fenced by a
claim generation: a claim raises it, every later write must carry it, and an
older one is refused. A lease end gates only a new claim and the dispatch
marker; it never proves anything about the effect itself. Nothing here
performs an effect.
-}
module Lockstep.Kernel.Effect
  ( EffectClass (..)
  , effectClassName
  , IdempotencyTerms (..)
  , LookupTerms (..)
  , ClassTerms (..)
  , EffectSpec
  , mkEffectSpec
  , effectSpecName
  , effectSpecClass
  , effectSpecTerms
  , effectSpecBudget
  , EffectKey
  , mkEffectKey
  , effectKeyText
  , OperationId (..)
  , SubjectRef (..)
  , IntentRequest (..)
  , Lease (..)
  , Observation (..)
  , Settlement (..)
  , Provenance (..)
  , Reason (..)
  , attestedReasonText
  , reasonOf
  , IntentState (..)
  , Intent (..)
  , newIntents
  , IntentInput (..)
  , stepIntent
  , intentStateName
  , IntentStateName (..)
  , intentStateNameOf
  , intentStateNameText
  , parseIntentStateName
  , parseEffectClass
  , EffectRefusal (..)
  , effectRefusalCode
  , effectRefusalMessage
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Enum (parseEnumText)
import Lockstep.Kernel.Identity (TicketId, Uuid, WorkOrderId)
import Lockstep.Kernel.Profile (ContentDigest, Hasher (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..), principalLabel)

data EffectClass
  = Repeatable
  | Idempotent
  | Queryable
  | Unqueryable
  deriving (Eq, Ord, Show, Enum, Bounded)

effectClassName :: EffectClass -> T.Text
effectClassName c =
  T.pack $
    case c of
      Repeatable -> "repeatable"
      Idempotent -> "idempotent"
      Queryable -> "queryable"
      Unqueryable -> "unqueryable"

data IdempotencyTerms
  = IdempotencyTerms
  { keyLifetimeSeconds :: Integer
  , refusesChangedParameters :: Bool
  }
  deriving (Eq, Show)

data LookupTerms
  = LookupTerms
  { lookupAuthoritative :: Bool
  , lookupExcludesLateApplication :: Bool
  }
  deriving (Eq, Show)

data ClassTerms
  = TermsRepeatable
  | TermsIdempotent IdempotencyTerms
  | TermsQueryable LookupTerms
  | TermsUnqueryable
  deriving (Eq, Show)

data EffectSpec
  = EffectSpec T.Text ClassTerms Int
  deriving (Eq, Show)

validName :: T.Text -> Bool
validName text =
  case T.uncons text of
    Just (first, rest) ->
      Char.isAsciiLower first
        && T.length rest <= 63
        && T.all (\c -> Char.isAsciiLower c || Char.isDigit c || c == '-') rest
    Nothing -> False

mkEffectSpec :: T.Text -> ClassTerms -> Int -> Either EffectRefusal EffectSpec
mkEffectSpec name terms budget
  | not (validName name) = Left (InvalidEffectSpec (T.pack "the name must match ^[a-z][a-z0-9-]{0,63}$"))
  | budget < 0 || budget > 3 = Left (InvalidEffectSpec (T.pack "the retry budget must be 0 to 3"))
  | otherwise =
      case terms of
        TermsUnqueryable | budget /= 0 -> Left UnsafeRetryBudget
        TermsIdempotent idem
          | keyLifetimeSeconds idem < 1 -> Left (InvalidEffectSpec (T.pack "the key lifetime must be at least one second"))
          -- The stored lifetime is a PostgreSQL bigint; a longer one cannot be recorded faithfully.
          | keyLifetimeSeconds idem > toInteger (maxBound :: Int64) -> Left (InvalidEffectSpec (T.pack "the key lifetime must be at most 9223372036854775807 seconds"))
          | not (refusesChangedParameters idem) -> Left IdempotencyUndocumented
        _ -> Right (EffectSpec name terms budget)

effectSpecName :: EffectSpec -> T.Text
effectSpecName (EffectSpec name _ _) =
  name

effectSpecClass :: EffectSpec -> EffectClass
effectSpecClass (EffectSpec _ terms _) =
  case terms of
    TermsRepeatable -> Repeatable
    TermsIdempotent _ -> Idempotent
    TermsQueryable _ -> Queryable
    TermsUnqueryable -> Unqueryable

effectSpecTerms :: EffectSpec -> ClassTerms
effectSpecTerms (EffectSpec _ terms _) =
  terms

effectSpecBudget :: EffectSpec -> Int
effectSpecBudget (EffectSpec _ _ budget) =
  budget

newtype EffectKey
  = EffectKey T.Text
  deriving (Eq, Ord, Show)

mkEffectKey :: T.Text -> Either EffectRefusal EffectKey
mkEffectKey text =
  if validName text then Right (EffectKey text) else Left (InvalidEffectKey text)

effectKeyText :: EffectKey -> T.Text
effectKeyText (EffectKey text) =
  text

newtype OperationId
  = OperationId Uuid
  deriving (Eq, Ord, Show)

data SubjectRef
  = SubjectTicket TicketId
  | SubjectWorkOrder WorkOrderId
  deriving (Eq, Ord, Show)

data IntentRequest
  = IntentRequest
  { requestKey :: EffectKey
  , requestSpec :: EffectSpec
  , requestParameters :: T.Text
  }
  deriving (Eq, Show)

data Lease
  = Lease
  { leaseOwner :: T.Text
  , leaseGeneration :: Int
  , leaseUntil :: UTCTime
  }
  deriving (Eq, Show)

data Observation
  = DestinationApplied T.Text
  | DestinationNotApplied T.Text
  | NoAnswer T.Text
  deriving (Eq, Show)

data Settlement
  = SettledApplied T.Text
  | SettledNotApplied T.Text
  deriving (Eq, Show)

{- | Where an outcome's reason comes from: the destination's own answer (or
Lockstep's lookup of it), or a person who attested it (C-P2.7 R5; DG-04
binding requirement 6).
-}
data Provenance
  = Observed
  | HumanAttested
  deriving (Eq, Show)

{- | An outcome's reason with its provenance. The states keep a reason as the
text that is stored ('IntentNotApplied', 'Settlement'); an attested one is
that text after 'attestedReasonText's marker. 'reasonOf' reads it back.
-}
data Reason
  = Reason
  { reasonProvenance :: Provenance
  , reasonText :: T.Text
  -- ^ the reason as stored (for an attested one, with its marker)
  }
  deriving (Eq, Show)

-- | The stored reason of a person's attestation: the evidence after the fixed marker @human-attested: @.
attestedReasonText :: T.Text -> T.Text
attestedReasonText evidence =
  attestedMarker <> evidence

{- | The provenance of a stored reason, decided here and nowhere else: a reason
that begins with the marker of 'attestedReasonText' is 'HumanAttested'; any
other is 'Observed'. The reader is the prefix rule the frozen suite pins (unit
@RemediationTest@ "a 'human-attested:' outcome is ATTESTED without the
record"), so the guarantee is on the writer side: only a person's resolution
('Lockstep.Kernel.Reconciliation.resolveIntent') writes the marker, and an
observation whose text carries it is refused as malformed where observations
become reasons ('observed'). The resolution's attestation record is the other,
independent, source of the same fact.
-}
reasonOf :: T.Text -> Reason
reasonOf text =
  Reason (if attestedMarker `T.isPrefixOf` text then HumanAttested else Observed) text

attestedMarker :: T.Text
attestedMarker =
  T.pack "human-attested: "

data IntentState
  = IntentPending
  | IntentClaimed Lease
  | IntentDispatched Lease
  | IntentApplied T.Text
  | IntentNotApplied T.Text
  | IntentUnknown T.Text
  | IntentSettled Settlement
  | IntentAbandoned T.Text
  deriving (Eq, Show)

data Intent
  = Intent
  { intentOperation :: OperationId
  , intentSubject :: SubjectRef
  , intentBasisRevision :: Int
  , intentKey :: EffectKey
  , intentSpec :: EffectSpec
  , intentParameters :: T.Text
  , intentParametersDigest :: ContentDigest
  , intentState :: IntentState
  , intentGeneration :: Int
  , intentDispatches :: Int
  }
  deriving (Eq, Show)

{- | The intents of one decision (E2): each pending, generation 0, no
dispatches, with the SHA-256 of its parameters. One effect key twice is
'DuplicateEffectKey'.
-}
newIntents :: Hasher -> SubjectRef -> Int -> [(OperationId, IntentRequest)] -> Either EffectRefusal [Intent]
newIntents (Hasher hash) subject revision requests =
  case duplicates (fmap (requestKey . snd) requests) of
    k : _ -> Left (DuplicateEffectKey k)
    [] -> traverse build requests
 where
  build (operation, request)
    | not (validParameters (requestParameters request)) = Left InvalidEffectParameters
    | otherwise =
        Right
          Intent
            { intentOperation = operation
            , intentSubject = subject
            , intentBasisRevision = revision
            , intentKey = requestKey request
            , intentSpec = requestSpec request
            , intentParameters = requestParameters request
            , intentParametersDigest = hash (requestParameters request)
            , intentState = IntentPending
            , intentGeneration = 0
            , intentDispatches = 0
            }

duplicates :: Ord a => [a] -> [a]
duplicates =
  mapMaybe second . L.group . L.sort
 where
  second xs =
    case xs of
      x : _ : _ -> Just x
      _ -> Nothing

validParameters :: T.Text -> Bool
validParameters text =
  not (T.null text) && T.length text <= 4096 && not (T.any Char.isControl text)

data IntentInput
  = IntentClaim T.Text UTCTime UTCTime
  | IntentDispatch Int UTCTime
  | IntentObserve Int Observation
  | IntentSettle Int
  | IntentAbandon T.Text
  deriving (Eq, Show)

{- | One step of the §3 table. Check order (E3): an Agent; a settled or
abandoned intent; the principal; a stale generation; then the cell.
-}
stepIntent :: Intent -> Command IntentInput -> Either EffectRefusal Intent
stepIntent intent (Command principal input)
  | principal == Agent = Left EffectAgentAssertion
  | terminal (intentState intent) = Left EffectAlreadySettled
  | principal /= permitted input = Left (EffectNotAuthorized principal)
  | Just g <- inputGeneration input, g /= intentGeneration intent = Left StaleClaim
  | otherwise = cell intent input

terminal :: IntentState -> Bool
terminal state =
  case state of
    IntentSettled _ -> True
    IntentAbandoned _ -> True
    _ -> False

permitted :: IntentInput -> Principal
permitted input =
  case input of
    IntentAbandon _ -> Human
    _ -> Supervisor

inputGeneration :: IntentInput -> Maybe Int
inputGeneration input =
  case input of
    IntentDispatch g _ -> Just g
    IntentObserve g _ -> Just g
    IntentSettle g -> Just g
    IntentClaim {} -> Nothing
    IntentAbandon _ -> Nothing

cell :: Intent -> IntentInput -> Either EffectRefusal Intent
cell intent input =
  case (intentState intent, input) of
    (_, IntentAbandon reason) -> Right (to (IntentAbandoned reason))
    (IntentPending, IntentClaim owner _ end) -> claimed owner end
    (IntentClaimed lease, IntentClaim owner now end)
      | now >= leaseUntil lease -> claimed owner end
      | otherwise -> Left ClaimHeld
    (IntentClaimed lease, IntentDispatch _ now)
      | now >= leaseUntil lease -> Left LeaseExpired
      | otherwise -> Right (to (IntentDispatched lease)) {intentDispatches = intentDispatches intent + 1}
    (IntentDispatched _, IntentClaim {}) -> Left DispatchedNeedsRecovery
    (IntentDispatched _, IntentObserve _ observation) -> Right (to (observed observation))
    (IntentApplied _, IntentClaim {}) -> Left AlreadyObserved
    (IntentApplied result, IntentSettle _) -> Right (to (IntentSettled (SettledApplied result)))
    (IntentNotApplied _, IntentClaim owner _ end)
      | intentDispatches intent <= effectSpecBudget (intentSpec intent) -> claimed owner end
      | otherwise -> Left RetriesExhausted
    (IntentNotApplied reason, IntentSettle _) -> Right (to (IntentSettled (SettledNotApplied reason)))
    (IntentUnknown _, IntentClaim {}) -> Left OutcomeUnknownBlocks
    (IntentUnknown _, IntentSettle _) -> Left OutcomeUnknownBlocks
    (state, IntentObserve _ _) | observedAlready state -> Left AlreadyObserved
    (state, _) -> Left (IllegalIntentTransition (intentStateName state) (inputName input))
 where
  to state = intent {intentState = state}
  claimed owner end =
    let
      next = intentGeneration intent + 1
    in
      Right (to (IntentClaimed (Lease owner next end))) {intentGeneration = next}
  observedAlready state =
    case state of
      IntentApplied _ -> True
      IntentNotApplied _ -> True
      IntentUnknown _ -> True
      _ -> False

{- | E6: a missing answer is an unknown outcome, never a failure. This is the
one place an observation's text becomes an intent's reason. A destination
never speaks for a person (DG-04 binding requirement 6): an answer whose text
carries the attestation marker ('attestedReasonText') is not stored as it
came, since it would read back as attested ('reasonOf'); it is a malformed
answer, an unknown outcome, as the executor makes any other invalid answer.
-}
observed :: Observation -> IntentState
observed observation =
  case observation of
    DestinationApplied result
      | forged result -> malformed
      | otherwise -> IntentApplied result
    DestinationNotApplied reason
      | forged reason -> malformed
      | otherwise -> IntentNotApplied reason
    NoAnswer reason
      | forged reason -> malformed
      | otherwise -> IntentUnknown reason
 where
  forged text = reasonProvenance (reasonOf text) == HumanAttested
  malformed = IntentUnknown (T.pack "malformed-answer")

inputName :: IntentInput -> T.Text
inputName input =
  T.pack $
    case input of
      IntentClaim {} -> "claim"
      IntentDispatch _ _ -> "dispatch"
      IntentObserve _ _ -> "observe"
      IntentSettle _ -> "settle"
      IntentAbandon _ -> "abandon"

intentStateName :: IntentState -> T.Text
intentStateName =
  intentStateNameText . intentStateNameOf

-- | Which state an intent is in, without its lease or outcome (the stored @state@ column).
data IntentStateName
  = NamePending
  | NameClaimed
  | NameDispatched
  | NameConfirmedApplied
  | NameConfirmedNotApplied
  | NameOutcomeUnknown
  | NameSettled
  | NameAbandoned
  deriving (Eq, Show, Enum, Bounded)

intentStateNameOf :: IntentState -> IntentStateName
intentStateNameOf state =
  case state of
    IntentPending -> NamePending
    IntentClaimed _ -> NameClaimed
    IntentDispatched _ -> NameDispatched
    IntentApplied _ -> NameConfirmedApplied
    IntentNotApplied _ -> NameConfirmedNotApplied
    IntentUnknown _ -> NameOutcomeUnknown
    IntentSettled _ -> NameSettled
    IntentAbandoned _ -> NameAbandoned

intentStateNameText :: IntentStateName -> T.Text
intentStateNameText name =
  T.pack $
    case name of
      NamePending -> "pending"
      NameClaimed -> "claimed"
      NameDispatched -> "dispatched"
      NameConfirmedApplied -> "confirmed-applied"
      NameConfirmedNotApplied -> "confirmed-not-applied"
      NameOutcomeUnknown -> "outcome-unknown"
      NameSettled -> "settled"
      NameAbandoned -> "abandoned"

-- | The state name of its text; derived from 'intentStateNameText'.
parseIntentStateName :: T.Text -> Maybe IntentStateName
parseIntentStateName =
  parseEnumText intentStateNameText

-- | The effect class of its name; derived from 'effectClassName'.
parseEffectClass :: T.Text -> Maybe EffectClass
parseEffectClass =
  parseEnumText effectClassName

data EffectRefusal
  = InvalidEffectSpec T.Text
  | IdempotencyUndocumented
  | UnsafeRetryBudget
  | InvalidEffectKey T.Text
  | InvalidEffectParameters
  | DuplicateEffectKey EffectKey
  | EffectAgentAssertion
  | EffectAlreadySettled
  | EffectNotAuthorized Principal
  | StaleClaim
  | IllegalIntentTransition T.Text T.Text
  | ClaimHeld
  | LeaseExpired
  | DispatchedNeedsRecovery
  | AlreadyObserved
  | OutcomeUnknownBlocks
  | RetriesExhausted
  deriving (Eq, Show)

effectRefusalCode :: EffectRefusal -> T.Text
effectRefusalCode refusal =
  T.pack $
    case refusal of
      InvalidEffectSpec _ -> "invalid-effect-spec"
      IdempotencyUndocumented -> "idempotency-undocumented"
      UnsafeRetryBudget -> "retry-budget-forbidden"
      InvalidEffectKey _ -> "invalid-effect-key"
      InvalidEffectParameters -> "invalid-effect-parameters"
      DuplicateEffectKey _ -> "duplicate-effect-key"
      EffectAgentAssertion -> "agent-assertion"
      EffectAlreadySettled -> "already-settled"
      EffectNotAuthorized _ -> "not-authorized"
      StaleClaim -> "stale-claim"
      IllegalIntentTransition _ _ -> "illegal-intent-transition"
      ClaimHeld -> "claim-held"
      LeaseExpired -> "lease-expired"
      DispatchedNeedsRecovery -> "dispatched-needs-recovery"
      AlreadyObserved -> "already-observed"
      OutcomeUnknownBlocks -> "outcome-unknown"
      RetriesExhausted -> "retries-exhausted"

-- | The refusal in words (its code is 'effectRefusalCode').
effectRefusalMessage :: EffectRefusal -> T.Text
effectRefusalMessage refusal =
  case refusal of
    InvalidEffectSpec reason -> T.pack "the effect spec is not valid: " <> reason
    IdempotencyUndocumented -> T.pack "an idempotent effect must document its key lifetime"
    UnsafeRetryBudget -> T.pack "this effect class may not be retried"
    InvalidEffectKey reason -> T.pack "the effect key is not valid: " <> reason
    InvalidEffectParameters -> T.pack "the effect parameters are not valid"
    DuplicateEffectKey key -> T.pack "the effect key " <> effectKeyText key <> T.pack " is declared twice"
    EffectAgentAssertion -> T.pack "an agent's assertion is never a command"
    EffectAlreadySettled -> T.pack "the intent is already settled"
    EffectNotAuthorized principal -> principalLabel principal <> T.pack " may not step an effect intent"
    StaleClaim -> T.pack "the intent's claim has moved on"
    IllegalIntentTransition state input -> T.pack "a " <> input <> T.pack " is not possible while the intent is " <> state
    ClaimHeld -> T.pack "another claim on the intent is still held"
    LeaseExpired -> T.pack "the intent's lease has expired"
    DispatchedNeedsRecovery -> T.pack "the intent was dispatched and needs recovery first"
    AlreadyObserved -> T.pack "the intent's outcome is already observed"
    OutcomeUnknownBlocks -> T.pack "the intent's outcome is unknown; a person must resolve it"
    RetriesExhausted -> T.pack "the intent's retries are spent"
