# Implementation Decisions

The spec (`docs/spec/…`) says *what* to build and leaves several *how* choices open. This file
closes them so every epic is built the same way. Each decision lists what to do and why.
Changing one requires a new entry that supersedes it — don't silently drift.

Library versions: pin exact versions in `package.json` at install time. Pick releases at
least two weeks old. Where a decision names a library, confirm its current major version is
compatible with the others before installing, and record the pinned versions in the E01 PR.

---

### D-001 Toolchain
- Node.js active LTS, pinned in `.nvmrc` and `package.json#engines`. pnpm, pinned via `packageManager`.
- Nx latest stable at E01 start, pinned; `@nx/angular`, `@nx/nest`, `@nx/js`, `@nx/eslint`, `@nx/jest`, `@nx/playwright` at the same version.
- TypeScript `strict: true`, plus `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noImplicitOverride`.
- ESLint flat config with `@nx/enforce-module-boundaries` as an error. Prettier for formatting.

*Why:* the spec requires pinned, reproducible toolchains (09 §8) and enforced boundaries (09 §3).

### D-002 Database and migrations
- PostgreSQL 16+. SQL-first migrations in `db/migrations`, run by **node-pg-migrate** in SQL mode (`-- Up Migration` / `-- Down Migration` markers; verified with node-pg-migrate 9).
- Three roles (see `infra/containers/postgres/init/01-roles.sql`): `factory_migrator` owns the schema and runs migrations; `factory_app_role` is a NOLOGIN group role receiving DML grants; `factory_api` is the LOGIN role the services use.
- `db/tests/schema-guards.sql` and `db/tests/rls-coverage.sql` run in CI after migrations (`pnpm db:verify`).

*Why:* the schema leans on triggers, composite FKs and RLS. ORMs that generate migrations fight that; plain SQL keeps the database the authority and is readable by an enterprise DBA.

### D-003 Query layer
- **Kysely** for queries, **kysely-codegen** generating `libs/infrastructure/postgres/src/generated/db.ts` from the migrated database. No ORM entities, no `synchronize`.
- Repositories live in `libs/infrastructure/postgres` and implement port interfaces declared in domain/application libraries.

*Why:* type-safe SQL without hiding it; codegen keeps types honest to the real schema.

### D-004 Tenant context and RLS
- `withTenantContext({orgId, userId}, fn)` opens a transaction and runs
  `SELECT set_config('app.current_org_id', $1, true), set_config('app.current_user_id', $2, true)`
  before `fn(trx)`. (`SET LOCAL` cannot take bind parameters; `set_config(..., true)` is the parameterised equivalent.)
- Repositories accept a transaction handle; they never open their own connection. A request with no tenant context sees no tenant rows (fail-closed, verified by `schema-guards.sql`).
- Platform catalog rows (`organization_id IS NULL`) are written only by seed/sync tooling running as `factory_migrator`.

*Why:* RLS is defence in depth (05 §4). Application authorization is still required and comes first.

### D-005 Validation and contracts
- **Zod** is the single runtime validation library at every boundary (resolves 09 §6 "select one").
- Contracts live in `libs/shared/contracts`, versioned by folder (`agent-task/v1/…`).
- JSON Schemas are generated into `schemas/` with Zod's JSON Schema export and committed; CI fails if regeneration produces a diff.
- HTTP DTOs and OpenAPI via **nestjs-zod** (confirm Zod-major compatibility at install; if incompatible, use `@asteasolutions/zod-to-openapi` with a thin validation pipe).

*Why:* one schema language for HTTP, Temporal payloads, agent envelopes and events means one source of truth per shape.

### D-006 Identity (human users)
- The API speaks **OIDC only**: it validates bearer access tokens (JWT) with **jose** against the IdP's JWKS, checking `iss`, `aud`, `exp`, `nbf` and allowed algorithms. Stateless; no server sessions.
- SAML enterprises are supported by brokering through an OIDC-capable IdP (Keycloak, Entra ID, Okta) — the API never parses SAML.
- Local/dev IdP: **Keycloak** with a realm export in `infra/containers/keycloak/`.
- Portal: Authorization Code + PKCE via **angular-auth-oidc-client**; tokens in memory, silent renew via refresh token rotation.
- First login upserts a `users` row keyed by `(iss, sub)`. Email is informational, never an identity key.

*Why:* 06 §2 requires enterprise SSO; OIDC-only keeps the attack surface small and the IdP swappable by configuration.

### D-007 Tenant selection
- Organization-scoped routes take the active organization from the `X-Organization-Id` header — a *selector*, accepted only if the user has a membership there.
- Project-scoped routes (`/projects/{projectId}/…`) derive the organization from the project row, then check membership.
- Request bodies never carry tenant identity.

### D-008 Authorization
- Global deny-by-default guard. Each route declares `@RequirePermission('<permission>')` (or `@Public()` for health/OpenAPI only).
- Roles are mapped to permissions in one table in `libs/domain/access` (see E02 brief). Role assignment (memberships) is separate from permission evaluation (the map).
- A unit test enumerates every registered route and fails if any lacks a permission declaration.

### D-009 Secrets
- `SecretResolver` port resolving references: `env://NAME` (local/dev only — refused when `FACTORY_ENV` is `STAGING` or `PRODUCTION`), `vault://mount/path#key`. `aws-sm://` and `azure-kv://` are declared but implemented later (E12).
- Resolved secrets are never logged, cached beyond their TTL, or placed in prompts.

### D-010 Errors, correlation and logging
- Error envelope `{code, message, correlationId, details?}` from a single exception filter. `code` is a stable machine string (e.g. `PROJECT_KEY_TAKEN`).
- Correlation: accept `X-Correlation-Id` if it's a UUID, else generate; store in AsyncLocalStorage (**nestjs-cls**); echo in response header; attach to logs, audit events, outbox events and outbound calls.
- Logging: **pino** via **nestjs-pino**, JSON, with redaction paths for `authorization`, `cookie`, `*.token`, `*.secret`, `*.password`, `*.apiKey`.

### D-011 API conventions
- Prefix `/api/v1`. UUID ids. Cursor pagination (`limit` ≤ 100, opaque `cursor`).
- Mutations accept `Idempotency-Key` (table `api_idempotency_keys`): same key + same request hash → stored response; same key + different hash → `422 IDEMPOTENCY_KEY_REUSED`.
- Optimistic concurrency with `ETag` / `If-Match` on resources that carry `row_version` or `config_version`.
- OpenAPI served at `/api/v1/openapi.json` and exported to `schemas/openapi/factory-api.json` in CI.

### D-012 Audit
- `AuditWriter` port; every privileged mutation writes its audit event inside the same transaction as the change.
- Action names are dotted, past-tense facts: `project.created`, `membership.role.granted`, `agent.version.promoted`.
- Hash chaining (`prev_event_hash`, `event_hash`) is filled from E12; columns exist now.

### D-013 Agent definitions as code
- Agent manifests (`agents/manifests/*.yaml`), prompts (`agents/prompts/`), skills (`agents/skills/`), tool profiles and model profiles are version-controlled and reviewed (09 §10).
- A sync tool (`pnpm agents:sync`, E03) validates them and loads them into the registry. Hashes use SHA-256 over canonical content (RFC 8785 JSON canonicalisation for manifests; raw UTF-8 bytes with normalised `\n` line endings for prompts).
- Changing a released version's content is an error — bump the version.

### D-014 Testing
- Unit: Jest (Nx default). Domain libraries reach full branch coverage on permission and transition logic.
- Integration: Jest + **Testcontainers** PostgreSQL, running real migrations, connecting as `factory_api`.
- E2E: Playwright for the portal against the local stack.
- Contract tests: fixture-driven tests for every contract version in `libs/testing/contract-testing`.

### D-015 Local infrastructure
- `infra/docker-compose.yml`: PostgreSQL 16, Redis 7, Keycloak, Temporal dev server + UI, MinIO (S3-compatible artifact store). Images pinned by exact tag.
- Temporal and MinIO are started from E01 so the stack doesn't change shape later, but are unused until E04.

### D-016 Deployment packaging (shape only until E14)
- Each app builds to its own container image (`infra/containers/<app>/Dockerfile`, non-root user, distroless or slim base).
- Helm chart skeleton in `infra/deployment/helm/` from E01, filled in as services appear.

### D-017 Model access
- `model_profiles` map a logical alias (`reasoning-large`, `coding`, `fast`) to a provider: `ANTHROPIC`, `AWS_BEDROCK` or `GOOGLE_VERTEX`. Agents reference aliases only, so an enterprise that permits Claude only through its cloud account switches provider by configuration.
