{- | Warp settings. Derived from Launchpad.REPL.warpSettings (11886bf), with the
bind host taken from the configuration (loopback only) instead of Warp's
all-interfaces default.
-}
module Lockstep.Web.Server
  ( serverSettings
  ) where

import Data.String (fromString)
import Flipstone.Prelude
import Network.Wai.Handler.Warp qualified as Warp
import System.Posix.Signals qualified as Signals

import Lockstep.Foundation.Config (ServeConfig (..), bindHostAddress, portNumber)

serverSettings :: ServeConfig -> Warp.Settings
serverSettings serveConfig =
  Warp.setHost (fromString (bindHostAddress (serveHost serveConfig)))
    . Warp.setPort (portNumber (servePort serveConfig))
    . Warp.setGracefulShutdownTimeout (Just 3)
    . Warp.setInstallShutdownHandler shutdownHandler
    $ Warp.defaultSettings

shutdownHandler :: IO () -> IO ()
shutdownHandler closeSocket =
  void $
    Signals.installHandler Signals.sigTERM (Signals.Catch closeSocket) Nothing
