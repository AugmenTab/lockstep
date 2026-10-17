{- | libpq connection settings for a 'DatabaseConfig'. Derived from
Launchpad.Config.dbConnectionOptions (11886bf), plus a connect timeout.
-}
module Lockstep.Persistence.Connection
  ( connectionString
  , poolOptions
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (show)

import Lockstep.Foundation.Config (portNumber)
import Lockstep.Foundation.SystemConfig (DatabaseConfig (..), revealSecret)

-- | A libpq conninfo string. It contains the password: never log it.
connectionString :: DatabaseConfig -> String
connectionString config =
  let
    connOpt key value =
      key <> "=" <> quoteConnInfoValue value
  in
    L.unwords
      [ connOpt "host" (T.unpack (dbHost config))
      , connOpt "port" (show (portNumber (dbPort config)))
      , connOpt "dbname" (T.unpack (dbName config))
      , connOpt "user" (T.unpack (dbUser config))
      , connOpt "password" (T.unpack (revealSecret (dbPassword config)))
      , connOpt "connect_timeout" "3"
      , connOpt "application_name" "lockstep"
      ]

quoteConnInfoValue :: String -> String
quoteConnInfoValue value =
  let
    escapeChar c =
      case c of
        '\'' -> "\\'"
        '\\' -> "\\\\"
        _ -> [c]
  in
    "'" <> foldMap escapeChar value <> "'"

poolOptions :: DatabaseConfig -> O.ConnectionOptions
poolOptions config =
  O.ConnectionOptions
    { O.connectionString = connectionString config
    , O.connectionNoticeReporting = O.DisableNoticeReporting
    , O.connectionPoolStripes = O.OneStripePerCapability
    , O.connectionPoolLingerTime = 10
    , O.connectionPoolMaxConnections = O.MaxConnectionsPerStripe 1
    }
