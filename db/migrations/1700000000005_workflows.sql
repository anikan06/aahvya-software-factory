-- Up Migration
-- Workflow runtime records. Temporal holds the live execution; these tables are the
-- queryable, auditable projection the API and portal read (03, 05).

CREATE TABLE workflows (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id        UUID NOT NULL,
  project_id             UUID NOT NULL,
  workflow_type          TEXT NOT NULL CHECK (workflow_type IN (
                           'FEATURE_DELIVERY','BUG_FIX','ARCHITECTURE_CHANGE',
                           'MODERNIZATION','SECURITY_REMEDIATION','CI_REMEDIATION')),
  title                  TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
  status                 TEXT NOT NULL DEFAULT 'DRAFT' CHECK (status IN (
                           'DRAFT','REQUIREMENT_ANALYSIS','REQUIREMENT_REVIEW',
                           'ARCHITECTURE_DESIGN','ARCHITECTURE_REVIEW','DEVELOPMENT_PLANNING',
                           'DEVELOPMENT_IN_PROGRESS','QUALITY_VALIDATION','PR_REVIEW',
                           'APPROVAL_PENDING','PR_READY','RELEASE_READY','DEPLOYMENT_APPROVAL',
                           'DEPLOYED','COMPLETED','BLOCKED','FAILED','CANCELLED')),
  source                 JSONB NOT NULL DEFAULT '{}'::jsonb,  -- e.g. {"system":"JIRA","issueKey":"AAH-245"}
  options                JSONB NOT NULL DEFAULT '{}'::jsonb,  -- e.g. {"stopAfter":"PR_READY"}
  correlation_id         UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  temporal_workflow_id   TEXT UNIQUE,
  policy_bundle_id       UUID REFERENCES policy_bundles(id),   -- pinned at start
  created_by             UUID NOT NULL REFERENCES users(id),
  row_version            INTEGER NOT NULL DEFAULT 1,           -- optimistic concurrency (ETag)
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at             TIMESTAMPTZ,
  completed_at           TIMESTAMPTZ,
  FOREIGN KEY (organization_id, project_id) REFERENCES projects (organization_id, id),
  UNIQUE (organization_id, id)
);
CREATE INDEX idx_workflows_project_created ON workflows (project_id, created_at DESC);
CREATE INDEX idx_workflows_status_updated ON workflows (status, updated_at);
CREATE TRIGGER trg_workflows_updated_at BEFORE UPDATE ON workflows
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE workflow_stages (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID NOT NULL,
  workflow_id      UUID NOT NULL,
  stage_key        TEXT NOT NULL,
  sequence         INTEGER NOT NULL CHECK (sequence >= 0),
  attempt          INTEGER NOT NULL DEFAULT 1 CHECK (attempt >= 1),
  status           TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN (
                     'PENDING','RUNNING','WAITING_APPROVAL','SUCCEEDED','FAILED',
                     'BLOCKED','SKIPPED','CANCELLED')),
  entered_at       TIMESTAMPTZ,
  exited_at        TIMESTAMPTZ,
  FOREIGN KEY (organization_id, workflow_id) REFERENCES workflows (organization_id, id),
  UNIQUE (workflow_id, stage_key, attempt)
);

CREATE TABLE tasks (
  id                         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id            UUID NOT NULL,
  workflow_id                UUID NOT NULL,
  parent_task_id             UUID,
  task_key                   TEXT NOT NULL,
  title                      TEXT NOT NULL,
  task_type                  TEXT NOT NULL,
  stage_key                  TEXT NOT NULL,
  assigned_agent_version_id  UUID REFERENCES agent_versions(id),
  status                     TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN (
                               'PENDING','READY','RUNNING','SUCCEEDED','PARTIAL',
                               'FAILED','BLOCKED','CANCELLED')),
  input_ref                  TEXT,
  output_ref                 TEXT,
  attempt                    INTEGER NOT NULL DEFAULT 1 CHECK (attempt >= 1),
  created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id, workflow_id) REFERENCES workflows (organization_id, id),
  UNIQUE (workflow_id, task_key),
  UNIQUE (organization_id, id)
);
ALTER TABLE tasks ADD FOREIGN KEY (organization_id, parent_task_id) REFERENCES tasks (organization_id, id);
CREATE INDEX idx_tasks_workflow_status ON tasks (workflow_id, status);
CREATE TRIGGER trg_tasks_updated_at BEFORE UPDATE ON tasks
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Dependency graph edges (normalised form of 05's tasks.depends_on).
CREATE TABLE task_dependencies (
  organization_id     UUID NOT NULL,
  task_id             UUID NOT NULL,
  depends_on_task_id  UUID NOT NULL,
  PRIMARY KEY (task_id, depends_on_task_id),
  CHECK (task_id <> depends_on_task_id),
  FOREIGN KEY (organization_id, task_id) REFERENCES tasks (organization_id, id),
  FOREIGN KEY (organization_id, depends_on_task_id) REFERENCES tasks (organization_id, id)
);
CREATE INDEX idx_task_dependencies_reverse ON task_dependencies (depends_on_task_id);

CREATE TABLE agent_executions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID NOT NULL,
  task_id           UUID NOT NULL,
  agent_version_id  UUID NOT NULL REFERENCES agent_versions(id),
  adapter           TEXT NOT NULL CHECK (adapter IN ('CLAUDE_CODE','GITHUB_COPILOT')),
  adapter_version   TEXT,
  session_ref       TEXT,                -- adapter-native session id, for trace correlation
  trace_id          TEXT,
  status            TEXT NOT NULL DEFAULT 'QUEUED' CHECK (status IN (
                      'QUEUED','RUNNING','SUCCEEDED','PARTIAL','FAILED','BLOCKED',
                      'CANCELLED','TIMED_OUT')),
  attempt           INTEGER NOT NULL DEFAULT 1 CHECK (attempt >= 1),
  started_at        TIMESTAMPTZ,
  ended_at          TIMESTAMPTZ,
  usage_summary     JSONB NOT NULL DEFAULT '{}'::jsonb,   -- tokens/tool calls as reported by source
  cost_usd          NUMERIC(12,4),
  error_class       TEXT,
  FOREIGN KEY (organization_id, task_id) REFERENCES tasks (organization_id, id),
  UNIQUE (organization_id, id)
);
CREATE INDEX idx_agent_executions_task_started ON agent_executions (task_id, started_at DESC);

-- Transactional outbox for platform events (03 §8). Written in the same transaction as
-- the state change; relayed by integration-worker.
CREATE TABLE outbox_events (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID NOT NULL REFERENCES organizations(id),
  aggregate_type   TEXT NOT NULL,
  aggregate_id     UUID NOT NULL,
  event_type       TEXT NOT NULL,        -- e.g. WorkflowCreated, ApprovalGranted
  schema_version   TEXT NOT NULL,
  payload          JSONB NOT NULL,
  correlation_id   UUID,
  occurred_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  published_at     TIMESTAMPTZ,
  attempts         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_outbox_unpublished ON outbox_events (occurred_at) WHERE published_at IS NULL;

-- Down Migration
DROP TABLE IF EXISTS outbox_events;
DROP TABLE IF EXISTS agent_executions;
DROP TABLE IF EXISTS task_dependencies;
DROP TABLE IF EXISTS tasks;
DROP TABLE IF EXISTS workflow_stages;
DROP TABLE IF EXISTS workflows;
