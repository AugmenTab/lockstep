{- | The live provider's construction (contract C-P4.L L1; C-P1.7 E3, the
guard's construction gate): the one place where the live runner and the Claude
Code adapter are put together. Only the service's entry point imports it
(@scripts/lib/check-guard@ (c)); tests use the parts.

Phase 5 (@docs/architecture/dev-capsules.md@ §5): when the helper's capsule
mode is on, the same runner carries the role to the helper, which runs the
CLI with no built-in tool and the capsule bridge; the adapter is the capsule
variant, whose instructions name the capsule's tools.
-}
module Lockstep.Effects.Provider.Live
  ( liveRoles
  , liveCapsuleRoles
  ) where

import Flipstone.Prelude

import Lockstep.Effects.HelperRunner (RunnerChannel)
import Lockstep.Effects.Provider.Claude (ProviderConfig, claudeAdapter, claudeCapsuleAdapter)
import Lockstep.Effects.Roles (Adapter, Runner, liveRunner)
import Lockstep.Kernel.Roles (Role)

-- | The runner and, for every role and attempt, the adapter of a live engine.
liveRoles :: RunnerChannel -> ProviderConfig -> (Runner, Role -> Int -> Maybe Adapter)
liveRoles channel config =
  (liveRunner channel, \role _ -> Just (claudeAdapter config role))

-- | 'liveRoles' for the helper's capsule mode.
liveCapsuleRoles :: RunnerChannel -> ProviderConfig -> (Runner, Role -> Int -> Maybe Adapter)
liveCapsuleRoles channel config =
  (liveRunner channel, \role _ -> Just (claudeCapsuleAdapter config role))
