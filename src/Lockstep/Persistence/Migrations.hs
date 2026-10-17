{-# LANGUAGE QuasiQuotes #-}

{- | The production migration list. Append only: an applied migration's SQL
must never change (its checksum is verified on every run).
-}
module Lockstep.Persistence.Migrations
  ( migrations
  ) where

import Data.String.Interpolate qualified as Interpolate

import Lockstep.Persistence.Migration (Migration, sequentialMigrations)

migrations :: [Migration]
migrations =
  sequentialMigrations
    [
      ( [Interpolate.i|record service starts|]
      , [Interpolate.i|
CREATE TABLE lockstep_service_starts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
|]
      )
    ,
      ( [Interpolate.i|operator sign-in tokens and sessions|]
      , [Interpolate.i|
CREATE TABLE lockstep_operator_sign_in_tokens (
  digest bytea PRIMARY KEY CHECK (octet_length(digest) = 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz
);
CREATE TABLE lockstep_operator_sessions (
  digest bytea PRIMARY KEY CHECK (octet_length(digest) = 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz
);
|]
      )
    ]
