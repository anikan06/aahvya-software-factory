-- Up Migration
-- Content-addressed artifact metadata and hash-bound human approvals (05, 06 §9, 03 §9).

CREATE TABLE artifacts (
  id                         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id            UUID NOT NULL,
  workflow_id                UUID NOT NULL,
  task_id                    UUID,
  produced_by_execution_id   UUID,
  artifact_type              TEXT NOT NULL,        -- e.g. requirements-baseline, hld, adr, implementation-report
  uri                        TEXT NOT NULL,        -- object storage or git location; bytes never stored here
  version                    TEXT NOT NULL,
  sha256                     CHAR(64) NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes                 BIGINT CHECK (size_bytes >= 0),
  media_type                 TEXT,
  classification             TEXT NOT NULL DEFAULT 'INTERNAL'
                               CHECK (classification IN ('PUBLIC','INTERNAL','CONFIDENTIAL','RESTRICTED')),
  approval_status            TEXT NOT NULL DEFAULT 'DRAFT' CHECK (approval_status IN (
                               'DRAFT','PENDING_APPROVAL','APPROVED','REJECTED','SUPERSEDED')),
  created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id, workflow_id) REFERENCES workflows (organization_id, id),
  FOREIGN KEY (organization_id, task_id) REFERENCES tasks (organization_id, id),
  FOREIGN KEY (organization_id, produced_by_execution_id) REFERENCES agent_executions (organization_id, id),
  UNIQUE (workflow_id, artifact_type, version),
  UNIQUE (organization_id, id)
);
CREATE INDEX idx_artifacts_workflow ON artifacts (workflow_id, created_at);
CREATE INDEX idx_artifacts_sha ON artifacts (sha256);

-- Content identity is immutable; a change is a new version row.
CREATE FUNCTION guard_artifact() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF NEW.uri IS DISTINCT FROM OLD.uri OR NEW.sha256 IS DISTINCT FROM OLD.sha256
     OR NEW.version IS DISTINCT FROM OLD.version OR NEW.artifact_type IS DISTINCT FROM OLD.artifact_type
     OR NEW.workflow_id IS DISTINCT FROM OLD.workflow_id OR NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION 'Artifact content identity is immutable; register a new version';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER trg_artifacts_guard BEFORE UPDATE ON artifacts
  FOR EACH ROW EXECUTE FUNCTION guard_artifact();

CREATE TABLE approvals (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID NOT NULL,
  workflow_id       UUID NOT NULL,
  stage_key         TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN (
                      'PENDING','APPROVED','REJECTED','EXPIRED','CANCELLED','SUPERSEDED')),
  required_role     TEXT NOT NULL CHECK (required_role IN (
                      'PRODUCT_OWNER','SOLUTION_ARCHITECT','ENGINEERING_LEAD','QA_LEAD',
                      'SECURITY_LEAD','RELEASE_OWNER','PROJECT_ADMIN')),
  artifact_ids      UUID[] NOT NULL CHECK (cardinality(artifact_ids) > 0),
  artifact_hashes   JSONB NOT NULL CHECK (jsonb_typeof(artifact_hashes) = 'array'
                                          AND jsonb_array_length(artifact_hashes) > 0),
  policy_version    TEXT NOT NULL,
  requested_by      TEXT NOT NULL,       -- actor ref of requester, e.g. workflow:<id> or agent:<key>@<ver>
  requested_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at        TIMESTAMPTZ,          -- expiry blocks progression; never auto-approves
  decided_by        UUID REFERENCES users(id),
  decided_at        TIMESTAMPTZ,
  comments          TEXT,
  FOREIGN KEY (organization_id, workflow_id) REFERENCES workflows (organization_id, id),
  CHECK ((status IN ('APPROVED','REJECTED')) = (decided_by IS NOT NULL AND decided_at IS NOT NULL)),
  CHECK (status <> 'REJECTED' OR length(coalesce(trim(comments), '')) > 0)
);
-- At most one open approval per gate.
CREATE UNIQUE INDEX uq_approvals_pending ON approvals (workflow_id, stage_key) WHERE status = 'PENDING';
CREATE INDEX idx_approvals_inbox ON approvals (status, required_role, requested_at);

-- Decided approvals are frozen.
CREATE FUNCTION guard_approval() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.status <> 'PENDING' THEN
    RAISE EXCEPTION 'Approval % is already %', OLD.id, OLD.status;
  END IF;
  IF NEW.artifact_ids IS DISTINCT FROM OLD.artifact_ids
     OR NEW.artifact_hashes IS DISTINCT FROM OLD.artifact_hashes
     OR NEW.required_role IS DISTINCT FROM OLD.required_role
     OR NEW.workflow_id IS DISTINCT FROM OLD.workflow_id
     OR NEW.stage_key IS DISTINCT FROM OLD.stage_key THEN
    RAISE EXCEPTION 'Approval binding fields are immutable';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER trg_approvals_guard BEFORE UPDATE ON approvals
  FOR EACH ROW EXECUTE FUNCTION guard_approval();

-- Down Migration
DROP TABLE IF EXISTS approvals;
DROP FUNCTION IF EXISTS guard_approval();
DROP TABLE IF EXISTS artifacts;
DROP FUNCTION IF EXISTS guard_artifact();
