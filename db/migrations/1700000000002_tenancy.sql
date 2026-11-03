-- Up Migration
-- Tenancy: organizations, users, projects, memberships, repositories.

CREATE TABLE organizations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  slug        TEXT NOT NULL UNIQUE CHECK (slug ~ '^[a-z][a-z0-9-]{1,62}$'),
  status      TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_organizations_updated_at BEFORE UPDATE ON organizations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Human users only. Agents and services are never rows here, so they can never
-- hold a membership and therefore never hold a human approval role (06 §3).
CREATE TABLE users (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  external_issuer   TEXT NOT NULL,
  external_subject  TEXT NOT NULL,
  email             TEXT NOT NULL,
  display_name      TEXT,
  status            TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
  last_login_at     TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (external_issuer, external_subject)
);
CREATE INDEX idx_users_email ON users (lower(email));
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE projects (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID NOT NULL REFERENCES organizations(id),
  project_key      TEXT NOT NULL CHECK (project_key ~ '^[a-z][a-z0-9-]{1,39}$'),
  name             TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  description      TEXT,
  config           JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(config) = 'object'),
  config_version   INTEGER NOT NULL DEFAULT 1,
  status           TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','ARCHIVED')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, project_key),
  UNIQUE (organization_id, id)   -- target for tenant-consistent composite FKs
);
CREATE TRIGGER trg_projects_updated_at BEFORE UPDATE ON projects
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Role bindings. project_id NULL = organization-wide binding.
CREATE TABLE memberships (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID NOT NULL REFERENCES organizations(id),
  project_id       UUID,
  user_id          UUID NOT NULL REFERENCES users(id),
  role             TEXT NOT NULL CHECK (role IN (
                     'ORGANIZATION_OWNER','PLATFORM_ADMIN','PROJECT_ADMIN','PRODUCT_OWNER',
                     'SOLUTION_ARCHITECT','ENGINEERING_LEAD','DEVELOPER','QA_LEAD',
                     'SECURITY_LEAD','RELEASE_OWNER','AUDITOR','VIEWER')),
  created_by       UUID REFERENCES users(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id, project_id) REFERENCES projects (organization_id, id),
  -- Organization-level roles cannot be bound to a single project.
  CHECK (project_id IS NULL OR role NOT IN ('ORGANIZATION_OWNER','PLATFORM_ADMIN')),
  UNIQUE NULLS NOT DISTINCT (organization_id, project_id, user_id, role)
);
CREATE INDEX idx_memberships_user ON memberships (user_id);
CREATE INDEX idx_memberships_project ON memberships (project_id) WHERE project_id IS NOT NULL;

-- Repositories. Credentials are never stored: only a secret reference such as
-- vault://kv/factory/projects/acme#github-app or env://GITHUB_APP_KEY (local only).
CREATE TABLE repositories (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id        UUID NOT NULL,
  project_id             UUID NOT NULL,
  provider               TEXT NOT NULL CHECK (provider IN ('GITHUB')),
  external_repo_id       TEXT NOT NULL,
  full_name              TEXT NOT NULL,
  default_branch         TEXT NOT NULL,
  credential_secret_ref  TEXT CHECK (credential_secret_ref ~ '^[a-z][a-z0-9+.-]*://'),
  access_validated_at    TIMESTAMPTZ,
  status                 TEXT NOT NULL DEFAULT 'PENDING_VALIDATION'
                           CHECK (status IN ('PENDING_VALIDATION','ACTIVE','ACCESS_FAILED','ARCHIVED')),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (organization_id, project_id) REFERENCES projects (organization_id, id),
  UNIQUE (project_id, provider, external_repo_id),
  UNIQUE (organization_id, id)
);
CREATE TRIGGER trg_repositories_updated_at BEFORE UPDATE ON repositories
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Down Migration
DROP TABLE IF EXISTS repositories;
DROP TABLE IF EXISTS memberships;
DROP TABLE IF EXISTS projects;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS organizations;
