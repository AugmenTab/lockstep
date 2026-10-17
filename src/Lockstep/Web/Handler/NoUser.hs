-- | Derived from Launchpad.Handler.NoUser (11886bf).
module Lockstep.Web.Handler.NoUser
  ( NoUser (NoUser)
  ) where

-- | A simple data type when a handler does not require an authenticated user.
data NoUser = NoUser
