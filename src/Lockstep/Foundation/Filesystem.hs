{- | Filesystem checks shared by the Supervisor's writes into a working tree
(the Git snapshot and the engine's extra files).
-}
module Lockstep.Foundation.Filesystem
  ( linkedOrUnreadable
  ) where

import Control.Exception (try)
import Flipstone.Prelude
import System.Directory (pathIsSymbolicLink)
import System.IO (FilePath)
import System.IO.Error (isDoesNotExistError)

{- | Whether a path on the way to a write must stop it: it is a symbolic
link, or it cannot be checked. A path that is not there yet is no link; any
other failure to check it fails closed.
-}
linkedOrUnreadable :: FilePath -> IO Bool
linkedOrUnreadable path = do
  checked <- try (pathIsSymbolicLink path)
  pure $
    case checked of
      Right isLink -> isLink
      Left e -> not (isDoesNotExistError e)
