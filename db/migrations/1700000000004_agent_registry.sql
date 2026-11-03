-- Up Migration
-- Agent registry: model profiles, tool profiles, agent definitions and immutable versions.
-- organization_id NULL on these tables = platform catalog entry visible to all organizations.

CREATE TABLE model_profiles (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID REFERENCES organizations(id),
  profile_key      TEXT NOT NULL CHECK (profile_key ~ '^[a-z][a-z0-9-]{1,62}$'),
  provider         TEXT NOT NULL CHECK (provider IN ('ANTHROPIC','AWS_BEDROCK','GOOGLE_VERTEX','GITHUB_COPILOT')),
  model_alias      TEXT NOT NULL,          -- logical name used by agents, e.g. "reasoning-large"
  model_id         TEXT,                   -- pinned provider model identifier; NULL = resolved by adapter config
  limits           JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(limits) = 'object'),
  status           TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (organization_id, profile_key)
);
CREATE TRIGGER trg_model_profiles_updated_at BEFORE UPDATE ON model_profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- T3 (privileged) is deliberately not representable: autonomous agents never get it (04 §7).
CREATE TABLE tool_profiles (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID REFERENCES organizations(id),
  profile_key      TEXT NOT NULL CHECK (profile_key ~ '^[a-z][a-z0-9-]{1,62}$'),
  version          TEXT NOT NULL CHECK (version ~ '^\d+\.\d+\.\d+$'),
  allowed_tools    JSONB NOT NULL CHECK (jsonb_typeof(allowed_tools) = 'array'),
  risk_ceiling     TEXT NOT NULL CHECK (risk_ceiling IN ('T0','T1','T2')),
  status           TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DEPRECATED')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (organization_id, profile_key, version)
);

CREATE TABLE agent_definitions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID REFERENCES organizations(id),
  agent_key        TEXT NOT NULL CHECK (agent_key ~ '^[a-z][a-z0-9-]{1,62}$'),
  display_name     TEXT NOT NULL,
  agent_group      TEXT NOT NULL,          -- catalog group, e.g. Requirements, Architecture
  agent_class      TEXT NOT NULL CHECK (agent_class IN (
                     'ANALYSIS','DESIGN','DEVELOPER','QA','SECURITY','RELEASE',
                     'OBSERVABILITY','DOCUMENTATION','ANALYTICS','PLATFORM')),
  description      TEXT,
  owner            TEXT NOT NULL,          -- accountable team or person
  lifecycle        TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (lifecycle IN ('ACTIVE','RETIRED')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (organization_id, agent_key)
);
CREATE TRIGGER trg_agent_definitions_updated_at BEFORE UPDATE ON agent_definitions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE agent_versions (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id      UUID REFERENCES organizations(id),   -- copied from definition by trigger
  agent_definition_id  UUID NOT NULL REFERENCES agent_definitions(id),
  version              TEXT NOT NULL CHECK (version ~ '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$'),
  status               TEXT NOT NULL DEFAULT 'DRAFT'
                         CHECK (status IN ('DRAFT','CANDIDATE','ACTIVE','DEPRECATED')),
  prompt_ref           TEXT NOT NULL,                       -- e.g. agents/prompts/ba.md
  prompt_hash          CHAR(64) NOT NULL CHECK (prompt_hash ~ '^[0-9a-f]{64}$'),
  skill_refs           JSONB NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(skill_refs) = 'array'),
  tool_profile_id      UUID NOT NULL REFERENCES tool_profiles(id),
  model_profile_id     UUID NOT NULL REFERENCES model_profiles(id),
  allowed_adapters     TEXT[] NOT NULL
                         CHECK (cardinality(allowed_adapters) > 0
                                AND allowed_adapters <@ ARRAY['CLAUDE_CODE','GITHUB_COPILOT']::text[]),
  input_schema_ref     TEXT NOT NULL,                       -- e.g. schema://agent-task-input/1.0
  output_schema_ref    TEXT NOT NULL,
  budgets              JSONB NOT NULL CHECK (jsonb_typeof(budgets) = 'object'),
  manifest             JSONB NOT NULL CHECK (jsonb_typeof(manifest) = 'object'),
  manifest_hash        CHAR(64) NOT NULL CHECK (manifest_hash ~ '^[0-9a-f]{64}$'),
  created_by           UUID REFERENCES users(id),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  promoted_by          UUID REFERENCES users(id),
  promoted_at          TIMESTAMPTZ,
  deprecated_at        TIMESTAMPTZ,
  UNIQUE (agent_definition_id, version)
);
CREATE INDEX idx_agent_versions_status ON agent_versions (agent_definition_id, status);

-- Versions inherit their definition's tenant; released versions are immutable (08 §8).
CREATE FUNCTION guard_agent_version() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
DECLARE
  def_org UUID;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT organization_id INTO def_org FROM agent_definitions WHERE id = NEW.agent_definition_id;
    NEW.organization_id := def_org;
    IF NEW.status <> 'DRAFT' THEN
      RAISE EXCEPTION 'Agent versions must be created as DRAFT';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'DRAFT' THEN
      RAISE EXCEPTION 'Released agent version % cannot be deleted', OLD.version;
    END IF;
    RETURN OLD;
  END IF;

  -- UPDATE
  IF OLD.status <> 'DRAFT' AND (
       NEW.organization_id     IS DISTINCT FROM OLD.organization_id OR
       NEW.agent_definition_id IS DISTINCT FROM OLD.agent_definition_id OR
       NEW.version             IS DISTINCT FROM OLD.version OR
       NEW.prompt_ref          IS DISTINCT FROM OLD.prompt_ref OR
       NEW.prompt_hash         IS DISTINCT FROM OLD.prompt_hash OR
       NEW.skill_refs          IS DISTINCT FROM OLD.skill_refs OR
       NEW.tool_profile_id     IS DISTINCT FROM OLD.tool_profile_id OR
       NEW.model_profile_id    IS DISTINCT FROM OLD.model_profile_id OR
       NEW.allowed_adapters    IS DISTINCT FROM OLD.allowed_adapters OR
       NEW.input_schema_ref    IS DISTINCT FROM OLD.input_schema_ref OR
       NEW.output_schema_ref   IS DISTINCT FROM OLD.output_schema_ref OR
       NEW.budgets             IS DISTINCT FROM OLD.budgets OR
       NEW.manifest            IS DISTINCT FROM OLD.manifest OR
       NEW.manifest_hash       IS DISTINCT FROM OLD.manifest_hash) THEN
    RAISE EXCEPTION 'Agent version % is released and immutable; create a new version', OLD.version;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'DRAFT'     AND NEW.status IN ('CANDIDATE','DEPRECATED')) OR
       (OLD.status = 'CANDIDATE' AND NEW.status IN ('ACTIVE','DEPRECATED')) OR
       (OLD.status = 'ACTIVE'    AND NEW.status = 'DEPRECATED')) THEN
    RAISE EXCEPTION 'Illegal agent version transition % -> %', OLD.status, NEW.status;
  END IF;

  IF NEW.status = 'ACTIVE' AND OLD.status <> 'ACTIVE' THEN
    IF NEW.promoted_by IS NULL THEN
      RAISE EXCEPTION 'Promotion to ACTIVE requires promoted_by';
    END IF;
    NEW.promoted_at := now();
  END IF;
  IF NEW.status = 'DEPRECATED' AND OLD.status <> 'DEPRECATED' THEN
    NEW.deprecated_at := now();
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER trg_agent_versions_guard BEFORE INSERT OR UPDATE OR DELETE ON agent_versions
  FOR EACH ROW EXECUTE FUNCTION guard_agent_version();

-- Down Migration
DROP TABLE IF EXISTS agent_versions;
DROP FUNCTION IF EXISTS guard_agent_version();
DROP TABLE IF EXISTS agent_definitions;
DROP TABLE IF EXISTS tool_profiles;
DROP TABLE IF EXISTS model_profiles;
