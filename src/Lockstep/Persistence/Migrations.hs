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
    ,
      ( [Interpolate.i|durable tickets, work orders, events, effect intents and schedule decisions|]
      , [Interpolate.i|
CREATE TABLE lockstep_subjects (
  id uuid PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('ticket', 'work-order')),
  revision integer NOT NULL CHECK (revision >= 1),
  state text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE lockstep_tickets (
  id uuid PRIMARY KEY REFERENCES lockstep_subjects (id),
  title text NOT NULL,
  content_revision integer NOT NULL CHECK (content_revision >= 1)
);
CREATE TABLE lockstep_work_orders (
  id uuid PRIMARY KEY REFERENCES lockstep_subjects (id),
  kind text NOT NULL,
  ticket_id uuid NOT NULL REFERENCES lockstep_tickets (id),
  ticket_content_revision integer NOT NULL CHECK (ticket_content_revision >= 1),
  repository_id uuid NOT NULL REFERENCES lockstep_repositories (id),
  priority integer NOT NULL CHECK (priority BETWEEN 0 AND 999),
  admitted_at timestamptz NOT NULL DEFAULT now(),
  classes text NOT NULL,
  path_classes text NOT NULL,
  non_behavioural_rationale text,
  binding_approver text NOT NULL,
  effective_digest text NOT NULL CHECK (effective_digest ~ '^[0-9a-f]{64}$'),
  binding_digest text NOT NULL CHECK (binding_digest ~ '^[0-9a-f]{64}$')
);
CREATE TABLE lockstep_work_order_dependencies (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  work_order_id uuid NOT NULL REFERENCES lockstep_work_orders (id),
  depends_on uuid NOT NULL REFERENCES lockstep_work_orders (id),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (work_order_id, depends_on)
);
CREATE TABLE lockstep_work_order_profile_sources (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  work_order_id uuid NOT NULL REFERENCES lockstep_work_orders (id),
  position integer NOT NULL CHECK (position >= 1),
  level text NOT NULL CHECK (level IN ('baseline', 'repository-default', 'specialization')),
  profile_id text NOT NULL,
  version integer NOT NULL CHECK (version >= 1),
  digest text NOT NULL CHECK (digest ~ '^[0-9a-f]{64}$'),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (work_order_id, position)
);
CREATE TABLE lockstep_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subject_id uuid NOT NULL REFERENCES lockstep_subjects (id),
  sequence integer NOT NULL CHECK (sequence >= 1),
  principal text NOT NULL CHECK (principal IN ('human', 'supervisor', 'scheduler', 'delivery-adapter')),
  command text NOT NULL,
  state_after text NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (subject_id, sequence)
);
CREATE TABLE lockstep_decision_refusals (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subject_id uuid NOT NULL REFERENCES lockstep_subjects (id),
  expected_revision integer NOT NULL,
  principal text NOT NULL,
  command text NOT NULL,
  refusal_code text NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE lockstep_effect_intents (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation_id uuid NOT NULL UNIQUE,
  subject_id uuid NOT NULL REFERENCES lockstep_subjects (id),
  basis_revision integer NOT NULL CHECK (basis_revision >= 1),
  effect_key text NOT NULL CHECK (effect_key ~ '^[a-z][a-z0-9-]{0,63}$'),
  event_id bigint NOT NULL REFERENCES lockstep_events (id),
  spec_name text NOT NULL CHECK (spec_name ~ '^[a-z][a-z0-9-]{0,63}$'),
  effect_class text NOT NULL CHECK (effect_class IN ('repeatable', 'idempotent', 'queryable', 'unqueryable')),
  retry_budget integer NOT NULL CHECK (retry_budget BETWEEN 0 AND 3),
  key_lifetime_seconds bigint,
  refuses_changed_parameters boolean,
  lookup_authoritative boolean,
  lookup_excludes_late_application boolean,
  parameters text NOT NULL,
  parameters_digest text NOT NULL CHECK (parameters_digest ~ '^[0-9a-f]{64}$'),
  state text NOT NULL CHECK (state IN ('pending', 'claimed', 'dispatched', 'confirmed-applied', 'confirmed-not-applied', 'outcome-unknown', 'settled', 'abandoned')),
  generation integer NOT NULL DEFAULT 0 CHECK (generation >= 0),
  dispatches integer NOT NULL DEFAULT 0 CHECK (dispatches >= 0),
  lease_owner text,
  lease_until timestamptz,
  outcome_text text,
  settled_applied boolean,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (subject_id, basis_revision, effect_key),
  CHECK ((effect_class = 'repeatable' AND key_lifetime_seconds IS NULL AND lookup_authoritative IS NULL)
      OR (effect_class = 'idempotent' AND key_lifetime_seconds >= 1 AND refuses_changed_parameters AND lookup_authoritative IS NULL)
      OR (effect_class = 'queryable' AND key_lifetime_seconds IS NULL AND lookup_authoritative IS NOT NULL AND lookup_excludes_late_application IS NOT NULL)
      OR (effect_class = 'unqueryable' AND retry_budget = 0 AND key_lifetime_seconds IS NULL AND lookup_authoritative IS NULL))
);
CREATE FUNCTION lockstep_refuse_intent_identity_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (OLD.operation_id, OLD.subject_id, OLD.basis_revision, OLD.effect_key, OLD.event_id, OLD.spec_name, OLD.effect_class,
      OLD.retry_budget, OLD.key_lifetime_seconds, OLD.refuses_changed_parameters, OLD.lookup_authoritative,
      OLD.lookup_excludes_late_application, OLD.parameters, OLD.parameters_digest)
     IS DISTINCT FROM
     (NEW.operation_id, NEW.subject_id, NEW.basis_revision, NEW.effect_key, NEW.event_id, NEW.spec_name, NEW.effect_class,
      NEW.retry_budget, NEW.key_lifetime_seconds, NEW.refuses_changed_parameters, NEW.lookup_authoritative,
      NEW.lookup_excludes_late_application, NEW.parameters, NEW.parameters_digest) THEN
    RAISE EXCEPTION 'lockstep: an effect intent''s identity, spec and parameters are immutable';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER lockstep_effect_intents_identity BEFORE UPDATE ON lockstep_effect_intents FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_intent_identity_change();
CREATE TRIGGER lockstep_effect_intents_no_delete BEFORE DELETE ON lockstep_effect_intents FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_effect_intents_no_truncate BEFORE TRUNCATE ON lockstep_effect_intents FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
CREATE TABLE lockstep_effect_observations (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation_id uuid NOT NULL REFERENCES lockstep_effect_intents (operation_id),
  generation integer NOT NULL,
  observation text NOT NULL,
  accepted boolean NOT NULL,
  refusal_code text,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  CHECK (accepted = (refusal_code IS NULL))
);
CREATE TABLE lockstep_gate_evidence (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  work_order_id uuid NOT NULL REFERENCES lockstep_work_orders (id),
  artifact text NOT NULL,
  digest text NOT NULL CHECK (digest ~ '^[0-9a-f]{64}$'),
  verifiers text NOT NULL,
  approval text NOT NULL CHECK (approval IN ('none', 'supervisor', 'human')),
  principal text NOT NULL CHECK (principal IN ('human', 'supervisor')),
  recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE lockstep_schedule_decisions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rendering text NOT NULL,
  digest text NOT NULL CHECK (digest ~ '^[0-9a-f]{64}$'),
  selected_work_order uuid REFERENCES lockstep_work_orders (id),
  recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE lockstep_work_units (
  id uuid PRIMARY KEY,
  work_order_id uuid NOT NULL REFERENCES lockstep_work_orders (id),
  ticket_id uuid NOT NULL REFERENCES lockstep_tickets (id),
  repository_id uuid NOT NULL REFERENCES lockstep_repositories (id),
  engineer_id uuid NOT NULL REFERENCES lockstep_engineers (id),
  plan_ref text,
  admitted_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER lockstep_events_immutable BEFORE UPDATE OR DELETE ON lockstep_events FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_events_no_truncate BEFORE TRUNCATE ON lockstep_events FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_decision_refusals_immutable BEFORE UPDATE OR DELETE ON lockstep_decision_refusals FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_decision_refusals_no_truncate BEFORE TRUNCATE ON lockstep_decision_refusals FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_effect_observations_immutable BEFORE UPDATE OR DELETE ON lockstep_effect_observations FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_effect_observations_no_truncate BEFORE TRUNCATE ON lockstep_effect_observations FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_gate_evidence_immutable BEFORE UPDATE OR DELETE ON lockstep_gate_evidence FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_gate_evidence_no_truncate BEFORE TRUNCATE ON lockstep_gate_evidence FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_schedule_decisions_immutable BEFORE UPDATE OR DELETE ON lockstep_schedule_decisions FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_schedule_decisions_no_truncate BEFORE TRUNCATE ON lockstep_schedule_decisions FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_work_order_profile_sources_immutable BEFORE UPDATE OR DELETE ON lockstep_work_order_profile_sources FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_work_order_profile_sources_no_truncate BEFORE TRUNCATE ON lockstep_work_order_profile_sources FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_work_order_dependencies_immutable BEFORE UPDATE OR DELETE ON lockstep_work_order_dependencies FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_work_order_dependencies_no_truncate BEFORE TRUNCATE ON lockstep_work_order_dependencies FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
|]
      )
    ,
      ( [Interpolate.i|effect recovery records|]
      , [Interpolate.i|
CREATE TABLE lockstep_effect_recoveries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation_id uuid NOT NULL REFERENCES lockstep_effect_intents (operation_id),
  generation integer NOT NULL CHECK (generation >= 1),
  decision text NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER lockstep_effect_recoveries_immutable BEFORE UPDATE OR DELETE ON lockstep_effect_recoveries FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_effect_recoveries_no_truncate BEFORE TRUNCATE ON lockstep_effect_recoveries FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
|]
      )
    ,
      ( [Interpolate.i|effect resolution records|]
      , [Interpolate.i|
CREATE TABLE lockstep_effect_resolutions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation_id uuid NOT NULL REFERENCES lockstep_effect_intents (operation_id),
  generation integer NOT NULL CHECK (generation >= 0),
  basis text NOT NULL CHECK (basis IN ('lookup', 'human-attested', 'human-retry', 'late-observation')),
  decision text NOT NULL,
  duplication_acknowledged boolean NOT NULL DEFAULT false,
  recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER lockstep_effect_resolutions_immutable BEFORE UPDATE OR DELETE ON lockstep_effect_resolutions FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_effect_resolutions_no_truncate BEFORE TRUNCATE ON lockstep_effect_resolutions FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
|]
      )
    ,
      ( [Interpolate.i|sandbox effect destination|]
      , [Interpolate.i|
CREATE TABLE lockstep_sandbox_applications (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation_id uuid NOT NULL,
  effect text NOT NULL,
  parameters text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE lockstep_sandbox_keys (
  operation_id uuid PRIMARY KEY,
  parameters text NOT NULL
);
CREATE TABLE lockstep_sandbox_queryable (
  operation_id uuid PRIMARY KEY,
  outcome text NOT NULL CHECK (outcome IN ('applied', 'fenced'))
);
|]
      )
    ,
      ( [Interpolate.i|effect activations, first dispatch times, human abandon and carry records|]
      , [Interpolate.i|
ALTER TABLE lockstep_effect_intents ADD COLUMN first_dispatched_at timestamptz;
ALTER TABLE lockstep_effect_intents ADD COLUMN activation_generation integer NOT NULL DEFAULT 1 CHECK (activation_generation >= 1);
ALTER TABLE lockstep_effect_resolutions DROP CONSTRAINT lockstep_effect_resolutions_basis_check;
ALTER TABLE lockstep_effect_resolutions ADD CONSTRAINT lockstep_effect_resolutions_basis_check
  CHECK (basis IN ('lookup', 'human-attested', 'human-retry', 'late-observation', 'human-abandon', 'human-carry'));
|]
      )
    ,
      ( [Interpolate.i|projects|]
      , [Interpolate.i|
CREATE TABLE lockstep_projects (
  id uuid PRIMARY KEY,
  creation_key text NOT NULL UNIQUE CHECK (creation_key ~ '^[A-Za-z0-9_-]{16,64}$'),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
  outcome text NOT NULL CHECK (char_length(outcome) <= 2000),
  setup text NOT NULL CHECK (setup IN ('organized', 'connected', 'setup-failed')),
  setup_refusal text,
  folder text,
  engineer_name text,
  repository_id uuid UNIQUE REFERENCES lockstep_repositories (id),
  revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((setup = 'setup-failed') = (setup_refusal IS NOT NULL)),
  CHECK ((setup = 'connected') = (repository_id IS NOT NULL AND folder IS NOT NULL))
);
CREATE UNIQUE INDEX lockstep_projects_name ON lockstep_projects (lower(name));
|]
      )
    ,
      ( [Interpolate.i|project tasks and their dependencies|]
      , [Interpolate.i|
CREATE TABLE lockstep_project_tasks (
  ticket_id uuid PRIMARY KEY REFERENCES lockstep_tickets (id),
  project_id uuid NOT NULL REFERENCES lockstep_projects (id),
  creation_key text NOT NULL UNIQUE CHECK (creation_key ~ '^[A-Za-z0-9_-]{16,64}$'),
  acceptance text NOT NULL CHECK (char_length(acceptance) <= 4000),
  priority integer NOT NULL CHECK (priority BETWEEN 0 AND 999),
  revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX lockstep_project_tasks_project ON lockstep_project_tasks (project_id);
CREATE TABLE lockstep_task_dependencies (
  task_id uuid NOT NULL REFERENCES lockstep_project_tasks (ticket_id),
  depends_on uuid NOT NULL REFERENCES lockstep_project_tasks (ticket_id),
  PRIMARY KEY (task_id, depends_on),
  CHECK (task_id <> depends_on)
);
|]
      )
    ,
      ( [Interpolate.i|receipts of human decisions made in the browser|]
      , [Interpolate.i|
CREATE TABLE lockstep_decision_receipts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  idempotency_key text NOT NULL UNIQUE CHECK (idempotency_key ~ '^[A-Za-z0-9_-]{16,64}$'),
  payload_digest text NOT NULL CHECK (payload_digest ~ '^[0-9a-f]{64}$'),
  subject uuid NOT NULL,
  choice text NOT NULL CHECK (choice IN ('put-back', 'cancel', 'happened', 'did-not-happen', 'try-again', 'give-up')),
  expected integer NOT NULL CHECK (expected >= 0),
  outcome text NOT NULL CHECK (outcome IN ('applied', 'refused')),
  refusal_code text,
  actor text NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((outcome = 'refused') = (refusal_code IS NOT NULL))
);
CREATE INDEX lockstep_decision_receipts_subject ON lockstep_decision_receipts (subject);
CREATE TRIGGER lockstep_decision_receipts_immutable BEFORE UPDATE OR DELETE ON lockstep_decision_receipts FOR EACH ROW EXECUTE FUNCTION lockstep_refuse_change();
CREATE TRIGGER lockstep_decision_receipts_no_truncate BEFORE TRUNCATE ON lockstep_decision_receipts FOR EACH STATEMENT EXECUTE FUNCTION lockstep_refuse_change();
|]
      )
    ]
