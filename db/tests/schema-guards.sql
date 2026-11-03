-- Schema guard smoke test. Run against a freshly migrated database as the migration (owner) role:
--   psql "$MIGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/schema-guards.sql
-- The RLS section switches to factory_app_role, so the running role needs SET permission on it
-- (granted below; works when the migration role created factory_app_role or has ADMIN on it).
-- Everything runs in one transaction and is rolled back.
-- Port these cases to Jest integration tests (E01-02, E02-02); keep this file as the
-- fast DB-level regression check in CI.

\set QUIET on
\pset tuples_only on
\o /dev/null
BEGIN;

CREATE FUNCTION pg_temp.expect_error(stmt TEXT, label TEXT) RETURNS void
  LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS  % [%]', label, SQLERRM;
    RETURN;
  END;
  RAISE EXCEPTION 'FAIL  % (statement succeeded but should have been rejected)', label;
END $$;

CREATE FUNCTION pg_temp.expect_count(stmt TEXT, expected BIGINT, label TEXT) RETURNS void
  LANGUAGE plpgsql AS $$
DECLARE n BIGINT;
BEGIN
  EXECUTE stmt INTO n;
  IF n IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'FAIL  % (expected %, got %)', label, expected, n;
  END IF;
  RAISE NOTICE 'PASS  %', label;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.expect_error(TEXT, TEXT), pg_temp.expect_count(TEXT, BIGINT, TEXT) TO factory_app_role;
DO $$ BEGIN EXECUTE format('GRANT USAGE ON SCHEMA %I TO factory_app_role', pg_my_temp_schema()::regnamespace); END $$;
GRANT factory_app_role TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;

-- ---------- Seed (as owner; RLS bypassed) ----------
INSERT INTO organizations (id, name, slug) VALUES
  ('a0000000-0000-0000-0000-000000000001', 'Org A', 'org-a'),
  ('b0000000-0000-0000-0000-000000000001', 'Org B', 'org-b');
INSERT INTO users (id, external_issuer, external_subject, email) VALUES
  ('c0000000-0000-0000-0000-000000000001', 'https://idp.local', 'alice', 'alice@example.test');
INSERT INTO projects (id, organization_id, project_key, name) VALUES
  ('a1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'alpha', 'Alpha'),
  ('b1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'bravo', 'Bravo');
INSERT INTO memberships (organization_id, project_id, user_id, role) VALUES
  ('a0000000-0000-0000-0000-000000000001', NULL, 'c0000000-0000-0000-0000-000000000001', 'ORGANIZATION_OWNER');
INSERT INTO model_profiles (id, profile_key, provider, model_alias) VALUES
  ('d0000000-0000-0000-0000-000000000001', 'reasoning-large', 'ANTHROPIC', 'reasoning-large');
INSERT INTO tool_profiles (id, profile_key, version, allowed_tools, risk_ceiling) VALUES
  ('d1000000-0000-0000-0000-000000000001', 'analysis', '1.0.0', '["mcp-jira:get_issue"]', 'T0');
INSERT INTO agent_definitions (id, agent_key, display_name, agent_group, agent_class, owner) VALUES
  ('d2000000-0000-0000-0000-000000000001', 'ba', 'Business Analyst', 'Requirements', 'ANALYSIS', 'platform-ai');
INSERT INTO agent_versions (id, agent_definition_id, version, prompt_ref, prompt_hash, tool_profile_id,
  model_profile_id, allowed_adapters, input_schema_ref, output_schema_ref, budgets, manifest, manifest_hash)
VALUES ('d3000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001', '1.0.0',
  'agents/prompts/ba.md', repeat('a', 64), 'd1000000-0000-0000-0000-000000000001',
  'd0000000-0000-0000-0000-000000000001', ARRAY['CLAUDE_CODE'], 'schema://agent-task-input/1.0',
  'schema://agent-task-output/1.0', '{"maxDurationSeconds":1800}', '{}', repeat('b', 64));
INSERT INTO workflows (id, organization_id, project_id, workflow_type, title, created_by) VALUES
  ('a2000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001',
   'a1000000-0000-0000-0000-000000000001', 'FEATURE_DELIVERY', 'Loyalty points',
   'c0000000-0000-0000-0000-000000000001');

-- ---------- Structural guards (owner) ----------
SELECT pg_temp.expect_error($$
  INSERT INTO workflows (organization_id, project_id, workflow_type, title, created_by)
  VALUES ('a0000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
          'FEATURE_DELIVERY', 'cross-tenant', 'c0000000-0000-0000-0000-000000000001') $$,
  'composite FK blocks workflow in org A pointing at project in org B');

SELECT pg_temp.expect_error($$
  INSERT INTO memberships (organization_id, project_id, user_id, role)
  VALUES ('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
          'c0000000-0000-0000-0000-000000000001', 'PLATFORM_ADMIN') $$,
  'org-level role cannot be bound to a project');

SELECT pg_temp.expect_error($$
  INSERT INTO tool_profiles (profile_key, version, allowed_tools, risk_ceiling)
  VALUES ('god-mode', '1.0.0', '[]', 'T3') $$,
  'tool profile cannot carry T3 risk ceiling');

SELECT pg_temp.expect_error($$
  INSERT INTO repositories (organization_id, project_id, provider, external_repo_id, full_name,
    default_branch, credential_secret_ref)
  VALUES ('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'GITHUB',
    '1', 'acme/alpha', 'main', 'ghp_plaintexttoken') $$,
  'repository credential must be a secret reference, not a raw token');

-- ---------- Agent version immutability ----------
SELECT pg_temp.expect_error($$
  UPDATE agent_versions SET status = 'ACTIVE', promoted_by = 'c0000000-0000-0000-0000-000000000001'
  WHERE id = 'd3000000-0000-0000-0000-000000000001' $$,
  'DRAFT cannot jump straight to ACTIVE');
UPDATE agent_versions SET status = 'CANDIDATE' WHERE id = 'd3000000-0000-0000-0000-000000000001';
SELECT pg_temp.expect_error($$
  UPDATE agent_versions SET prompt_hash = repeat('c', 64)
  WHERE id = 'd3000000-0000-0000-0000-000000000001' $$,
  'released agent version content is immutable');
SELECT pg_temp.expect_error($$
  UPDATE agent_versions SET status = 'ACTIVE' WHERE id = 'd3000000-0000-0000-0000-000000000001' $$,
  'promotion requires promoted_by');
UPDATE agent_versions SET status = 'ACTIVE', promoted_by = 'c0000000-0000-0000-0000-000000000001'
  WHERE id = 'd3000000-0000-0000-0000-000000000001';
SELECT pg_temp.expect_error($$
  DELETE FROM agent_versions WHERE id = 'd3000000-0000-0000-0000-000000000001' $$,
  'released agent version cannot be deleted');

-- ---------- Artifacts and approvals ----------
INSERT INTO artifacts (id, organization_id, workflow_id, artifact_type, uri, version, sha256) VALUES
  ('a3000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001',
   'a2000000-0000-0000-0000-000000000001', 'requirements-baseline', 'artifact://alpha/req/1', '1.0.0',
   repeat('e', 64));
SELECT pg_temp.expect_error($$
  UPDATE artifacts SET sha256 = repeat('f', 64) WHERE id = 'a3000000-0000-0000-0000-000000000001' $$,
  'artifact content hash is immutable');

INSERT INTO approvals (id, organization_id, workflow_id, stage_key, required_role, artifact_ids,
  artifact_hashes, policy_version, requested_by) VALUES
  ('a4000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001',
   'a2000000-0000-0000-0000-000000000001', 'REQUIREMENT_REVIEW', 'PRODUCT_OWNER',
   ARRAY['a3000000-0000-0000-0000-000000000001']::uuid[], '["sha256:eeee"]', '2026.1', 'workflow:test');
SELECT pg_temp.expect_error($$
  INSERT INTO approvals (organization_id, workflow_id, stage_key, required_role, artifact_ids,
    artifact_hashes, policy_version, requested_by)
  VALUES ('a0000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001',
    'REQUIREMENT_REVIEW', 'PRODUCT_OWNER', ARRAY['a3000000-0000-0000-0000-000000000001']::uuid[],
    '["sha256:eeee"]', '2026.1', 'workflow:test') $$,
  'only one pending approval per gate');
SELECT pg_temp.expect_error($$
  UPDATE approvals SET status = 'REJECTED', decided_by = 'c0000000-0000-0000-0000-000000000001',
    decided_at = now() WHERE id = 'a4000000-0000-0000-0000-000000000001' $$,
  'rejection requires a reason');
SELECT pg_temp.expect_error($$
  UPDATE approvals SET status = 'APPROVED' WHERE id = 'a4000000-0000-0000-0000-000000000001' $$,
  'approval requires decided_by and decided_at');
UPDATE approvals SET status = 'APPROVED', decided_by = 'c0000000-0000-0000-0000-000000000001',
  decided_at = now() WHERE id = 'a4000000-0000-0000-0000-000000000001';
SELECT pg_temp.expect_error($$
  UPDATE approvals SET comments = 'edited later' WHERE id = 'a4000000-0000-0000-0000-000000000001' $$,
  'decided approval is frozen');

-- ---------- Tool invocations and audit ----------
SELECT pg_temp.expect_error($$
  INSERT INTO tool_invocations (organization_id, project_id, actor_type, actor_ref, server_id,
    tool_name, risk_tier, decision, status)
  VALUES ('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'AGENT',
    'agent:backend-developer@1.0.0', 'mcp-github', 'merge_pull_request', 'T3', 'ALLOW', 'SUCCEEDED') $$,
  'agent can never be allowed a T3 tool call');

INSERT INTO audit_events (id, organization_id, actor_type, actor_id, action, resource_type, outcome)
VALUES ('a5000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'USER',
  'c0000000-0000-0000-0000-000000000001', 'project.created', 'project', 'SUCCESS');
SELECT pg_temp.expect_error($$
  UPDATE audit_events SET action = 'tampered' WHERE id = 'a5000000-0000-0000-0000-000000000001' $$,
  'audit events cannot be updated, even by the owner');
SELECT pg_temp.expect_error($$
  DELETE FROM audit_events WHERE id = 'a5000000-0000-0000-0000-000000000001' $$,
  'audit events cannot be deleted, even by the owner');

-- ---------- Row-level security (as application role) ----------
SET LOCAL ROLE factory_app_role;

SELECT pg_temp.expect_count($$ SELECT count(*) FROM projects $$, 0,
  'no tenant context -> no project rows visible (fail closed)');

SET LOCAL app.current_org_id = 'a0000000-0000-0000-0000-000000000001';
SET LOCAL app.current_user_id = 'c0000000-0000-0000-0000-000000000001';

SELECT pg_temp.expect_count($$ SELECT count(*) FROM projects $$, 1,
  'org A context sees exactly its own project');
SELECT pg_temp.expect_count($$ SELECT count(*) FROM projects WHERE project_key = 'bravo' $$, 0,
  'org A context cannot see org B project');
SELECT pg_temp.expect_count($$ SELECT count(*) FROM organizations $$, 1,
  'user sees only organizations they belong to');
SELECT pg_temp.expect_count($$ SELECT count(*) FROM agent_definitions $$, 1,
  'platform catalog agents are visible to tenants');
SELECT pg_temp.expect_error($$
  INSERT INTO projects (organization_id, project_key, name)
  VALUES ('b0000000-0000-0000-0000-000000000001', 'sneaky', 'Sneaky') $$,
  'cannot insert a row into another tenant');
SELECT pg_temp.expect_count($$
  WITH u AS (UPDATE agent_definitions SET display_name = 'hijacked' WHERE agent_key = 'ba' RETURNING 1)
  SELECT count(*) FROM u $$, 0,
  'tenant cannot modify platform catalog rows (update matches zero rows)');
SELECT pg_temp.expect_error($$
  UPDATE audit_events SET action = 'x' $$,
  'application role has no UPDATE on audit_events');
SELECT pg_temp.expect_error($$
  DELETE FROM approvals $$,
  'application role has no DELETE on approvals');

RESET ROLE;
\o
\echo 'All schema guard checks passed.'
ROLLBACK;
