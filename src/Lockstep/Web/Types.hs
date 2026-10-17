{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | The request-handling monad. Derived from Launchpad.Types (11886bf), with
the removals listed in ARCHITECTURE §3 and contract C-P1.1 D7/D8. It lives in
Web (contract C-P1.2 E10) because it carries the WAI request and an
Application database handle.
-}
module Lockstep.Web.Types
  ( Lockstep
  , runLockstep
  , AppContext (..)
  , getConfig
  , getDatabase
  , log
  ) where

import Control.Exception.Safe (MonadCatch, MonadThrow)
import Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import Data.String.Interpolate qualified as Interpolate
import Flipstone.Prelude
import Network.Wai qualified as Wai
import Orb qualified
import System.Log.FastLogger qualified as FL
import Text.Show (show)
import UnliftIO (MonadUnliftIO)

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Foundation.Config (ServeConfig)

type role Lockstep nominal

newtype Lockstep a
  = Lockstep
  { unLockstep :: ReaderT AppContext IO a
  }
  deriving
    ( Applicative
    , Functor
    , Monad
    , MonadCatch
    , MonadIO
    , MonadReader AppContext
    , MonadThrow
    , MonadUnliftIO
    )

instance Orb.HasLogger Lockstep where
  log exception =
    log $ "EXCEPTION " <> show exception

instance Orb.HasRequest Lockstep where
  request = asks request

instance Orb.HasRespond Lockstep where
  respond = asks respond

runLockstep :: AppContext -> Lockstep a -> IO a
runLockstep ctx action =
  runReaderT (unLockstep action) ctx

data AppContext
  = AppContext
  { config :: ServeConfig
  , database :: Maybe DatabaseRuntime
  , request :: Wai.Request
  , respond :: Wai.Response -> IO Wai.ResponseReceived
  , logger :: FL.LogStr -> IO ()
  }

getConfig :: (ServeConfig -> a) -> Lockstep a
getConfig getter =
  asks (getter . config)

getDatabase :: Lockstep (Maybe DatabaseRuntime)
getDatabase =
  asks database

log :: FL.ToLogStr msg => msg -> Lockstep ()
log msg = do
  appLogger <- asks logger
  liftIO . appLogger $ FL.toLogStr msg <> [Interpolate.i|\n|]
