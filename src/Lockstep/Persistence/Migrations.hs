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
    ,
      ( [Interpolate.i|workspace and command receipts|]
      , [Interpolate.i|
CREATE TABLE lockstep_workspace (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
  revision bigint NOT NULL CHECK (revision >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO lockstep_workspace (name, revision) VALUES ('Lockstep', 0);
CREATE TABLE lockstep_command_receipts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  idempotency_key text NOT NULL UNIQUE,
  envelope_version integer NOT NULL,
  command_kind text NOT NULL,
  payload_digest bytea NOT NULL CHECK (octet_length(payload_digest) = 32),
  actor text NOT NULL,
  expected_revision bigint NOT NULL,
  outcome text NOT NULL CHECK (outcome IN ('applied', 'refused_stale')),
  resulting_revision bigint NOT NULL,
  accepted_at timestamptz NOT NULL DEFAULT now()
);
|]
      )
    ,
      ( [Interpolate.i|background jobs|]
      , [Interpolate.i|
ALTER TABLE lockstep_command_receipts DROP CONSTRAINT lockstep_command_receipts_outcome_check;
ALTER TABLE lockstep_command_receipts ADD CONSTRAINT lockstep_command_receipts_outcome_check
  CHECK (outcome IN ('applied', 'refused_stale', 'queued'));
CREATE TABLE lockstep_jobs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  receipt_id bigint NOT NULL UNIQUE REFERENCES lockstep_command_receipts (id),
  kind text NOT NULL CHECK (kind = 'noop'),
  state text NOT NULL CHECK (state IN ('queued', 'running', 'succeeded', 'failed')),
  steps_total integer NOT NULL CHECK (steps_total BETWEEN 1 AND 20),
  step_millis integer NOT NULL CHECK (step_millis BETWEEN 0 AND 5000),
  fail_at_step integer CHECK (fail_at_step BETWEEN 1 AND steps_total),
  steps_done integer NOT NULL DEFAULT 0,
  attempts integer NOT NULL DEFAULT 0,
  owner text,
  lease_until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  last_error text,
  recovered_count integer NOT NULL DEFAULT 0
);
|]
      )
    ,
      ( [Interpolate.i|job outcome digests|]
      , [Interpolate.i|
ALTER TABLE lockstep_jobs ADD COLUMN outcome_digest bytea CHECK (octet_length(outcome_digest) = 32);
|]
      )
    ]
