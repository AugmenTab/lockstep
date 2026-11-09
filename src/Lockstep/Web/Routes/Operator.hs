{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The operator route tree (contracts C-P1.3 E3–E8, C-P1.4 E9, C-P1.5 E7,
C-P2.7, C-P2.8): route types, each path defined once as a builder polymorphic
in the router, and the links the operator pages use, generated from the same
builders. The addresses are the frozen ones.
-}
module Lockstep.Web.Routes.Operator
  ( Routes
  , routes
  , SignInConfirm (..)
  , SignInExchange (..)
  , OperatorHome (..)
  , SignOut (..)
  , RenameCommand (..)
  , ReceiptView (..)
  , QueueCommand (..)
  , QueueForm (..)
  , CenterView (..)
  , LedgerView (..)
  , signInAction
  , operatorHomeLink
  , signOutAction
  , renameAction
  , receiptLink
  , queueAction
  , queueFormLink
  , centerLink
  , ledgerLink
  ) where

import Beeline.Routing ((/+), (/-), (/:))
import Beeline.Routing qualified as R
import Brigid.Types qualified as B
import Flipstone.Prelude
import Shrubbery qualified

import Lockstep.Kernel.Identity (ReceiptId)
import Lockstep.Web.Routes.Params (receiptIdParam)

type Routes =
  Shrubbery.Union
    [ SignInConfirm
    , SignInExchange
    , OperatorHome
    , SignOut
    , RenameCommand
    , ReceiptView
    , QueueCommand
    , QueueForm
    , CenterView
    , LedgerView
    ]

routes :: R.Router r => r Routes
routes =
  R.routeList $
    R.get (signIn SignInConfirm)
      /: R.post (signIn SignInExchange)
      /: R.get operatorHome
      /: R.post signOut
      /: R.post rename
      /: R.get receiptView
      /: R.post queue
      /: R.get queueForm
      /: R.get center
      /: R.get ledger
      /: R.emptyRoutes

operatorRoot :: R.Router r => a -> R.Builder r route a
operatorRoot con =
  R.make con /- "operator"

-- | The confirm page (GET) and the exchange (POST) share the address.
signIn :: R.Router r => route -> R.Builder r route route
signIn route =
  operatorRoot route /- "sign-in"

data SignInConfirm = SignInConfirm

data SignInExchange = SignInExchange

signInAction :: B.RelativeURL B.Post
signInAction =
  B.post SignInExchange (signIn SignInExchange)

data OperatorHome = OperatorHome

operatorHome :: R.Router r => R.Builder r OperatorHome OperatorHome
operatorHome =
  operatorRoot OperatorHome

operatorHomeLink :: B.RelativeURL B.Get
operatorHomeLink =
  B.get OperatorHome operatorHome

data SignOut = SignOut

signOut :: R.Router r => R.Builder r SignOut SignOut
signOut =
  operatorRoot SignOut /- "sign-out"

signOutAction :: B.RelativeURL B.Post
signOutAction =
  B.post SignOut signOut

data RenameCommand = RenameCommand

rename :: R.Router r => R.Builder r RenameCommand RenameCommand
rename =
  operatorRoot RenameCommand /- "commands" /- "rename-workspace"

renameAction :: B.RelativeURL B.Post
renameAction =
  B.post RenameCommand rename

newtype ReceiptView = ReceiptView {receiptViewId :: ReceiptId}

receiptView :: R.Router r => R.Builder r ReceiptView ReceiptView
receiptView =
  operatorRoot ReceiptView /- "receipts" /+ R.Param receiptIdParam receiptViewId

receiptLink :: ReceiptId -> B.RelativeURL B.Get
receiptLink rid =
  B.get (ReceiptView rid) receiptView

data QueueCommand = QueueCommand

queue :: R.Router r => R.Builder r QueueCommand QueueCommand
queue =
  operatorRoot QueueCommand /- "commands" /- "queue-noop"

queueAction :: B.RelativeURL B.Post
queueAction =
  B.post QueueCommand queue

data QueueForm = QueueForm

queueForm :: R.Router r => R.Builder r QueueForm QueueForm
queueForm =
  operatorRoot QueueForm /- "jobs" /- "new"

queueFormLink :: B.RelativeURL B.Get
queueFormLink =
  B.get QueueForm queueForm

data CenterView = CenterView

center :: R.Router r => R.Builder r CenterView CenterView
center =
  operatorRoot CenterView /- "center"

centerLink :: B.RelativeURL B.Get
centerLink =
  B.get CenterView center

data LedgerView = LedgerView

ledger :: R.Router r => R.Builder r LedgerView LedgerView
ledger =
  operatorRoot LedgerView /- "ledger"

ledgerLink :: B.RelativeURL B.Get
ledgerLink =
  B.get LedgerView ledger
