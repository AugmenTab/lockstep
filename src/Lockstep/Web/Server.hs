{- | Warp settings. Derived from Launchpad.REPL.warpSettings (11886bf), with the
bind host taken from the configuration (loopback only) instead of Warp's
all-interfaces default.
-}
module Lockstep.Web.Server
  ( serverSettings
  , serverSettingsWith
  ) where

import Data.String (fromString)
import Flipstone.Prelude
import Network.Wai.Handler.Warp qualified as Warp
import System.Posix.Signals qualified as Signals

import Lockstep.Foundation.Config (ServeConfig (..), bindHostAddress, portNumber)

serverSettings :: ServeConfig -> Warp.Settings
serverSettings =
  serverSettingsWith (pure ())

{- | As 'serverSettings', running @onShutdown@ first when SIGTERM arrives
(C-P1.5 E5: the dispatcher must stop between steps before Warp's graceful
shutdown, which can wait for idle keep-alive connections).
-}
serverSettingsWith :: IO () -> ServeConfig -> Warp.Settings
serverSettingsWith onShutdown serveConfig =
  Warp.setHost (fromString (bindHostAddress (serveHost serveConfig)))
    . Warp.setPort (portNumber (servePort serveConfig))
    . Warp.setGracefulShutdownTimeout (Just 3)
    . Warp.setInstallShutdownHandler (shutdownHandler onShutdown)
    $ Warp.defaultSettings

shutdownHandler :: IO () -> IO () -> IO ()
shutdownHandler onShutdown closeSocket =
  void $
    Signals.installHandler Signals.sigTERM (Signals.Catch (onShutdown >> closeSocket)) Nothing
