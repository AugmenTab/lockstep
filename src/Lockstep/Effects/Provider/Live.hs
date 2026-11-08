{- | The live provider's construction (contract C-P4.L L1; C-P1.7 E3, the
guard's construction gate): the one place where the live runner and the Claude
Code adapter are put together. Only the service's entry point imports it
(@scripts/lib/check-guard@ (c)); tests use the parts.
-}
module Lockstep.Effects.Provider.Live
  ( liveRoles
  ) where

import Flipstone.Prelude

import Lockstep.Effects.HelperRunner (RunnerChannel)
import Lockstep.Effects.Provider.Claude (ProviderConfig, claudeAdapter)
import Lockstep.Effects.Roles (Adapter, Runner, liveRunner)
import Lockstep.Kernel.Roles (Role)

-- | The runner and, for every role and attempt, the adapter of a live engine.
liveRoles :: RunnerChannel -> ProviderConfig -> (Runner, Role -> Int -> Maybe Adapter)
liveRoles channel config =
  (liveRunner channel, \role _ -> Just (claudeAdapter config role))
