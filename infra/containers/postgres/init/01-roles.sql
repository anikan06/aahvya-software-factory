-- Local/dev bootstrap only. Runs once as the Postgres superuser when the container's data
-- volume is first created (docker-entrypoint-initdb.d). In shared environments a DBA
-- creates the equivalent roles; passwords come from the secrets manager, never this file.
--
--   factory_migrator  owns the database and every table; runs migrations and seed tooling.
--                     Owners bypass RLS, so the API must never connect as this role.
--   factory_app_role  NOLOGIN group role that migrations grant DML to.
--   factory_api       LOGIN role used by factory-api and the workers. Member of factory_app_role.

CREATE ROLE factory_migrator LOGIN PASSWORD 'local-migrator-password';
CREATE ROLE factory_app_role NOLOGIN;
CREATE ROLE factory_api LOGIN PASSWORD 'local-api-password' IN ROLE factory_app_role;

-- Lets the migrator switch into the app role for db/tests/schema-guards.sql without
-- inheriting its privileges during normal migration runs.
GRANT factory_app_role TO factory_migrator WITH ADMIN TRUE, INHERIT FALSE, SET TRUE;

CREATE DATABASE factory OWNER factory_migrator;
\connect factory
ALTER SCHEMA public OWNER TO factory_migrator;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
