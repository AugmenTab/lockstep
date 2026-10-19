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
    ,
      ( [Interpolate.i|engineers, repository ownership and identity decisions|]
      , [Interpolate.i|
CREATE TABLE lockstep_engineers (
  id uuid PRIMARY KEY,
  name text NOT NULL UNIQUE CHECK (name ~ '^[a-z][a-z0-9-]{0,39}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE lockstep_repositories (
  id uuid PRIMARY KEY,
  owner_engineer_id uuid NOT NULL REFERENCES lockstep_engineers (id),
  common_dir text NOT NULL,
  physical_id text NOT NULL,
  authoritative_remote text,
  authoritative_identity text,
  other_remotes text NOT NULL,
  observation_digest bytea NOT NULL CHECK (octet_length(observation_digest) = 32),
  registered_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz CHECK (released_at IS NULL),
  CHECK ((authoritative_remote IS NULL) = (authoritative_identity IS NULL))
);
CREATE UNIQUE INDEX lockstep_repositories_active_owner ON lockstep_repositories (owner_engineer_id) WHERE released_at IS NULL;
CREATE UNIQUE INDEX lockstep_repositories_active_physical ON lockstep_repositories (physical_id) WHERE released_at IS NULL;
CREATE UNIQUE INDEX lockstep_repositories_active_common_dir ON lockstep_repositories (common_dir) WHERE released_at IS NULL;
CREATE UNIQUE INDEX lockstep_repositories_active_remote ON lockstep_repositories (authoritative_identity) WHERE released_at IS NULL;
CREATE TABLE lockstep_identity_decisions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation text NOT NULL CHECK (operation IN ('engineer-add', 'repository-register')),
  engineer_name text NOT NULL,
  requested_path text,
  requested_remote text,
  outcome text NOT NULL CHECK (outcome IN ('accepted', 'refused')),
  refusal_code text,
  engineer_id uuid,
  repository_id uuid,
  observation text,
  decided_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((outcome = 'refused') = (refusal_code IS NOT NULL))
);
|]
      )
    ,
      ( [Interpolate.i|profiles, repository default profiles and profile decisions|]
      , [Interpolate.i|
CREATE FUNCTION lockstep_refuse_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'lockstep: % rows are immutable', TG_TABLE_NAME;
END;
$$;
CREATE TABLE lockstep_profiles (
  profile_id text NOT NULL CHECK (profile_id ~ '^[a-z][a-z0-9-]{0,63}$'),
  version integer NOT NULL CHECK (version >= 1),
  digest text NOT NULL CHECK (digest ~ '^[0-9a-f]{64}$'),
  document text NOT NULL,
  added_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (profile_id, version)
);
CREATE TABLE lockstep_repository_profiles (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  repository_id uuid NOT NULL REFERENCES lockstep_repositories (id),
  profile_id text NOT NULL,
  set_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE lockstep_profile_decisions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation text NOT NULL CHECK (operation IN ('profile-add', 'repository-set-profile')),
  profile_id text,
  version integer,
  digest text,
  engineer_name text,
  repository_id uuid,
  outcome text NOT NULL CHECK (outcome IN ('accepted', 'unchanged', 'refused')),
  refusal_code text,
  decided_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((outcome = 'refused') = (refusal_code IS NOT NULL))
);
CREATE TRIGGER lockstep_profiles_immutable BEFORE UPDATE OR DELETE ON lockstep_profiles FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_profiles_no_truncate BEFORE TRUNCATE ON lockstep_profiles FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_repository_profiles_immutable BEFORE UPDATE OR DELETE ON lockstep_repository_profiles FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_repository_profiles_no_truncate BEFORE TRUNCATE ON lockstep_repository_profiles FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_profile_decisions_immutable BEFORE UPDATE OR DELETE ON lockstep_profile_decisions FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_profile_decisions_no_truncate BEFORE TRUNCATE ON lockstep_profile_decisions FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
|]
      )
    ]
