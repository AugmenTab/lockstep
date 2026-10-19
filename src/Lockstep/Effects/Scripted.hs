{- | Scripted, in-process effect destinations (contract C-P2.6 X3). Model-free
stand-ins for an external destination: each records every application it
makes, and its adapter answers by a script, one step per call. A destination
behind an idempotent spec deduplicates by operation id, as DG-04 binding
requirement 2 demands of a real one: a repeat with the same parameters gets
the first result and applies nothing; a repeat with other parameters is
refused. Its keys never expire within the process.
-}
module Lockstep.Effects.Scripted
  ( ScriptedDestination
  , newScriptedDestination
  , Application (..)
  , destinationApplications
  , ScriptStep (..)
  , scriptedAdapter
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Exception (throwIO)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO.Error (userError)
import Text.Show (Show)

import Lockstep.Effects.Executor (DestinationAnswer (..), EffectAdapter (..))
import Lockstep.Kernel.Effect (EffectClass (..), EffectSpec, OperationId, effectSpecClass)

data Application
  = Application
  { appliedOperation :: OperationId
  , appliedParameters :: T.Text
  }
  deriving (Eq, Show)

-- | Applications, newest first, with the result each answered (for deduplication).
newtype ScriptedDestination
  = ScriptedDestination (MVar [(Application, T.Text)])

newScriptedDestination :: IO ScriptedDestination
newScriptedDestination =
  ScriptedDestination <$> newMVar []

destinationApplications :: ScriptedDestination -> IO [Application]
destinationApplications (ScriptedDestination store) =
  L.reverse . fmap fst <$> readMVar store

data ScriptStep
  = StepApply T.Text
  | StepRefuse T.Text
  | StepApplyThenHang T.Text
  | StepHang
  | StepApplyThenFail
  | StepFail
  | StepMalformed
  deriving (Eq, Show)

scriptedAdapter :: EffectSpec -> ScriptedDestination -> [ScriptStep] -> IO EffectAdapter
scriptedAdapter spec destination script = do
  steps <- newMVar script
  pure (EffectAdapter spec (run (effectSpecClass spec == Idempotent) destination steps))

data Outcome
  = Answer DestinationAnswer
  | HangAfter
  | FailAfter

run :: Bool -> ScriptedDestination -> MVar [ScriptStep] -> OperationId -> T.Text -> IO DestinationAnswer
run deduplicates (ScriptedDestination store) steps operation parameters = do
  outcome <-
    modifyMVar store $ \applied ->
      case L.find ((== operation) . appliedOperation . fst) applied of
        Just (previous, result)
          | deduplicates ->
              pure
                ( applied
                , Answer $
                    if appliedParameters previous == parameters
                      then AnswerApplied result
                      else AnswerNotApplied (T.pack "changed-parameters")
                )
        _ -> do
          step <- modifyMVar steps (\s -> pure (L.drop 1 s, nextStep s))
          pure (perform applied step)
  case outcome of
    Answer answer -> pure answer
    HangAfter -> threadDelay 3600000000 >> throwIO (userError "a scripted hang ended")
    FailAfter -> throwIO (userError "scripted failure")
 where
  application result applied =
    (Application operation parameters, result) : applied
  perform applied step =
    case step of
      StepApply result -> (application result applied, Answer (AnswerApplied result))
      StepRefuse reason -> (applied, Answer (AnswerNotApplied reason))
      StepApplyThenHang result -> (application result applied, HangAfter)
      StepHang -> (applied, HangAfter)
      StepApplyThenFail -> (application (T.pack "applied") applied, FailAfter)
      StepFail -> (applied, FailAfter)
      StepMalformed -> (application (T.pack "applied") applied, Answer (AnswerApplied T.empty))

nextStep :: [ScriptStep] -> ScriptStep
nextStep script =
  case script of
    step : _ -> step
    [] -> StepApply (T.pack "ok")
