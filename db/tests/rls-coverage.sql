-- RLS coverage check. Fails if any table with an organization_id column does not have
-- row-level security enabled, or is not granted to factory_app_role.
-- Run in CI after migrations:  psql "$MIGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/rls-coverage.sql
DO $$
DECLARE
  missing_rls   TEXT;
  missing_grant TEXT;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO missing_rls
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'organization_id' AND NOT a.attisdropped
  WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND NOT c.relrowsecurity;

  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO missing_grant
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND c.relname <> 'pgmigrations'
    AND NOT has_table_privilege('factory_app_role', c.oid, 'SELECT');

  IF missing_rls IS NOT NULL THEN
    RAISE EXCEPTION 'Tenant tables without row-level security: %', missing_rls;
  END IF;
  IF missing_grant IS NOT NULL THEN
    RAISE EXCEPTION 'Tables not granted to factory_app_role: %', missing_grant;
  END IF;
  RAISE NOTICE 'RLS coverage OK';
END
$$;
