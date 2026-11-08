{- | The operator configuration file named by @LOCKSTEP_CONFIG@ (contract
C-P1.2 E2). Derived from Launchpad.Config (11886bf) with only the database block
kept; unknown keys are refused rather than ignored, so a leftover template
block cannot be silently carried.
-}
module Lockstep.Foundation.SystemConfig
  ( Secret
  , mkSecret
  , revealSecret
  , DatabaseConfig (..)
  , SystemConfig (..)
  , ConfigError (..)
  , decodeSystemConfig
  , loadSystemConfig
  , renderConfigError
  ) where

import Control.Exception (IOException, try)
import Data.Bits ((.&.), (.|.))
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Fleece.Aeson qualified as FA
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude
import System.IO (FilePath)
import System.Posix.Files (fileMode, getFileStatus, groupModes, otherModes)
import Text.Show (Show (show))

import Lockstep.Foundation.Config (Port, mkPort)

-- | A secret value. 'show' never reveals it.
newtype Secret
  = Secret T.Text

instance Show Secret where
  show _ = "<redacted>"

mkSecret :: T.Text -> Secret
mkSecret =
  Secret

revealSecret :: Secret -> T.Text
revealSecret (Secret value) =
  value

data DatabaseConfig
  = DatabaseConfig
  { dbHost :: T.Text
  , dbPort :: Port
  , dbName :: T.Text
  , dbUser :: T.Text
  , dbPassword :: Secret
  }
  deriving (Show)

newtype SystemConfig
  = SystemConfig
  { databaseConfig :: DatabaseConfig
  }
  deriving (Show)

data ConfigError
  = ConfigUnreadable String
  | ConfigInvalid String
  | ConfigUnknownKeys [T.Text]
  | ConfigInsecurePermissions FilePath
  deriving (Eq, Show)

renderConfigError :: ConfigError -> String
renderConfigError err =
  case err of
    ConfigUnreadable reason ->
      "configuration file cannot be read: " <> reason
    ConfigInvalid reason ->
      "configuration file is invalid: " <> reason
    ConfigUnknownKeys keys ->
      "configuration file has unknown keys: " <> L.intercalate ", " (fmap T.unpack keys)
    ConfigInsecurePermissions path ->
      "configuration file "
        <> path
        <> " is readable or writable by group or others; its permissions must be 0600"

-- The decoded JSON before validation, with any unknown keys captured.
data RawDatabase
  = RawDatabase
  { rawHost :: T.Text
  , rawPort :: Integer
  , rawName :: T.Text
  , rawUser :: T.Text
  , rawPassword :: T.Text
  , rawDatabaseExtra :: Map.Map T.Text FC.AnyJSON
  }

data RawSystem
  = RawSystem
  { rawDatabase :: RawDatabase
  , rawSystemExtra :: Map.Map T.Text FC.AnyJSON
  }

rawDatabaseSchema :: FC.Fleece t => FC.Schema t RawDatabase
rawDatabaseSchema =
  FC.object $
    FC.additional
      ( FC.constructor RawDatabase
          #+ FC.required "host" rawHost FC.text
          #+ FC.required "port" rawPort FC.integer
          #+ FC.required "name" rawName FC.text
          #+ FC.required "username" rawUser FC.text
          #+ FC.required "password" rawPassword FC.text
      )
      (FC.additionalFields rawDatabaseExtra FC.anyJSON)

rawSystemSchema :: FC.Fleece t => FC.Schema t RawSystem
rawSystemSchema =
  FC.object $
    FC.additional
      ( FC.constructor RawSystem
          #+ FC.required "database" rawDatabase rawDatabaseSchema
      )
      (FC.additionalFields rawSystemExtra FC.anyJSON)

decodeSystemConfig :: LBS.ByteString -> Either ConfigError SystemConfig
decodeSystemConfig bytes =
  case FA.decode rawSystemSchema bytes of
    Left reason -> Left (ConfigInvalid reason)
    Right raw -> validate raw

validate :: RawSystem -> Either ConfigError SystemConfig
validate raw =
  let
    db = rawDatabase raw
    unknown extra =
      if Map.null extra
        then Right ()
        else Left (ConfigUnknownKeys (Map.keys extra))
  in
    do
      unknown (rawSystemExtra raw)
      unknown (rawDatabaseExtra db)
      port <-
        maybe
          (Left (ConfigInvalid "database.port must be between 1 and 65535"))
          Right
          (mkPort (rawPort db))
      pure
        SystemConfig
          { databaseConfig =
              DatabaseConfig
                { dbHost = rawHost db
                , dbPort = port
                , dbName = rawName db
                , dbUser = rawUser db
                , dbPassword = Secret (rawPassword db)
                }
          }

{- | Reads and validates the file. It must not be readable or writable by group
or others (contract C-P1.2 E3).
-}
loadSystemConfig :: FilePath -> IO (Either ConfigError SystemConfig)
loadSystemConfig path = do
  statusOrErr <- try (getFileStatus path)
  case statusOrErr of
    Left err ->
      pure (Left (ConfigUnreadable (show (err :: IOException))))
    Right status ->
      if fileMode status .&. (groupModes .|. otherModes) /= 0
        then pure (Left (ConfigInsecurePermissions path))
        else do
          bytesOrErr <- try (LBS.readFile path)
          pure $
            case bytesOrErr of
              Left err -> Left (ConfigUnreadable (show (err :: IOException)))
              Right bytes -> decodeSystemConfig bytes
