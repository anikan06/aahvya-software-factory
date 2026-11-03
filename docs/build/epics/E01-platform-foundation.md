# E01 — Platform Foundation

**Spec:** 09 (Nx blueprint), 05 §4–§6 (database, API conventions), 01 §7 (technology baseline)
**Backlog weeks:** 1–2 · **Priority:** P0 · **Depends on:** nothing
**Milestone contribution:** M1 Foundation

## Goal

A governed Nx workspace where the API, portal and database run locally, boundaries are
enforced, the full schema is migrated, and CI proves it on every change. Nothing
user-facing beyond a health check and an empty portal shell.

## Stories (in order)

---

### E01-00 — Local infrastructure *(enabling story, not in spec backlog)*

**Build**
- `infra/docker-compose.yml` with services, all images pinned to exact tags:
  - `postgres` 16.x — mounts `infra/containers/postgres/init/` (already in repo) into `/docker-entrypoint-initdb.d`. Healthcheck with `pg_isready`.
  - `redis` 7.x
  - `keycloak` — dev mode, imports `infra/containers/keycloak/factory-realm.json` on start.
  - `temporal` — single-container dev server (Temporal CLI `server start-dev`, verify the current official image and command) with UI on 8233.
  - `minio` — with a bucket-creation init container for `factory-artifacts`.
- `infra/containers/keycloak/factory-realm.json` with:
  - realm `factory`, public client `factory-portal` (Auth Code + PKCE, redirect `http://localhost:4200/*`), and an audience mapper so access tokens carry `aud: factory-api`.
  - Two test users: `alice` (will become org owner) and `bob` (no memberships). Passwords documented in the README as local-only.
- `.env.example` with placeholders only: `DATABASE_URL` (factory_api), `MIGRATION_DATABASE_URL` (factory_migrator), `OIDC_ISSUER`, `OIDC_AUDIENCE`, `FACTORY_ENV=LOCAL`, `REDIS_URL`, `TEMPORAL_ADDRESS`, `S3_ENDPOINT`, `S3_BUCKET`.
- Root scripts: `infra:up`, `infra:down`, `infra:reset` (drops volumes).

**Acceptance criteria**
- `pnpm infra:up` brings every service to healthy on a clean machine.
- `psql` as `factory_api` and as `factory_migrator` both succeed with the local passwords.
- Keycloak issues an access token for `alice` whose `aud` includes `factory-api`.

---

### E01-01 — Create Nx workspace

**Build**
- Nx workspace (pnpm, integrated monorepo) per D-001. Apps: `factory-portal` (Angular, standalone, Material, SCSS), `factory-portal-e2e` (Playwright), `factory-api` (NestJS).
- Libraries for this epic, each tagged per `docs/build/repo-structure.md`:
  `shared/contracts`, `shared/types`, `shared/utilities`, `api/platform`, `infrastructure/postgres`, `testing/test-utilities`, `ui/design-system`, `ui/shell`.
- `eslint.config.mjs` with the boundary rules from `repo-structure.md` verbatim.
- `tsconfig.base.json` strict settings from D-001; path aliases `@factory/...`.
- `tools` Nx project (scope:tools) — empty for now, used from E03.
- README: prerequisites, setup, every command in CLAUDE.md's Commands section, local credentials table.
- CI (`.github/workflows/ci.yml`): pnpm install with frozen lockfile → format check → `nx affected -t lint typecheck test build` (base = merge-base with main) → Postgres service container + `db:migrate` + `db:verify` → secrets scan (gitleaks) → dependency audit (`pnpm audit --audit-level high`, report-only for now).

**Acceptance criteria** (spec + concrete)
- Angular portal and NestJS API projects exist and `nx serve` runs each.
- Strict TypeScript and linting are configured; `nx run-many -t lint typecheck` is clean.
- Project tags and module-boundary rules are enforced: a deliberate test import from `ui/shell` → `infrastructure/postgres` fails lint (verify, then revert).
- CI runs affected lint/test/build and the DB checks.
- README contains local setup instructions a new engineer can follow end to end.

---

### E01-02 — Establish platform database

The full schema already exists in `db/migrations/` (migrations 001–010, tested up/down/up
with node-pg-migrate 9 on PostgreSQL 16). This story wires it into the workspace.

**Build**
- Scripts: `db:migrate`, `db:migrate:down`, `db:migrate:create` (SQL template), `db:codegen` (kysely-codegen → `libs/infrastructure/postgres/src/generated/db.ts`, committed), `db:verify` (runs `db/tests/schema-guards.sql` then `db/tests/rls-coverage.sql` via psql as `factory_migrator`).
- `libs/infrastructure/postgres`:
  - `createDb(config)` returning a Kysely instance over a `pg` Pool (connects as `factory_api`; pool size and statement timeout from config).
  - `withTenantContext(db, {orgId, userId}, fn)` per D-004. Also `withUserContext(db, {userId}, fn)` for org-less lookups (memberships of the caller).
  - `TenantContext` type with branded `OrganizationId` / `UserId` from `shared/types`.
- `docs/build/database.md`: role model, how to add a migration (checklist from CLAUDE.md), rollback procedure, how RLS context works, how to run the guard tests.
- Integration test harness in `testing/test-utilities`: Testcontainers Postgres 16 → run the init roles script → run migrations as migrator → hand tests a `factory_api` connection.

**Acceptance criteria** (spec + concrete)
- PostgreSQL migrations are versioned; `db:migrate` then `db:migrate:down 10` then `db:migrate` succeeds.
- Organization, project and workflow baseline tables exist (all 24 platform tables do).
- Migration and rollback procedure is documented in `docs/build/database.md`.
- Tenant-scoped repository tests pass: integration tests prove that through `withTenantContext` org A cannot read, insert into or update org B rows in `projects` and `workflows`, and that with no context zero tenant rows are visible.
- `pnpm db:verify` passes locally and in CI.

---

### E01-03 — API foundation

**Build** (in `libs/api/platform`, wired in `apps/factory-api`)
- Global prefix `/api/v1`; `GET /api/v1/health` (public) returning `{status, checks: {database, redis}}` with 503 if a dependency is down; `GET /api/v1/health/live` for liveness.
- Config module: env parsed and validated by a Zod schema at startup; the process exits with a clear message on invalid config.
- Correlation per D-010: middleware + nestjs-cls; `X-Correlation-Id` echoed.
- Global exception filter producing the error envelope; maps Zod validation errors to `400 VALIDATION_FAILED` with field paths in `details`; unknown errors → `500 INTERNAL_ERROR` with no internals leaked.
- Validation per D-005 (nestjs-zod pipe). DTO schemas imported from `shared/contracts`.
- OpenAPI at `/api/v1/openapi.json`; `tools` target `export-openapi` writes `schemas/openapi/factory-api.json`; CI fails if it's stale.
- Logging per D-010 with redaction; request log line includes method, route template, status, duration, correlationId — never headers or bodies.
- Idempotency interceptor per D-011 backed by `api_idempotency_keys` (opt-in via `@Idempotent()` decorator; it will need tenant context, so register it now and apply it to routes from E02).
- Security headers (helmet), CORS restricted to configured portal origin, request body size limit (1 MB default).
- Portal: `ui/shell` with a Material layout, a home page calling `/health`, and an environment config for the API base URL. No auth yet.

**Acceptance criteria** (spec + concrete)
- `/api/v1/health` is available and reflects dependency state.
- OpenAPI is generated and exported.
- Standard error envelope and correlation ID middleware exist; every error response carries `correlationId` matching the response header.
- DTO validation rejects invalid payloads (test with a throwaway `POST /api/v1/_test/echo` route behind `FACTORY_ENV=LOCAL`, removed or guarded before E02 ends).
- A unit test proves log redaction of `authorization` and `*.secret` fields.

## Out of scope
Authentication (E02), any business endpoints, Temporal workers (E04), artifact storage usage (E04+).

## Verification before closing the epic
```bash
pnpm infra:reset && pnpm infra:up
pnpm db:migrate && pnpm db:verify
pnpm nx run-many -t lint typecheck test build
pnpm nx serve factory-api   # curl /api/v1/health, /api/v1/openapi.json
pnpm nx serve factory-portal
```
