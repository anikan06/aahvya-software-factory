# Database

PostgreSQL 16 is the system of record. The schema is SQL-first: `db/migrations/*.sql` is the
authority and the TypeScript types are generated from the migrated database (D-002, D-003).

## Roles

| Role               | Login | Purpose                                                                                                                                                 |
| ------------------ | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `factory_migrator` | yes   | Owns the database and every table. Runs migrations and seed/sync tooling. **Owners bypass row-level security**, so no service may connect as this role. |
| `factory_app_role` | no    | Group role that migrations grant DML to.                                                                                                                |
| `factory_api`      | yes   | Member of `factory_app_role`. The role `factory-api` and the workers connect as; subject to RLS.                                                        |

`infra/containers/postgres/init/01-roles.sql` creates them for local development and CI. In shared
environments a DBA creates the equivalent roles and passwords come from the secrets manager.

Environment variables: `DATABASE_URL` (`factory_api`, services) and `MIGRATION_DATABASE_URL`
(`factory_migrator`, tooling). See `.env.example`. Copy it to `.env` (git-ignored) for local work;
the scripts load `.env` automatically and CI sets the variables directly.

## Commands

```bash
pnpm infra:up                  # postgres (and the rest of the stack)
pnpm db:migrate                # apply pending migrations as factory_migrator
pnpm db:migrate:down           # roll back one migration; `pnpm db:migrate:down 10` rolls back ten
pnpm db:migrate:create <name>  # new SQL migration from db/migration-template.sql
pnpm db:codegen                # regenerate libs/infrastructure/postgres/src/generated/db.ts
pnpm db:verify                 # schema guards + RLS coverage
```

If port 5432 is already in use on your machine, start the stack with `POSTGRES_PORT=5433 pnpm infra:up`
and point both URLs in `.env` at port 5433.

`db:verify` uses `psql` if it is on `PATH` (CI), otherwise runs `psql` inside the local
`factory-postgres` container.

## Adding a migration

1. `pnpm db:migrate:create <short_name>`; write both `-- Up Migration` and `-- Down Migration`.
2. **Never edit a migration that has been merged.** Add a new one.
3. New tenant-owned table checklist:
   - `organization_id` column.
   - `ENABLE ROW LEVEL SECURITY` plus a policy (see migration 009 for the patterns).
   - Explicit grants to `factory_app_role`.
   - Composite foreign keys `(organization_id, x_id) -> parent(organization_id, id)`; the parent needs `UNIQUE (organization_id, id)`.
   - `TEXT` + `CHECK` for statuses (no Postgres enums); `TIMESTAMPTZ` for all timestamps; JSONB only for versioned config or variable metadata.
4. Apply, regenerate types, verify:
   ```bash
   pnpm db:migrate && pnpm db:codegen && pnpm db:verify
   ```
5. Prove reversibility: `pnpm db:migrate:down` then `pnpm db:migrate`. CI runs the full cycle (up, down 10, up).
6. Commit the migration and the regenerated `generated/db.ts` together. CI fails if the generated file is stale.

## Rolling back

`pnpm db:migrate:down [count]` runs the `-- Down Migration` sections newest-first. Down migrations are
for development and for backing out a bad deploy _before_ data depends on the change. In a shared
environment, prefer a forward migration that fixes the problem. Roles are cluster-wide, so the foundation
migration deliberately leaves `factory_app_role` in place.

## How row-level security gets its context

RLS policies read `app_current_org_id()` and `app_current_user_id()`, which read the settings
`app.current_org_id` and `app.current_user_id`. With no setting they return `NULL`, so a query without
context matches no tenant rows (fail closed).

`libs/infrastructure/postgres` is the only place those settings are written:

- `withTenantContext(db, { organizationId, userId }, fn)` opens a transaction, runs
  `set_config('app.current_org_id', ..., true)` and `set_config('app.current_user_id', ..., true)`, then calls
  `fn(trx)`. `true` makes the setting transaction-local, so it cannot leak to the next request on a pooled connection.
- `withUserContext(db, { userId }, fn)` sets only the user id, for lookups made before an organization is
  chosen (for example, "which organizations does the caller belong to").
- Repositories receive the transaction handle (`Tx`); they never open their own connection.

Rules that follow from this (CLAUDE.md security invariants):

- The organization and user ids come from the authenticated identity and validated ownership, never from a
  request body, query string or agent output.
- Application authorization still runs first; RLS is defence in depth.
- Platform catalog rows (`organization_id IS NULL`) are written only by seed/sync tooling running as `factory_migrator`.

## Tests

| Check                                                                                    | Where                                                              | Run by                                |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------- |
| Schema guards (constraints, triggers, immutability, RLS behaviour as `factory_app_role`) | `db/tests/schema-guards.sql`                                       | `pnpm db:verify`                      |
| Every table with `organization_id` has RLS and grants                                    | `db/tests/rls-coverage.sql`                                        | `pnpm db:verify`                      |
| Tenant isolation through `withTenantContext` against a real PostgreSQL                   | `libs/testing/test-utilities/src/lib/tenant-isolation.int.spec.ts` | `pnpm nx test testing-test-utilities` |

The integration harness (`startPostgresHarness`) starts a throwaway PostgreSQL 16 with Testcontainers, runs the
same role bootstrap script as local infra, applies every migration as `factory_migrator`, and returns a
`factory_api` connection (`db`) for the code under test plus an owner connection (`adminDb`) for seeding and
assertions. It needs a reachable Docker daemon.

The harness and these specs live in `libs/testing/test-utilities` because the Nx boundary rules do not allow
`type:infrastructure` (or `type:application`/`type:app`) projects to depend on `type:testing`. Add new database
integration specs there.
