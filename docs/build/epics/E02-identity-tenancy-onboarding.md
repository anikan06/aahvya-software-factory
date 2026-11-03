# E02 — Identity, Tenancy and Project Onboarding

**Spec:** 06 §2–§5, §7 (identity, RBAC, enforcement points, secrets), 05 §6–§7 (API conventions, catalog), 04 §8 (credentials)
**Backlog weeks:** 1–3 · **Priority:** P0 · **Depends on:** E01
**Milestone contribution:** M1 Foundation

## Goal

Real users sign in through OIDC, belong to organizations and projects through role bindings,
and every API call is authenticated, tenant-scoped, authorized and audited. An admin can
onboard a project with a GitHub repository (credentials as secret references only) and bind
a policy bundle — from the portal.

## Permission model (implement exactly; changes need a decision entry)

Permissions are evaluated as the union of the user's organization-level memberships and their
memberships on the project being accessed. Holding a role grants nothing outside its organization.

| Permission | Owner | Plat. Admin | Proj. Admin | PO | Architect | Eng. Lead | Dev | QA Lead | Sec. Lead | Release | Auditor | Viewer |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `org:read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `org:update` | ✓ | | | | | | | | | | | |
| `member:read` | ✓ | ✓ | ✓ | | | ✓ | | | ✓ | | ✓ | |
| `member:manage` | ✓ | | ✓ ¹ | | | | | | | | | |
| `project:create` | ✓ | ✓ | | | | | | | | | | |
| `project:read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `project:update` | ✓ | | ✓ | | | | | | | | | |
| `project:archive` | ✓ | | ✓ | | | | | | | | | |
| `repository:manage` | ✓ | ✓ | ✓ | | | | | | | | | |
| `policy:bind` | ✓ | | ✓ | | | | | | ✓ | | | |
| `agent:read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `agent:register` | ✓ | ✓ | | | | | | | | | | |
| `agent:promote` | | ✓ | | | | | | | | | | |
| `workflow:start` | | | ✓ | ✓ | | ✓ | ✓ | | | | | |
| `workflow:read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `workflow:cancel` | | | ✓ | | | ✓ | | | | | | |
| `approval:decide:requirements` | | | | ✓ | | | | | | | | |
| `approval:decide:architecture` | | | | | ✓ | | | | | | | |
| `approval:decide:merge` | | | | | | ✓ | | | | | | |
| `approval:decide:deployment` | | | | | | | | | | ✓ | | |
| `audit:read` | ✓ | ✓ | | | | | | | ✓ | | ✓ | |

¹ Project Admin manages project-level memberships on their own projects only.

Rules that are not visible in the table:
- Only `ORGANIZATION_OWNER` grants or revokes organization-level roles (`ORGANIZATION_OWNER`, `PLATFORM_ADMIN`, or any role with `project_id = NULL`).
- Nobody can grant a role to themselves. The last `ORGANIZATION_OWNER` cannot be removed.
- Owner and Platform Admin deliberately hold no `approval:decide:*` permission (06 §3: admins don't automatically gain approval authority). They must be granted the specific role.
- Workflow and approval permissions are declared now so the map is complete; their endpoints arrive in E04/E08.

## Stories (in order)

---

### E02-01 — Enterprise SSO *(plan-first)*

**Build**
- `libs/infrastructure/identity`: `TokenVerifier` port + jose implementation (D-006): remote JWKS with caching and key-rotation refresh, issuer/audience/algorithm allowlist from config, clock skew ≤ 60 s.
- `UserProvisioning` use case: on first valid token, upsert `users` by `(iss, sub)`, update `email`, `display_name`, `last_login_at`; write a platform-scope audit event `user.provisioned` the first time.
- Global `AuthGuard` in `api/platform`: every route requires a valid bearer token unless marked `@Public()` (only health and OpenAPI). Disabled users get `403 USER_DISABLED`.
- `GET /api/v1/me` → user profile + memberships grouped by organization (uses `withUserContext`).
- Test support in `testing/test-utilities`: an in-process JWKS + token minter so integration tests don't need Keycloak. Never compiled into the app.
- Portal: angular-auth-oidc-client with PKCE against Keycloak; HTTP interceptor attaching the token to API calls only (never to third-party origins); 401 → re-authenticate; logout clears tokens and ends the IdP session.

**Acceptance criteria** (spec + concrete)
- OIDC integration uses the configured IdP; switching IdP is configuration only (prove by pointing tests at the test minter's issuer).
- User identity is mapped to an internal `users` record keyed by issuer + subject.
- Unauthenticated requests get `401 UNAUTHENTICATED`; wrong audience, wrong issuer, `alg: none`, bad signature and expired tokens are each rejected (one test per case).
- Token expiry is enforced by the API; the portal recovers by re-authenticating.

---

### E02-02 — Organization/project RBAC

**Build**
- `libs/domain/access`: `Role`, `Permission` unions, the matrix above as data, `evaluate(memberships, {organizationId, projectId?}, permission): Decision` with a reason. Pure; 100 % branch coverage.
- Tenant resolution (D-007): org-scoped routes read `X-Organization-Id`; project-scoped routes resolve org from the project id via a lookup that runs under `withUserContext`. Unknown or unauthorized resource → `404 NOT_FOUND` (don't reveal existence across tenants).
- `PermissionGuard` + `@RequirePermission()` (D-008), then the handler runs inside `withTenantContext` provided by an interceptor so services receive a tenant-bound transaction.
- **Route audit test**: boots the Nest app, enumerates every route, fails if any lacks `@RequirePermission` or `@Public`.
- Membership endpoints (org-scoped): `GET /members`, `POST /members` `{userEmail | userId, role, projectId?}`, `DELETE /members/{membershipId}`. Grants/revocations write `membership.role.granted` / `membership.role.revoked` audit events in the same transaction.
- Bootstrap CLI (`tools` target `bootstrap-org`, runs as `factory_migrator`): creates an organization and grants `ORGANIZATION_OWNER` to an existing user by issuer + subject. This is the only way to create an organization in v1. Audited as a platform event.
- Portal: organization switcher (from `/me`), members page with grant/revoke dialogs that only offer roles the caller may grant.

**Acceptance criteria** (spec + concrete)
- Organization and project roles are supported, with permissions as in the matrix.
- Cross-tenant access tests fail closed: with alice (org A owner) and bob (org B owner), every org- and project-scoped endpoint is called with the other tenant's ids and headers and returns 404 or 403 — never data. Run as a parameterised test over the route list.
- Role changes are audited, including denied attempts (`outcome = DENIED`).
- Agent identities cannot receive human approval roles: structurally guaranteed (memberships reference `users` only) and covered by a test asserting there is no API or service path that creates a membership for a non-user principal.
- Self-grant, granting org-level roles as Project Admin, and removing the last owner are each rejected with a specific error code.

---

### E02-03 — Project onboarding

**Build**
- Contracts: `ProjectConfig` Zod schema (v1) matching `project-configs/example-project.yaml` — stack, commands, branch conventions, allowed agent pins, data classification default. `projects.config` is validated against it on every write and on read.
- Endpoints:
  - `POST /projects`, `GET /projects`, `GET /projects/{projectId}`, `PATCH /projects/{projectId}` (requires `If-Match` with `config_version`; increments it), `POST /projects/{projectId}/archive`.
  - `POST /projects/{projectId}/repositories` `{provider, fullName, defaultBranch, credentialSecretRef}`, `GET …/repositories`, `POST …/repositories/{repositoryId}/validate`.
  - `GET /policy-bundles` (catalog visible to the org), `PUT /projects/{projectId}/policy-bindings/{environment}` `{policyBundleId}`.
  - `@Idempotent()` on every POST.
- `libs/infrastructure/secrets`: `SecretResolver` (D-009) with `env://` and `vault://` providers. The API stores and returns references only; resolution happens only inside the validation use case.
- `libs/adapters/github`: `RepositoryAccessValidator` using a GitHub App (secret ref resolves to `{appId, installationId, privateKey}`); in `LOCAL` it may also accept a fine-grained token via `env://`. Validation fetches the repo, records `external_repo_id`, confirms the default branch exists, sets `status = ACTIVE` and `access_validated_at`, or `ACCESS_FAILED` with a reason (no secret material in the reason).
- Policy bundles: `tools` target `policies:sync` (runs as `factory_migrator`) loads `policies/<key>/<version>.yaml`, resolves `extends` (deep merge onto the named version of the same bundle), validates the resolved document against a `PolicyBundle` Zod schema, computes the content hash over canonical JSON of the resolved document, inserts it as a platform bundle and marks it `ACTIVE`. Re-running with unchanged content is a no-op; changed content under an existing version fails.
- Binding enforces `environmentsAllowed` when present: `enterprise-default@2026.1-dev` can only be bound to `LOCAL` or `DEV`. Invariants checked at sync time and rejected if violated: `tools.denyAgentMerge`, `tools.denyAgentProductionDeploy` and `tools.denyByDefault` are true; `approvals.allowTimeoutAutoApproval` is false; `tools.maxRiskTierForAgents` is not `T3`.
- New projects get `enterprise-default@2026.1-dev` bound for `LOCAL` and `DEV` automatically. `STAGING` and `PRODUCTION` stay unbound until an admin binds them, and workflows (E04) refuse to start in an environment with no binding.
- Audit: `project.created`, `project.updated`, `project.archived`, `repository.registered`, `repository.validated`, `repository.validation_failed`, `policy.bound`.
- Portal: projects list; onboarding wizard (details → repository → stack config, with "import from YAML" → policy binding → review) using typed reactive forms and the shared Zod schema for client-side validation; project settings page.

**Acceptance criteria** (spec + concrete)
- An admin can register a project, repository and stack configuration through the portal.
- Credentials are stored as secret references only: the API rejects anything that isn't a reference, and a test greps API responses, logs and audit metadata for the resolved secret value.
- The project policy bundle is assigned; binding a bundle owned by another organization or one that isn't `ACTIVE` is rejected.
- Onboarding validates repository access and surfaces failure reasons in the wizard.
- Concurrent `PATCH` with a stale `If-Match` gets `412 PRECONDITION_FAILED`.

## Out of scope
Workflow and approval endpoints (E04, E08), MCP gateway (E05), Vault production hardening and
cloud secret providers (E12), SCIM/user provisioning from the IdP (not in v1).

## Verification before closing the epic
- Fresh stack → `bootstrap-org` for alice → alice logs into the portal, onboards a project
  pointing at a real test repository, validates it, binds policy, grants bob `VIEWER` on the project.
- Bob logs in: sees only that project, cannot edit it, cannot see org members.
- Cross-tenant and route-audit suites pass in CI.
