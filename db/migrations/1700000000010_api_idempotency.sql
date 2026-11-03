-- Up Migration
-- Idempotency-Key support for mutating API endpoints (05 §6).
-- A replay with the same key and same request hash returns the stored response;
-- the same key with a different request hash is rejected with 422.

CREATE TABLE api_idempotency_keys (
  organization_id   UUID NOT NULL REFERENCES organizations(id),
  user_id           UUID NOT NULL REFERENCES users(id),
  idempotency_key   TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 200),
  method            TEXT NOT NULL,
  route             TEXT NOT NULL,            -- route template, e.g. POST /api/v1/projects
  request_hash      CHAR(64) NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  state             TEXT NOT NULL DEFAULT 'IN_PROGRESS' CHECK (state IN ('IN_PROGRESS','COMPLETED')),
  response_status   INTEGER,
  response_body     JSONB,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at        TIMESTAMPTZ NOT NULL DEFAULT now() + interval '24 hours',
  PRIMARY KEY (organization_id, user_id, idempotency_key)
);
CREATE INDEX idx_api_idempotency_expiry ON api_idempotency_keys (expires_at);

ALTER TABLE api_idempotency_keys ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON api_idempotency_keys
  USING (organization_id = app_current_org_id())
  WITH CHECK (organization_id = app_current_org_id());
GRANT SELECT, INSERT, UPDATE, DELETE ON api_idempotency_keys TO factory_app_role;

-- Down Migration
DROP TABLE IF EXISTS api_idempotency_keys;
