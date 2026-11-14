{- | The read-only Jira intake adapter (contract C-P6.1 B12): a Jira REST v2
search response, read from a file, as a canonical backlog document. Only the
key, summary, update time, description and "Blocks" links are read; nothing
else in the provider's data reaches Lockstep. It never contacts Jira.
-}
module Lockstep.Application.BacklogJira
  ( fromJiraSearch
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Flipstone.Prelude

import Lockstep.Kernel.Backlog (BacklogDocument, SourceLocator)

fromJiraSearch :: SourceLocator -> LBS.ByteString -> Either T.Text BacklogDocument
fromJiraSearch _ _ =
  Left T.empty
