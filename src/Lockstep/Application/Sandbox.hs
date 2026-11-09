{- | Sandbox effects: model-free effects over a durable simulated destination
(contract C-P2.8 V5). One effect per class, each declaring its exact spec. The
destination lives in its own tables and every adapter writes in its own
transaction, never the ledger's, so a process killed between the effect and
its conclusion leaves exactly what a crashed worker would. Nothing here
invokes a model, a provider, Git or the network.
-}
module Lockstep.Application.Sandbox
  ( sandboxRequest
  , sandboxAdapters
  , sandboxReconcilers
  , sandboxApplications
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, throwIO)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), readinessCode, withDatabase)
import Lockstep.Application.LedgerRefusal (LedgerFailure (..), LedgerRefusal (UnknownSandboxEffect), refusalFailure)
import Lockstep.Effects.Executor (DestinationAnswer (..), EffectAdapter (..))
import Lockstep.Effects.Reconciler (EffectReconciler (..), LookupAnswer (..))
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectClass (..)
  , EffectSpec
  , IdempotencyTerms (..)
  , IntentRequest (..)
  , LookupTerms (..)
  , OperationId
  , effectSpecClass
  , effectSpecName
  , mkEffectKey
  , mkEffectSpec
  )
import Lockstep.Persistence.Sandbox qualified as Store

-- | The catalogue: name, class terms, retry budget.
catalogue :: [(String, ClassTerms, Int)]
catalogue =
  [ ("sandbox-repeatable", TermsRepeatable, 1)
  , ("sandbox-idempotent", TermsIdempotent (IdempotencyTerms 86400 True), 1)
  , ("sandbox-queryable", TermsQueryable (LookupTerms True True), 1)
  , ("sandbox-unqueryable", TermsUnqueryable, 0)
  ]

specs :: [EffectSpec]
specs =
  [s | (name, terms, budget) <- catalogue, Right s <- [mkEffectSpec (T.pack name) terms budget]]

data Mode
  = Apply
  | Refuse
  | Hang
  | ApplyThenHang
  deriving (Eq)

modes :: [(String, Mode)]
modes =
  [("apply", Apply), ("refuse", Refuse), ("hang", Hang), ("apply-then-hang", ApplyThenHang)]

-- | @NAME@ or @NAME:MODE@: the intent request for one sandbox effect, with parameters @mode=MODE@.
sandboxRequest :: T.Text -> Either LedgerFailure IntentRequest
sandboxRequest text =
  let
    (name, rest) = T.breakOn (T.pack ":") text
    modeName = if T.null rest then T.pack "apply" else T.drop 1 rest
  in
    case (L.find ((== name) . effectSpecName) specs, L.lookup (T.unpack modeName) modes, mkEffectKey name) of
      (Just spec, Just _, Right key) -> Right (IntentRequest key spec (T.pack "mode=" <> modeName))
      _ -> Left (refusalFailure (UnknownSandboxEffect text [T.pack n | (n, _, _) <- catalogue]))

{- | Why a sandbox adapter gave no answer. It is thrown, and the executor
reports any adapter exception as @adapter-failed@ (C-P2.6 X5).
-}
data SandboxFailure
  = DestinationUnavailable NotReadyReason
  | HangEnded
  | UnreadableParameters T.Text
  deriving (Show)

instance Exception SandboxFailure

-- | One transaction on the destination; a failure is a 'SandboxFailure'.
destination :: DatabaseRuntime -> O.Orville a -> IO a
destination runtime action = do
  result <- withDatabase runtime (O.withTransaction action)
  either (throwIO . DestinationUnavailable) pure result

hang :: IO a
hang =
  threadDelay 3600000000 >> throwIO HangEnded

applied :: DestinationAnswer
applied =
  AnswerApplied (T.pack "applied")

sandboxAdapters :: DatabaseRuntime -> IO [EffectAdapter]
sandboxAdapters runtime =
  pure (fmap (adapter runtime) specs)

adapter :: DatabaseRuntime -> EffectSpec -> EffectAdapter
adapter runtime spec =
  EffectAdapter spec $ \operation parameters -> do
    mode <-
      maybe (throwIO (UnreadableParameters parameters)) pure $
        T.stripPrefix (T.pack "mode=") parameters >>= \m -> L.lookup (T.unpack m) modes
    let
      op = operation
      name = effectSpecName spec
    case effectSpecClass spec of
      Idempotent -> do
        -- an operation id already applied answers at once, whatever its mode
        existing <- destination runtime (Store.keyParameters op)
        case existing of
          Just first
            | first == parameters -> pure applied
            | otherwise -> pure (AnswerNotApplied (T.pack "changed-parameters"))
          Nothing ->
            perform mode $ do
              destination runtime $ do
                isNew <- Store.insertKey op parameters
                when isNew (Store.recordApplication op name parameters)
              pure applied
      Queryable -> do
        -- a fenced operation id never applies, whatever its mode
        existing <- destination runtime (Store.queryableOutcome op)
        case existing of
          Just o | o == fenced -> pure fencedAnswer
          Just _ -> pure applied
          Nothing ->
            perform mode $ do
              outcome <- destination runtime $ do
                (o, isNew) <- Store.settleQueryable op (T.pack "applied")
                when (isNew && o == T.pack "applied") (Store.recordApplication op name parameters)
                pure o
              pure (if outcome == fenced then fencedAnswer else applied)
      _ ->
        perform mode $ do
          destination runtime (Store.recordApplication op name parameters)
          pure applied
 where
  perform mode apply =
    case mode of
      Refuse -> pure (AnswerNotApplied (T.pack "refused by the sandbox"))
      Hang -> hang
      Apply -> apply
      ApplyThenHang -> apply >> hang

fenced :: T.Text
fenced =
  T.pack "fenced"

fencedAnswer :: DestinationAnswer
fencedAnswer =
  AnswerNotApplied (T.pack "fenced by an earlier lookup")

-- | The lookup for the queryable sandbox effect: a lookup of an absent operation id fences it.
sandboxReconcilers :: DatabaseRuntime -> IO [EffectReconciler]
sandboxReconcilers runtime =
  pure
    [ EffectReconciler spec $ \operation _ -> do
        (outcome, _) <- destination runtime (Store.settleQueryable operation (T.pack "fenced"))
        pure (if outcome == T.pack "applied" then LookupApplied (T.pack "applied") else LookupAbsent)
    | spec <- specs
    , effectSpecClass spec == Queryable
    ]

sandboxApplications :: DatabaseRuntime -> IO (Either LedgerFailure [(OperationId, T.Text, Int)])
sandboxApplications runtime = do
  result <- withDatabase runtime Store.applicationCounts
  pure $
    case result of
      Left reason -> Left (LedgerUnavailable (readinessCode (NotReady reason)))
      Right rows -> Right [(op, effect, fromIntegral n) | (op, effect, n) <- rows]
