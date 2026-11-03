-- Up Migration
-- Row-level security as defence in depth (05 §4). Application authorization in NestJS
-- remains the primary control; these policies make a missed tenant filter fail closed.
--
-- Contract: the API runs every request in a transaction that first executes
--   SET LOCAL app.current_org_id = '<org uuid>'; SET LOCAL app.current_user_id = '<user uuid>';
-- The table owner (migration role) bypasses RLS and is used only for migrations and seeds.

-- 1. Tables where every row belongs to exactly one organization.
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'projects','repositories','policy_bindings','workflows','workflow_stages','tasks',
    'task_dependencies','agent_executions','outbox_events','artifacts','approvals',
    'tool_invocations','trace_sources'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (organization_id = app_current_org_id()) '
      'WITH CHECK (organization_id = app_current_org_id())', t);
  END LOOP;
END
$$;

-- 2. Catalog tables: organization_id NULL rows are platform entries, readable by all
--    tenants but writable only by the owner role (i.e. through migrations/seed tooling).
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'policy_bundles','model_profiles','tool_profiles','agent_definitions','agent_versions',
    'evaluation_runs'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY catalog_read ON %I FOR SELECT '
      'USING (organization_id IS NULL OR organization_id = app_current_org_id())', t);
    EXECUTE format(
      'CREATE POLICY catalog_insert ON %I FOR INSERT '
      'WITH CHECK (organization_id = app_current_org_id())', t);
    EXECUTE format(
      'CREATE POLICY catalog_update ON %I FOR UPDATE '
      'USING (organization_id = app_current_org_id()) WITH CHECK (organization_id = app_current_org_id())', t);
    EXECUTE format(
      'CREATE POLICY catalog_delete ON %I FOR DELETE '
      'USING (organization_id = app_current_org_id())', t);
  END LOOP;
END
$$;

-- 3. Organizations: a user sees organizations they belong to; writes need matching context.
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
CREATE POLICY org_read ON organizations FOR SELECT
  USING (id = app_current_org_id()
         OR id IN (SELECT organization_id FROM memberships WHERE user_id = app_current_user_id()));
CREATE POLICY org_write ON organizations FOR INSERT WITH CHECK (id = app_current_org_id());
CREATE POLICY org_update ON organizations FOR UPDATE
  USING (id = app_current_org_id()) WITH CHECK (id = app_current_org_id());

-- 4. Memberships: readable in the current org, plus the caller's own rows in any org
--    (needed to resolve which organizations a user may switch into).
ALTER TABLE memberships ENABLE ROW LEVEL SECURITY;
CREATE POLICY membership_read ON memberships FOR SELECT
  USING (organization_id = app_current_org_id() OR user_id = app_current_user_id());
CREATE POLICY membership_write ON memberships FOR INSERT
  WITH CHECK (organization_id = app_current_org_id());
CREATE POLICY membership_update ON memberships FOR UPDATE
  USING (organization_id = app_current_org_id()) WITH CHECK (organization_id = app_current_org_id());
CREATE POLICY membership_delete ON memberships FOR DELETE
  USING (organization_id = app_current_org_id());

-- 5. Audit events: tenant-scoped reads; inserts allowed for the current org or platform scope.
ALTER TABLE audit_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_read ON audit_events FOR SELECT
  USING (organization_id = app_current_org_id());
CREATE POLICY audit_insert ON audit_events FOR INSERT
  WITH CHECK (organization_id IS NULL OR organization_id = app_current_org_id());

-- users is a global identity table (no tenant column). The API must only expose users
-- through membership-scoped queries.

-- 6. Grants for the application role. History tables lose UPDATE/DELETE where relevant.
GRANT USAGE ON SCHEMA public TO factory_app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO factory_app_role;
GRANT EXECUTE ON FUNCTION app_current_org_id(), app_current_user_id() TO factory_app_role;
REVOKE UPDATE, DELETE, TRUNCATE ON audit_events FROM factory_app_role;
REVOKE DELETE, TRUNCATE ON approvals, artifacts, agent_executions, tool_invocations,
  workflow_stages, workflows FROM factory_app_role;
-- The migration runner's own table must not be writable by the app.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'pgmigrations') THEN
    REVOKE ALL ON pgmigrations FROM factory_app_role;
  END IF;
END
$$;

-- Down Migration
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'pgmigrations') THEN
    REVOKE ALL ON pgmigrations FROM factory_app_role;
  END IF;
END
$$;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM factory_app_role;
REVOKE EXECUTE ON FUNCTION app_current_org_id(), app_current_user_id() FROM factory_app_role;
REVOKE USAGE ON SCHEMA public FROM factory_app_role;

DROP POLICY IF EXISTS audit_insert ON audit_events;
DROP POLICY IF EXISTS audit_read ON audit_events;
ALTER TABLE audit_events DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS membership_delete ON memberships;
DROP POLICY IF EXISTS membership_update ON memberships;
DROP POLICY IF EXISTS membership_write ON memberships;
DROP POLICY IF EXISTS membership_read ON memberships;
ALTER TABLE memberships DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS org_update ON organizations;
DROP POLICY IF EXISTS org_write ON organizations;
DROP POLICY IF EXISTS org_read ON organizations;
ALTER TABLE organizations DISABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'policy_bundles','model_profiles','tool_profiles','agent_definitions','agent_versions',
    'evaluation_runs'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS catalog_delete ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS catalog_update ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS catalog_insert ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS catalog_read ON %I', t);
    EXECUTE format('ALTER TABLE %I DISABLE ROW LEVEL SECURITY', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY[
    'projects','repositories','policy_bindings','workflows','workflow_stages','tasks',
    'task_dependencies','agent_executions','outbox_events','artifacts','approvals',
    'tool_invocations','trace_sources'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', t);
    EXECUTE format('ALTER TABLE %I DISABLE ROW LEVEL SECURITY', t);
  END LOOP;
END
$$;
