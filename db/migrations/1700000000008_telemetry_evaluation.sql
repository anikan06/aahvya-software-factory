-- Up Migration
-- Native trace source configuration (read-only adapters, 07) and agent evaluation runs (08).

CREATE TABLE trace_sources (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id    UUID NOT NULL,
  project_id         UUID NOT NULL,
  adapter            TEXT NOT NULL CHECK (adapter IN ('CLAUDE_CODE','GITHUB_COPILOT','OPENTELEMETRY')),
  source_config_ref  TEXT NOT NULL CHECK (source_config_ref ~ '^[a-z][a-z0-9+.-]*://'),  -- secret ref, never plaintext
  enabled            BOOLEAN NOT NULL DEFAULT true,
  ingest_cursor      JSONB NOT NULL DEFAULT '{}'::jsonb,
  last_ingested_at   TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id, project_id) REFERENCES projects (organization_id, id),
  UNIQUE (project_id, adapter, source_config_ref)
);

-- organization_id NULL = evaluation of a platform-catalog agent version.
CREATE TABLE evaluation_runs (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id    UUID REFERENCES organizations(id),
  agent_version_id   UUID NOT NULL REFERENCES agent_versions(id),
  dataset_key        TEXT NOT NULL,
  dataset_version    TEXT NOT NULL,
  evaluator_version  TEXT NOT NULL,
  status             TEXT NOT NULL DEFAULT 'QUEUED'
                       CHECK (status IN ('QUEUED','RUNNING','PASSED','FAILED','ERRORED','CANCELLED')),
  score_summary      JSONB NOT NULL DEFAULT '{}'::jsonb,
  triggered_by       UUID REFERENCES users(id),
  started_at         TIMESTAMPTZ,
  completed_at       TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_evaluation_runs_agent ON evaluation_runs (agent_version_id, created_at DESC);

-- Down Migration
DROP TABLE IF EXISTS evaluation_runs;
DROP TABLE IF EXISTS trace_sources;
