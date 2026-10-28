{- | The coding transaction engine (contract C-P4.6 E1–E7). Pre-freeze stub:
the final types; nothing is started or advanced.
-}
module Lockstep.Application.Engine
  ( Engine (..)
  , StepReport (..)
  , TransactionView (..)
  , RecordView (..)
  , InvocationView (..)
  , startTransaction
  , advance
  , transactionView
  , transactionForWorkOrder
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Effects.Roles (Adapter, Runner)
import Lockstep.Kernel.Roles (Role)

data Engine
  = Engine
  { engineRunner :: Runner
  , engineAdapter :: Role -> Int -> Maybe Adapter
  }

data StepReport
  = Stepped T.Text TransactionView
  | Idle T.Text TransactionView
  deriving (Eq, Show)

data RecordView
  = RecordView
  { recordSequence :: Int
  , recordKind :: T.Text
  , recordPrincipal :: T.Text
  , recordStage :: T.Text
  , recordBody :: T.Text
  }
  deriving (Eq, Show)

data InvocationView
  = InvocationView
  { invocationId :: T.Text
  , invocationStage :: T.Text
  , invocationWhat :: T.Text
  , invocationRunner :: T.Text
  , invocationAdapter :: T.Text
  , invocationArgv :: T.Text
  , invocationOutcome :: Maybe T.Text
  , invocationExit :: Maybe Int
  }
  deriving (Eq, Show)

data TransactionView
  = TransactionView
  { viewId :: T.Text
  , viewWorkOrder :: T.Text
  , viewTask :: T.Text
  , viewEngineer :: T.Text
  , viewFolder :: T.Text
  , viewState :: T.Text
  , viewStage :: T.Text
  , viewHalt :: Maybe T.Text
  , viewBasis :: Maybe T.Text
  , viewBranch :: Maybe T.Text
  , viewCandidates :: Int
  , viewAttempts :: Int
  , viewRecords :: [RecordView]
  , viewInvocations :: [InvocationView]
  }
  deriving (Eq, Show)

transactionView :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe TransactionView))
transactionView _ _ =
  pure (Right Nothing)

transactionForWorkOrder :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe TransactionView))
transactionForWorkOrder _ _ =
  pure (Right Nothing)

startTransaction :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text TransactionView))
startTransaction _ _ =
  pure (Right (Left (T.pack "not-implemented")))

advance :: DatabaseRuntime -> Engine -> T.Text -> IO (Either NotReadyReason (Either T.Text StepReport))
advance _ _ _ =
  pure (Right (Left (T.pack "not-implemented")))
