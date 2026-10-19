{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.8 §7 unit cases: generated, replayable traces over the pure Kernel
(V7). The generator is a SplitMix64 written here, so a seed gives the same
traces whatever library versions are in use. A trace renders to canonical
text, parses back, and replays to the same intent and status.
-}
module Lockstep.Kernel.TraceTest
  ( tests
  ) where

import Data.Bits (shiftR, xor)
import Data.List qualified as L
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , IdempotencyTerms (..)
  , Intent (..)
  , IntentInput (..)
  , IntentRequest (..)
  , IntentState (..)
  , LookupTerms (..)
  , Observation (..)
  , OperationId (..)
  , Settlement (..)
  , SubjectRef (..)
  , intentStateName
  , mkEffectKey
  , mkEffectSpec
  , newIntents
  , stepIntent
  )
import Lockstep.Kernel.EffectView (EffectStatus (..), StatusFacts (..), effectStatus)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Reconciliation
  ( LateVerdict (..)
  , LookupResult (..)
  , ReconcileInput (..)
  , Resolution (..)
  , judgeLateObservation
  , reconcileIntent
  , resolveIntent
  )
import Lockstep.Kernel.Recovery (RecoveryInput (..), recoverIntent, recoveryIntent)
import Lockstep.Kernel.Transition (Command (..), Principal (..))

tests :: TestTree
tests =
  testGroup
    "Generated Kernel traces (C-P2.8)"
    [ generatorTests
    , invariantTests
    , replayTests
    ]

seed :: Word64
seed =
  20261019

traceCount :: Int
traceCount =
  300

-- SplitMix64 -------------------------------------------------------------------

newtype Gen
  = Gen Word64

nextWord :: Gen -> (Word64, Gen)
nextWord (Gen s) =
  let
    s' = s + 0x9e3779b97f4a7c15
    z1 = (s' `xor` (s' `shiftR` 30)) * 0xbf58476d1ce4e5b9
    z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
  in
    (z2 `xor` (z2 `shiftR` 31), Gen s')

-- | A number in [0, n).
below :: Int -> Gen -> (Int, Gen)
below n g =
  let
    (w, g') = nextWord g
  in
    (fromIntegral (w `mod` fromIntegral (max 1 n)), g')

-- | Picks by weight; the first choice is explicit, so the list is never empty.
weighted :: (Int, a) -> [(Int, a)] -> Gen -> (a, Gen)
weighted first rest g =
  let
    choices = first : rest
    (r, g') = below (L.sum (fmap fst choices)) g
    pick acc (w, x) remaining =
      case remaining of
        next : more | acc >= w -> pick (acc - w) next more
        _ -> x
  in
    (pick r first rest, g')

-- Traces ---------------------------------------------------------------------

data Who = WHuman | WSupervisor | WScheduler | WAgent
  deriving (Eq, Show, Enum, Bounded)

data GenRef = GCurrent | GOlder | GNewer
  deriving (Eq, Show, Enum, Bounded)

data Obs = OApplied | ONotApplied | ONoAnswer
  deriving (Eq, Show, Enum, Bounded)

data Look = LFound | LNotFound | LFailed
  deriving (Eq, Show, Enum, Bounded)

data Choice = CAttestApplied | CAttestNotApplied | CRetry | CRetryUnacknowledged
  deriving (Eq, Show, Enum, Bounded)

data Step
  = SClaim Who Integer Integer
  | SDispatch Who GenRef Integer
  | SObserve Who GenRef Obs
  | SSettle Who GenRef
  | SAbandon Who
  | SRecover Who Integer Bool
  | SReconcile Who Integer Look
  | SResolve Who GenRef Choice
  | SLate Obs
  deriving (Eq, Show)

-- | The class variant (0 repeatable, 1 idempotent, 2 queryable authoritative, 3 queryable not authoritative, 4 unqueryable), the budget, the steps.
data Trace
  = Trace
  { traceVariant :: Int
  , traceBudget :: Int
  , traceSteps :: [Step]
  }
  deriving (Eq, Show)

terms :: Int -> ClassTerms
terms variant =
  case variant of
    0 -> TermsRepeatable
    1 -> TermsIdempotent (IdempotencyTerms 86400 True)
    2 -> TermsQueryable (LookupTerms True True)
    3 -> TermsQueryable (LookupTerms False False)
    _ -> TermsUnqueryable

genTrace :: Gen -> (Trace, Gen)
genTrace g0 =
  let
    (variant, g1) = below 5 g0
    (budget, g2) = if variant == 4 then (0, g1) else below 3 g1
    (len, g3) = below 36 g2
    (generated, g4) = genSteps (len + 5) 0 g3
  in
    (Trace variant budget generated, g4)

genSteps :: Int -> Integer -> Gen -> ([Step], Gen)
genSteps n now g
  | n <= 0 = ([], g)
  | otherwise =
      let
        (s, g', now') = genStep g now
        (rest, g'') = genSteps (n - 1) now' g'
      in
        (s : rest, g'')

genWho :: Gen -> (Who, Gen)
genWho =
  weighted (60, WSupervisor) [(20, WHuman), (10, WScheduler), (10, WAgent)]

genHuman :: Gen -> (Who, Gen)
genHuman =
  weighted (70, WHuman) [(20, WSupervisor), (10, WAgent)]

genRef :: Gen -> (GenRef, Gen)
genRef =
  weighted (80, GCurrent) [(10, GOlder), (10, GNewer)]

genObs :: Gen -> (Obs, Gen)
genObs =
  weighted (45, OApplied) [(30, ONotApplied), (25, ONoAnswer)]

genStep :: Gen -> Integer -> (Step, Gen, Integer)
genStep g now0 =
  let
    (dt, g1) = below 31 g
    now = now0 + fromIntegral dt
    (kind, g2) = weighted (15, 0 :: Int) [(15, 1), (15, 2), (10, 3), (3, 4), (10, 5), (10, 6), (10, 7), (7, 8)] g1
  in
    case kind of
      0 ->
        let
          (w, g3) = genWho g2
          (lease, g4) = below 61 g3
        in
          (SClaim w now (30 + fromIntegral lease), g4, now)
      1 -> let (w, g3) = genWho g2; (r, g4) = genRef g3 in (SDispatch w r now, g4, now)
      2 -> let (w, g3) = genWho g2; (r, g4) = genRef g3; (o, g5) = genObs g4 in (SObserve w r o, g5, now)
      3 -> let (w, g3) = genWho g2; (r, g4) = genRef g3 in (SSettle w r, g4, now)
      4 -> let (w, g3) = genHuman g2 in (SAbandon w, g3, now)
      5 -> let (w, g3) = genWho g2; (a, g4) = weighted (80, True) [(20, False)] g3 in (SRecover w now a, g4, now)
      6 -> let (w, g3) = genWho g2; (l, g4) = weighted (40, LFound) [(40, LNotFound), (20, LFailed)] g3 in (SReconcile w now l, g4, now)
      7 -> let (w, g3) = genHuman g2; (r, g4) = genRef g3; (c, g5) = weighted (30, CAttestApplied) [(30, CAttestNotApplied), (30, CRetry), (10, CRetryUnacknowledged)] g4 in (SResolve w r c, g5, now)
      _ -> let (o, g3) = genObs g2 in (SLate o, g3, now)

traces :: [Trace]
traces =
  L.take traceCount (L.unfoldr (Just . genTrace) (Gen seed))

-- Rendering and parsing --------------------------------------------------------

whoName :: Who -> T.Text
whoName w =
  case w of
    WHuman -> "human"
    WSupervisor -> "supervisor"
    WScheduler -> "scheduler"
    WAgent -> "agent"

refName :: GenRef -> T.Text
refName r =
  case r of
    GCurrent -> "current"
    GOlder -> "older"
    GNewer -> "newer"

obsName :: Obs -> T.Text
obsName o =
  case o of
    OApplied -> "applied"
    ONotApplied -> "not-applied"
    ONoAnswer -> "no-answer"

lookName :: Look -> T.Text
lookName l =
  case l of
    LFound -> "found"
    LNotFound -> "not-found"
    LFailed -> "failed"

choiceName :: Choice -> T.Text
choiceName c =
  case c of
    CAttestApplied -> "attest-applied"
    CAttestNotApplied -> "attest-not-applied"
    CRetry -> "retry-acknowledged"
    CRetryUnacknowledged -> "retry-unacknowledged"

tshow :: Show a => a -> T.Text
tshow =
  T.pack . show

renderStep :: Step -> T.Text
renderStep s =
  case s of
    SClaim w now lease -> T.unwords ["claim", "who=" <> whoName w, "now=" <> tshow now, "lease=" <> tshow lease]
    SDispatch w r now -> T.unwords ["dispatch", "who=" <> whoName w, "gen=" <> refName r, "now=" <> tshow now]
    SObserve w r o -> T.unwords ["observe", "who=" <> whoName w, "gen=" <> refName r, "obs=" <> obsName o]
    SSettle w r -> T.unwords ["settle", "who=" <> whoName w, "gen=" <> refName r]
    SAbandon w -> T.unwords ["abandon", "who=" <> whoName w]
    SRecover w now a -> T.unwords ["recover", "who=" <> whoName w, "now=" <> tshow now, "active=" <> (if a then "true" else "false")]
    SReconcile w now l -> T.unwords ["reconcile", "who=" <> whoName w, "now=" <> tshow now, "lookup=" <> lookName l]
    SResolve w r c -> T.unwords ["resolve", "who=" <> whoName w, "gen=" <> refName r, "choice=" <> choiceName c]
    SLate o -> T.unwords ["late", "obs=" <> obsName o]

renderTrace :: Trace -> T.Text
renderTrace t =
  T.unlines (T.unwords ["trace", "variant=" <> tshow (traceVariant t), "budget=" <> tshow (traceBudget t)] : fmap renderStep (traceSteps t))

fromNames :: (Enum a, Bounded a) => (a -> T.Text) -> T.Text -> Maybe a
fromNames name text =
  L.find ((== text) . name) [minBound .. maxBound]

field :: T.Text -> [T.Text] -> Maybe T.Text
field key ws =
  L.find (T.isPrefixOf (key <> "=")) ws >>= T.stripPrefix (key <> "=")

number :: T.Text -> Maybe Integer
number text =
  if not (T.null text) && T.all (`L.elem` ("0123456789" :: String)) text
    then Just (T.foldl' (\acc c -> acc * 10 + toInteger (L.length (L.takeWhile (/= c) "0123456789"))) 0 text)
    else Nothing

parseStep :: T.Text -> Maybe Step
parseStep line =
  let
    ws = T.words line
    who = field "who" ws >>= fromNames whoName
    ref = field "gen" ws >>= fromNames refName
    now = field "now" ws >>= number
  in
    case ws of
      "claim" : _ -> SClaim <$> who <*> now <*> (field "lease" ws >>= number)
      "dispatch" : _ -> SDispatch <$> who <*> ref <*> now
      "observe" : _ -> SObserve <$> who <*> ref <*> (field "obs" ws >>= fromNames obsName)
      "settle" : _ -> SSettle <$> who <*> ref
      "abandon" : _ -> SAbandon <$> who
      "recover" : _ -> SRecover <$> who <*> now <*> (field "active" ws >>= \a -> if a == "true" then Just True else if a == "false" then Just False else Nothing)
      "reconcile" : _ -> SReconcile <$> who <*> now <*> (field "lookup" ws >>= fromNames lookName)
      "resolve" : _ -> SResolve <$> who <*> ref <*> (field "choice" ws >>= fromNames choiceName)
      "late" : _ -> SLate <$> (field "obs" ws >>= fromNames obsName)
      _ -> Nothing

parseTrace :: T.Text -> Maybe Trace
parseTrace text =
  case T.lines text of
    header : rest -> do
      let
        ws = T.words header
      variant <- field "variant" ws >>= number
      budget <- field "budget" ws >>= number
      parsed <- traverse parseStep rest
      Just (Trace (fromInteger variant) (fromInteger budget) parsed)
    [] -> Nothing

-- Running --------------------------------------------------------------------

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 19) (secondsToDiffTime 0)

at :: Integer -> UTCTime
at n =
  addUTCTime (fromInteger n) t0

principal :: Who -> Principal
principal w =
  case w of
    WHuman -> Human
    WSupervisor -> Supervisor
    WScheduler -> Scheduler
    WAgent -> Agent

startIntent :: Trace -> Either T.Text Intent
startIntent t = do
  spec <- either (Left . tshow) Right (mkEffectSpec "step" (terms (traceVariant t)) (traceBudget t))
  key <- either (Left . tshow) Right (mkEffectKey "first")
  intents <-
    either
      (Left . tshow)
      Right
      (newIntents sha256Hasher (SubjectWorkOrder (WorkOrderId (uuidFromWords 2 1))) 4 [(OperationId (uuidFromWords 4 1), IntentRequest key spec "p=1")])
  case intents of
    [i] -> Right i
    _ -> Left "expected one intent"

observation :: Obs -> Observation
observation o =
  case o of
    OApplied -> DestinationApplied "done"
    ONotApplied -> DestinationNotApplied "busy"
    ONoAnswer -> NoAnswer "timeout"

generationOf :: GenRef -> Intent -> Int
generationOf r i =
  case r of
    GCurrent -> intentGeneration i
    GOlder -> intentGeneration i - 1
    GNewer -> intentGeneration i + 1

-- | One step: the new intent, or the same one when the Kernel refuses.
apply :: Step -> Intent -> (Bool, Intent)
apply s i =
  case s of
    SClaim w now lease -> kernel (stepIntent i (Command (principal w) (IntentClaim "w1" (at now) (at (now + lease)))))
    SDispatch w r now -> kernel (stepIntent i (Command (principal w) (IntentDispatch (generationOf r i) (at now))))
    SObserve w r o -> kernel (stepIntent i (Command (principal w) (IntentObserve (generationOf r i) (observation o))))
    SSettle w r -> kernel (stepIntent i (Command (principal w) (IntentSettle (generationOf r i))))
    SAbandon w -> kernel (stepIntent i (Command (principal w) (IntentAbandon "stop")))
    SRecover w now active -> kernel (fmap recoveryIntent (recoverIntent i (Command (principal w) (RecoveryInput "w2" (at now) (at (now + 60)) active))))
    SReconcile w now l -> kernel (reconcileIntent i (Command (principal w) (ReconcileInput (at now) (lookupOf l))))
    SResolve w r c -> kernel (resolveIntent i (Command (principal w) (generationOf r i, resolutionOf c)))
    SLate o ->
      case judgeLateObservation i (observation o) of
        LateConflict j -> (True, j)
        LateConsistent -> (False, i)
 where
  kernel :: Either e Intent -> (Bool, Intent)
  kernel = either (const (False, i)) ((,) True)

lookupOf :: Look -> LookupResult
lookupOf l =
  case l of
    LFound -> LookupFound "done"
    LNotFound -> LookupNotFound
    LFailed -> LookupFailed "timeout"

resolutionOf :: Choice -> Resolution
resolutionOf c =
  case c of
    CAttestApplied -> AttestApplied "seen"
    CAttestNotApplied -> AttestNotApplied "none"
    CRetry -> RetryAcknowledgingDuplication True
    CRetryUnacknowledged -> RetryAcknowledgingDuplication False

-- | What a run tracks for the invariants.
data Run
  = Run
  { runIntent :: Intent
  , runAttested :: Bool
  , runDispatches :: Int
  , runRetries :: Int
  , runNow :: Integer
  , runStates :: [T.Text]
  }

stepTime :: Step -> Maybe Integer
stepTime s =
  case s of
    SClaim _ now _ -> Just now
    SDispatch _ _ now -> Just now
    SRecover _ now _ -> Just now
    SReconcile _ now _ -> Just now
    _ -> Nothing

terminal :: Intent -> Bool
terminal i =
  case intentState i of
    IntentSettled _ -> True
    IntentAbandoned _ -> True
    _ -> False

isDispatch :: Step -> Bool
isDispatch s =
  case s of
    SDispatch {} -> True
    _ -> False

stepWho :: Step -> Maybe Who
stepWho s =
  case s of
    SClaim w _ _ -> Just w
    SDispatch w _ _ -> Just w
    SObserve w _ _ -> Just w
    SSettle w _ -> Just w
    SAbandon w -> Just w
    SRecover w _ _ -> Just w
    SReconcile w _ _ -> Just w
    SResolve w _ _ -> Just w
    SLate _ -> Nothing

statusOf :: Run -> EffectStatus
statusOf run =
  effectStatus (StatusFacts (at (runNow run)) True (runAttested run)) (runIntent run)

-- | Runs a trace, checking every invariant after every step; Left names the first violation.
runTrace :: Trace -> Either T.Text Run
runTrace t = do
  i0 <- startIntent t
  L.foldl' (\acc (n, s) -> acc >>= check n s) (Right (Run i0 False 0 0 0 [intentStateName (intentState i0)])) (L.zip [1 :: Int ..] (traceSteps t))
 where
  unqueryable = traceVariant t == 4
  check n s run = do
    let
      i = runIntent run
      (accepted, j) = apply s i
      fail' what = Left (T.pack ("step " <> show n <> " (" <> T.unpack (renderStep s) <> "): " <> what))
      attested = runAttested run || (accepted && case s of SResolve _ _ CAttestApplied -> True; _ -> False)
      retries = runRetries run + (if accepted && isRetry s then 1 else 0)
      dispatches = runDispatches run + (if accepted && isDispatch s then 1 else 0)
      now = maybe (runNow run) (max (runNow run)) (stepTime s)
      next = Run j attested dispatches retries now (intentStateName (intentState j) : runStates run)
    when (accepted && stepWho s == Just WAgent) (fail' "an Agent was accepted")
    when (intentGeneration j < intentGeneration i) (fail' "the generation decreased")
    when (intentDispatches j /= intentDispatches i && not (accepted && isDispatch s && intentDispatches j == intentDispatches i + 1)) (fail' "dispatches changed other than by one dispatch")
    when (terminal i && j /= i) (fail' "a settled or abandoned intent changed")
    when (unqueryable && dispatches > 1 + retries) (fail' "an unqueryable intent was dispatched again without an acknowledged retry")
    case s of
      SResolve w r _ | accepted && (w /= WHuman || r /= GCurrent) -> fail' "a resolution was accepted from a non-Human or another generation"
      _ -> pure ()
    when (statusOf next == StatusPassed && not (settledApplied j && not attested)) (fail' "PASSED without a settled, unattested application")
    pure next

isRetry :: Step -> Bool
isRetry s =
  case s of
    SResolve _ _ CRetry -> True
    _ -> False

settledApplied :: Intent -> Bool
settledApplied i =
  case intentState i of
    IntentSettled (SettledApplied _) -> True
    _ -> False

digestOf :: T.Text -> T.Text
digestOf text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

-- Tests ----------------------------------------------------------------------

generatorTests :: TestTree
generatorTests =
  testGroup
    "the generator (checked before the freeze)"
    [ testCase "deterministic: the same seed gives the same traces" $
        fmap renderTrace (L.take traceCount (L.unfoldr (Just . genTrace) (Gen seed))) @?= fmap renderTrace traces
    , testCase "every trace renders and parses back to itself" $
        traverse_ (\t -> parseTrace (renderTrace t) @?= Just t) traces
    , testCase "the traces reach every intent state" $ do
        reached <- traverse (either (assertFailure . T.unpack) pure . runStatesOf) traces
        let
          names = L.nub (L.concat reached)
        traverse_
          (\n -> assertBool ("never reached: " <> T.unpack n) (n `L.elem` names))
          ["pending", "claimed", "dispatched", "confirmed-applied", "confirmed-not-applied", "outcome-unknown", "settled", "abandoned"]
    , testCase "the first trace's rendering has a golden SHA-256" $
        case traces of
          first : _ -> digestOf (renderTrace first) @?= goldenDigest
          [] -> assertFailure "no traces"
    ]
 where
  runStatesOf t = fmap runStates (runTraceLoose t)

-- | Runs without the invariants (for the generator's reach check before the freeze).
runTraceLoose :: Trace -> Either T.Text Run
runTraceLoose t = do
  i0 <- startIntent t
  pure (L.foldl' (\run s -> let (_, j) = apply s (runIntent run) in run {runIntent = j, runStates = intentStateName (intentState j) : runStates run}) (Run i0 False 0 0 0 [intentStateName (intentState i0)]) (traceSteps t))

goldenDigest :: T.Text
goldenDigest =
  "0918f1b651e0d545def0951c88ad2bbca6343195d6fde53600667b49ae1bc471"

invariantTests :: TestTree
invariantTests =
  testGroup
    "invariants after every step"
    [ testCase "300 traces, seed 20261019: authority, fencing, budgets and PASSED hold throughout" $
        traverse_ (\t -> either (\e -> assertFailure (T.unpack e <> "\n" <> T.unpack (renderTrace t))) (const (pure ())) (runTrace t)) traces
    ]

replayTests :: TestTree
replayTests =
  testGroup
    "replay"
    [ testCase "each trace replayed from its rendered text ends in the same intent and status" $
        traverse_ replays traces
    ]

replays :: Trace -> Assertion
replays t = do
  original <- either (assertFailure . T.unpack) pure (runTrace t)
  parsed <- maybe (assertFailure "the trace did not parse back") pure (parseTrace (renderTrace t))
  replayed <- either (assertFailure . T.unpack) pure (runTrace parsed)
  runIntent replayed @?= runIntent original
  statusOf replayed @?= statusOf original
