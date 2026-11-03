-- Up Migration
-- MCP tool invocation records and the append-only audit log (04, 06).

CREATE TABLE tool_invocations (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id        UUID NOT NULL,
  project_id             UUID NOT NULL,
  workflow_id            UUID,
  task_id                UUID,
  execution_id           UUID,
  actor_type             TEXT NOT NULL CHECK (actor_type IN ('AGENT','USER','SERVICE')),
  actor_ref              TEXT NOT NULL,      -- e.g. agent:backend-developer@1.0.0
  server_id              TEXT NOT NULL,      -- e.g. mcp-github
  tool_name              TEXT NOT NULL,
  tool_version           TEXT,
  risk_tier              TEXT NOT NULL CHECK (risk_tier IN ('T0','T1','T2','T3')),
  decision               TEXT NOT NULL CHECK (decision IN ('ALLOW','DENY')),
  decision_reason        TEXT,
  policy_bundle_version  TEXT,
  status                 TEXT NOT NULL CHECK (status IN (
                           'INTENT_RECORDED','SUCCEEDED','FAILED','DENIED','TIMED_OUT','RECONCILED')),
  idempotency_key        TEXT,
  resource               JSONB NOT NULL DEFAULT '{}'::jsonb,   -- redacted; never raw secrets
  external_resource_id   TEXT,
  duration_ms            INTEGER CHECK (duration_ms >= 0),
  occurred_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id, project_id) REFERENCES projects (organization_id, id),
  FOREIGN KEY (organization_id, workflow_id) REFERENCES workflows (organization_id, id),
  FOREIGN KEY (organization_id, task_id) REFERENCES tasks (organization_id, id),
  FOREIGN KEY (organization_id, execution_id) REFERENCES agent_executions (organization_id, id),
  CHECK (decision = 'ALLOW' OR status = 'DENIED'),
  CHECK (NOT (actor_type = 'AGENT' AND risk_tier = 'T3' AND decision = 'ALLOW'))
);
CREATE INDEX idx_tool_invocations_execution ON tool_invocations (execution_id, occurred_at);
CREATE UNIQUE INDEX uq_tool_invocations_idempotency
  ON tool_invocations (organization_id, server_id, tool_name, idempotency_key)
  WHERE idempotency_key IS NOT NULL AND decision = 'ALLOW';

-- Append-only. organization_id NULL = platform-level event (e.g. org created by platform admin).
-- event_hash / prev_event_hash are reserved for the tamper-evident hash chain (E12).
CREATE TABLE audit_events (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id    UUID REFERENCES organizations(id),
  project_id         UUID REFERENCES projects(id),
  workflow_id        UUID REFERENCES workflows(id),
  actor_type         TEXT NOT NULL CHECK (actor_type IN ('USER','AGENT','SERVICE','SYSTEM')),
  actor_id           TEXT NOT NULL,
  action             TEXT NOT NULL,        -- e.g. membership.role.granted
  resource_type      TEXT NOT NULL,
  resource_id        TEXT,
  outcome            TEXT NOT NULL CHECK (outcome IN ('SUCCESS','DENIED','FAILURE')),
  correlation_id     UUID,
  metadata_redacted  JSONB NOT NULL DEFAULT '{}'::jsonb,
  prev_event_hash    CHAR(64),
  event_hash         CHAR(64),
  occurred_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_events_org_time ON audit_events (organization_id, occurred_at DESC);
CREATE INDEX idx_audit_events_workflow ON audit_events (workflow_id, occurred_at) WHERE workflow_id IS NOT NULL;
CREATE TRIGGER trg_audit_events_append_only BEFORE UPDATE OR DELETE ON audit_events
  FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE TRIGGER trg_audit_events_no_truncate BEFORE TRUNCATE ON audit_events
  FOR EACH STATEMENT EXECUTE FUNCTION reject_mutation();

-- Down Migration
DROP TABLE IF EXISTS audit_events;
DROP TABLE IF EXISTS tool_invocations;
