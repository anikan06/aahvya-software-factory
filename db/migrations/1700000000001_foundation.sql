-- Up Migration
-- Foundation: helper functions shared by every later migration.
-- Requires PostgreSQL 16+ (gen_random_uuid() is core; UNIQUE NULLS NOT DISTINCT is used).

-- Group role the application login user is granted. Never log in as this role directly.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'factory_app_role') THEN
    CREATE ROLE factory_app_role NOLOGIN;
  END IF;
END
$$;

-- Tenant context. The API sets these with SET LOCAL inside every request transaction:
--   SET LOCAL app.current_org_id  = '<uuid>';
--   SET LOCAL app.current_user_id = '<uuid>';
-- Row-level security policies read them through these functions.
CREATE FUNCTION app_current_org_id() RETURNS uuid
  LANGUAGE sql STABLE
  AS $$ SELECT NULLIF(current_setting('app.current_org_id', true), '')::uuid $$;

CREATE FUNCTION app_current_user_id() RETURNS uuid
  LANGUAGE sql STABLE
  AS $$ SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid $$;

CREATE FUNCTION set_updated_at() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END
$$;

-- Generic guard for append-only tables.
CREATE FUNCTION reject_mutation() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  RAISE EXCEPTION '% on % is not permitted (append-only table)', TG_OP, TG_TABLE_NAME
    USING ERRCODE = 'insufficient_privilege';
END
$$;

-- Down Migration
DROP FUNCTION IF EXISTS reject_mutation();
DROP FUNCTION IF EXISTS set_updated_at();
DROP FUNCTION IF EXISTS app_current_user_id();
DROP FUNCTION IF EXISTS app_current_org_id();
-- factory_app_role is intentionally left in place: roles are cluster-wide and may be shared.
