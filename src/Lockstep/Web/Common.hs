{-# LANGUAGE QuasiQuotes #-}

-- | Shared path segments. Derived from Launchpad.Routes.Common (11886bf).
module Lockstep.Web.Common
  ( apiRootPath
  ) where

import Data.String.Interpolate qualified as Interpolate
import Data.Text qualified as T

apiRootPath :: T.Text
apiRootPath = [Interpolate.i|api|]
