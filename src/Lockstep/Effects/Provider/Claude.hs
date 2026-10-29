{- | The first live provider's role adapter (contract C-P4.L L1). STUB for the
freeze of C-P4.L: the names the frozen tests use, nothing built.
-}
module Lockstep.Effects.Provider.Claude
  ( ProviderConfig (..)
  , supportedModels
  , supportedEfforts
  , parseProviderLine
  , readProviderFile
  , claudeAdapter
  , claudeArgv
  , sessionIdOf
  , roleInstructions
  ) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO (FilePath)
import Text.Show (Show)

import Lockstep.Effects.Roles (Adapter (..), View, Workspace)
import Lockstep.Kernel.Roles (Role)

data ProviderConfig
  = ProviderConfig
  { providerModel :: T.Text
  , providerEffort :: T.Text
  }
  deriving (Eq, Show)

supportedModels :: [T.Text]
supportedModels =
  []

supportedEfforts :: [T.Text]
supportedEfforts =
  []

parseProviderLine :: BS.ByteString -> Either T.Text ProviderConfig
parseProviderLine _ =
  Left (T.pack "not-implemented")

readProviderFile :: FilePath -> IO (Maybe (Either T.Text ProviderConfig))
readProviderFile _ =
  pure Nothing

claudeAdapter :: ProviderConfig -> Role -> Adapter
claudeAdapter _ _ =
  Adapter
    { adapterName = T.pack "claude-code"
    , adapterPrepare = \_ -> pure []
    }

claudeArgv :: ProviderConfig -> Workspace -> [T.Text]
claudeArgv _ _ =
  []

sessionIdOf :: T.Text -> T.Text
sessionIdOf name =
  name

roleInstructions :: Role -> View -> T.Text
roleInstructions _ _ =
  T.empty
