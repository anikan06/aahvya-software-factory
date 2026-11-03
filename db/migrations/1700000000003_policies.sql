-- Up Migration
-- Policy bundles (immutable once released) and their bindings to projects.

-- organization_id NULL = platform-provided bundle visible to every organization.
CREATE TABLE policy_bundles (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID REFERENCES organizations(id),
  bundle_key       TEXT NOT NULL CHECK (bundle_key ~ '^[a-z][a-z0-9-]{1,62}$'),
  version          TEXT NOT NULL,
  content          JSONB NOT NULL CHECK (jsonb_typeof(content) = 'object'),
  content_hash     CHAR(64) NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
  status           TEXT NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','DEPRECATED')),
  created_by       UUID REFERENCES users(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (organization_id, bundle_key, version)
);

CREATE FUNCTION guard_policy_bundle() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'DRAFT' THEN
      RAISE EXCEPTION 'Released policy bundle % % cannot be deleted', OLD.bundle_key, OLD.version;
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status <> 'DRAFT' AND (
       NEW.content IS DISTINCT FROM OLD.content OR
       NEW.content_hash IS DISTINCT FROM OLD.content_hash OR
       NEW.version IS DISTINCT FROM OLD.version OR
       NEW.bundle_key IS DISTINCT FROM OLD.bundle_key OR
       NEW.organization_id IS DISTINCT FROM OLD.organization_id) THEN
    RAISE EXCEPTION 'Released policy bundle % % is immutable; publish a new version', OLD.bundle_key, OLD.version;
  END IF;
  IF OLD.status = 'DEPRECATED' AND NEW.status <> 'DEPRECATED' THEN
    RAISE EXCEPTION 'Deprecated policy bundle cannot be reactivated';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER trg_policy_bundles_guard BEFORE UPDATE OR DELETE ON policy_bundles
  FOR EACH ROW EXECUTE FUNCTION guard_policy_bundle();

CREATE TABLE policy_bindings (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID NOT NULL,
  project_id        UUID NOT NULL,
  policy_bundle_id  UUID NOT NULL REFERENCES policy_bundles(id),
  environment       TEXT NOT NULL CHECK (environment IN ('LOCAL','DEV','STAGING','PRODUCTION')),
  created_by        UUID REFERENCES users(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id, project_id) REFERENCES projects (organization_id, id),
  UNIQUE (project_id, environment)
);

-- A project may only bind a platform bundle or one owned by its own organization,
-- and only a bundle that has been released.
CREATE FUNCTION check_policy_binding() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
DECLARE
  b policy_bundles%ROWTYPE;
BEGIN
  SELECT * INTO b FROM policy_bundles WHERE id = NEW.policy_bundle_id;
  IF b.organization_id IS NOT NULL AND b.organization_id <> NEW.organization_id THEN
    RAISE EXCEPTION 'Policy bundle belongs to another organization';
  END IF;
  IF b.status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'Only ACTIVE policy bundles can be bound (bundle % is %)', b.version, b.status;
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER trg_policy_bindings_check BEFORE INSERT OR UPDATE ON policy_bindings
  FOR EACH ROW EXECUTE FUNCTION check_policy_binding();

-- Down Migration
DROP TABLE IF EXISTS policy_bindings;
DROP FUNCTION IF EXISTS check_policy_binding();
DROP TRIGGER IF EXISTS trg_policy_bundles_guard ON policy_bundles;
DROP FUNCTION IF EXISTS guard_policy_bundle();
DROP TABLE IF EXISTS policy_bundles;
