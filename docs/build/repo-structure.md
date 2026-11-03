# Repository Structure and Nx Boundaries

Follows spec section 09 with three additions: `db/` (SQL migrations and DB tests),
`libs/domain/access` (role → permission map), and `tools/` as an Nx project for repo tooling.
Libraries are created when the epic that needs them starts — the briefs say which.

## Layout

```text
enterprise-ai-sdlc/
├── apps/
│   ├── factory-portal/            # Angular shell: routing, auth bootstrap, layout only
│   ├── factory-portal-e2e/        # Playwright
│   ├── factory-api/               # NestJS: HTTP, guards, composition root
│   ├── workflow-worker/           # Temporal workers (E04)
│   ├── integration-worker/        # Webhooks, outbox relay (E05)
│   ├── telemetry-worker/          # Read-only trace adapters (E11)
│   └── evaluation-worker/         # Agent evaluation jobs (E13)
├── libs/
│   ├── shared/
│   │   ├── contracts/             # Zod schemas crossing process boundaries (versioned)
│   │   ├── types/                 # Branded ids, enums shared by everything
│   │   └── utilities/             # Pure helpers (hashing, canonical JSON, semver)
│   ├── domain/
│   │   ├── access/                # Roles, permissions, role→permission map, evaluation
│   │   ├── organizations/
│   │   ├── projects/
│   │   ├── agents/
│   │   ├── policies/
│   │   ├── audit/
│   │   └── …                      # workflows, tasks, approvals, artifacts, evaluations (later epics)
│   ├── application/
│   │   ├── project-onboarding/
│   │   ├── agent-registry/
│   │   └── …                      # workflow-use-cases, approval-use-cases, agent-dispatch
│   ├── infrastructure/
│   │   ├── postgres/              # Kysely db, withTenantContext, repositories, generated types
│   │   ├── identity/              # OIDC token verification (jose), user provisioning
│   │   ├── secrets/               # SecretResolver providers
│   │   ├── temporal/              # (E04)
│   │   └── object-storage/        # (E04)
│   ├── adapters/
│   │   ├── github/                # Repository access validation (E02), branches/PRs (E05+)
│   │   └── …                      # claude-code, github-copilot, mcp-client, jira, github-actions, native-traces
│   ├── api/
│   │   └── platform/              # Nest modules shared by api apps: errors, correlation, auth guard, idempotency
│   ├── ui/
│   │   ├── design-system/
│   │   ├── shell/                 # Auth, org switcher, layout
│   │   ├── projects/              # Project list, onboarding wizard
│   │   ├── agent-registry/
│   │   └── …                      # workflow-viewer, approval-inbox, analytics
│   └── testing/
│       ├── fixtures/
│       ├── contract-testing/
│       └── test-utilities/        # Testcontainers setup, token minting for tests
├── agents/
│   ├── manifests/                 # One YAML per agent version line
│   ├── prompts/
│   ├── skills/                    # (E06)
│   ├── tool-profiles.yaml
│   └── model-profiles.yaml
├── policies/                      # Policy bundles: policies/<bundle-key>/<version>.yaml
├── project-configs/               # Example onboarding configs
├── schemas/                       # GENERATED JSON Schema + OpenAPI. Do not hand-edit.
├── db/
│   ├── migrations/
│   └── tests/
├── tools/                         # Nx project: agents-sync, schema export, route audit
├── infra/
│   ├── docker-compose.yml
│   ├── containers/
│   ├── deployment/helm/
│   └── terraform/                 # (E14)
└── docs/
    ├── spec/
    ├── build/
    └── adr/
```

## Tags

Every project gets exactly one `scope:*` and one `type:*` tag, plus `domain:*` where it applies.

| Tag | Meaning |
|---|---|
| `scope:portal` | Browser code |
| `scope:api` | `factory-api` app only |
| `scope:worker` | Worker apps only |
| `scope:server` | Server-side libs used by api and workers (domain, application, infrastructure, adapters, api/platform) |
| `scope:shared` | Usable everywhere, including the browser: contracts, types, utilities |
| `scope:tools` | Repo tooling |
| `type:app` | Applications |
| `type:feature` | Portal feature libs (`libs/ui/*` except design-system) |
| `type:ui` | Presentational libs (`design-system`) |
| `type:domain` | Pure domain logic and port interfaces |
| `type:application` | Use cases orchestrating domain + ports |
| `type:infrastructure` | Adapters for platform infrastructure (db, identity, secrets, temporal) |
| `type:adapter` | Adapters for external engineering systems (GitHub, Jira, Claude Code…) |
| `type:api` | Shared NestJS plumbing |
| `type:contract` | Zod contracts |
| `type:util` | Pure utilities and shared types |
| `type:testing` | Test-only helpers |

## Boundary rules (`eslint.config.mjs`)

```js
'@nx/enforce-module-boundaries': ['error', {
  enforceBuildableLibDependency: true,
  allow: [],
  depConstraints: [
    // scope
    { sourceTag: 'scope:portal', onlyDependOnLibsWithTags: ['scope:portal', 'scope:shared'] },
    { sourceTag: 'scope:api',    onlyDependOnLibsWithTags: ['scope:api', 'scope:server', 'scope:shared'] },
    { sourceTag: 'scope:worker', onlyDependOnLibsWithTags: ['scope:worker', 'scope:server', 'scope:shared'] },
    { sourceTag: 'scope:server', onlyDependOnLibsWithTags: ['scope:server', 'scope:shared'] },
    { sourceTag: 'scope:shared', onlyDependOnLibsWithTags: ['scope:shared'] },
    { sourceTag: 'scope:tools',  onlyDependOnLibsWithTags: ['scope:server', 'scope:shared'] },
    // type
    { sourceTag: 'type:app',            onlyDependOnLibsWithTags: ['type:feature','type:ui','type:application','type:domain','type:infrastructure','type:adapter','type:api','type:contract','type:util'] },
    { sourceTag: 'type:feature',        onlyDependOnLibsWithTags: ['type:feature','type:ui','type:contract','type:util'] },
    { sourceTag: 'type:ui',             onlyDependOnLibsWithTags: ['type:ui','type:util'] },
    { sourceTag: 'type:api',            onlyDependOnLibsWithTags: ['type:application','type:domain','type:infrastructure','type:contract','type:util'] },
    { sourceTag: 'type:application',    onlyDependOnLibsWithTags: ['type:domain','type:contract','type:util'] },
    { sourceTag: 'type:domain',         onlyDependOnLibsWithTags: ['type:domain','type:contract','type:util'] },
    { sourceTag: 'type:infrastructure', onlyDependOnLibsWithTags: ['type:domain','type:application','type:contract','type:util'] },
    { sourceTag: 'type:adapter',        onlyDependOnLibsWithTags: ['type:domain','type:application','type:contract','type:util'] },
    { sourceTag: 'type:contract',       onlyDependOnLibsWithTags: ['type:contract','type:util'] },
    { sourceTag: 'type:util',           onlyDependOnLibsWithTags: ['type:util'] },
    { sourceTag: 'type:testing',        onlyDependOnLibsWithTags: ['type:domain','type:application','type:infrastructure','type:adapter','type:contract','type:util','type:testing'] },
  ],
}]
```

Consequences worth knowing:

- Domain and application code cannot import infrastructure, so ports are declared in domain/application and implemented in infrastructure/adapters, wired together in the app's composition root.
- Portal code can never import server code, even by accident. Shared shapes go in `scope:shared` contracts.
- Domain libraries talk to each other only through their public `index.ts`. Cross-domain coordination belongs in an application library.

## Import aliases

`@factory/<folder>/<name>`, e.g. `@factory/shared/contracts`, `@factory/domain/access`,
`@factory/infrastructure/postgres`, `@factory/ui/projects`.
