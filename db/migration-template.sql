-- Up Migration
-- Checklist (CLAUDE.md "Database rules"): new tenant table => organization_id, RLS enabled + policy,
-- explicit grants to factory_app_role, composite FKs (organization_id, x_id) -> parent(organization_id, id).
-- TEXT + CHECK for statuses (no enums), TIMESTAMPTZ everywhere. Never edit a merged migration.


-- Down Migration
-- Must fully reverse the Up section.

