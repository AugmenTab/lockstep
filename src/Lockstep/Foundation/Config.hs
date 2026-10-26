module Lockstep.Foundation.Config
  ( BindHost (Loopback)
  , bindHostAddress
  , Port
  , mkPort
  , portNumber
  , defaultPort
  , defaultControlPort
  , ServeConfig (..)
  , defaultServeConfig
  , loopbackAuthority
  , loopbackOrigin
  ) where

import Flipstone.Prelude
import Text.Show (Show, show)

{- | The interface `lockstep serve` binds. There is deliberately only one
constructor: a public bind is unrepresentable (contract C-P1.1 D1).
-}
data BindHost
  = Loopback
  deriving (Eq, Show)

bindHostAddress :: BindHost -> String
bindHostAddress host =
  case host of
    Loopback -> "127.0.0.1"

-- | A TCP port in 1..65535. Construct with 'mkPort'.
newtype Port
  = Port Int
  deriving (Eq, Show)

mkPort :: Integer -> Maybe Port
mkPort n =
  if n >= 1 && n <= 65535
    then Just (Port (fromInteger n))
    else Nothing

portNumber :: Port -> Int
portNumber (Port n) =
  n

-- | The documented default port (contract C-P1.1 D2).
defaultPort :: Port
defaultPort =
  Port 8000

-- | The control pane's default port (contract C-P3.1 L3).
defaultControlPort :: Port
defaultControlPort =
  Port 8100

data ServeConfig
  = ServeConfig
  { serveHost :: BindHost
  , servePort :: Port
  }
  deriving (Eq, Show)

defaultServeConfig :: ServeConfig
defaultServeConfig =
  ServeConfig
    { serveHost = Loopback
    , servePort = defaultPort
    }

{- | The exact @Host@ a browser sends for the loopback service on this port:
@127.0.0.1:N@, or @127.0.0.1@ for the default HTTP port 80 (contract C-P1.3
E7, decision D-1a).
-}
loopbackAuthority :: Port -> String
loopbackAuthority (Port n) =
  if n == 80
    then bindHostAddress Loopback
    else bindHostAddress Loopback <> ":" <> show n

-- | The exact @Origin@ a browser sends for pages of the loopback service.
loopbackOrigin :: Port -> String
loopbackOrigin port =
  "http://" <> loopbackAuthority port
