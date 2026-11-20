# Enterprise AI SDLC Factory

A multi-tenant platform that runs specialist AI agents through the software lifecycle
(requirements → architecture → code → tests → PR) with mandatory human approval at risk
boundaries, server-side policy enforcement and a complete audit trail.

Start with [CLAUDE.md](CLAUDE.md) for the working rules, and
[docs/build/](docs/build/) for decisions, repo structure and per-epic briefs. The product
spec is in [docs/spec/](docs/spec/).

## Prerequisites

| Tool    | Version                    | Notes                                                                     |
| ------- | -------------------------- | ------------------------------------------------------------------------- |
| Node.js | 26.13.0 (see `.nvmrc`)     | Active LTS. Use your version manager, e.g. `nvm install` in the repo root |
| pnpm    | 12.14.0 (`packageManager`) | `npm install -g pnpm@12.14.0`. Node 26 no longer bundles corepack         |
| Docker  | Engine with Compose v2     | Runs the local infrastructure                                             |
| Git     |                            |                                                                           |

## Setup

```bash
pnpm install                  # frozen to pnpm-lock.yaml in CI
pnpm infra:up                 # postgres, redis, keycloak, temporal, rustfs; waits until healthy
pnpm nx serve factory-api     # http://localhost:3000/api
pnpm nx serve factory-portal  # http://localhost:4200
```

If a host port is already taken (commonly 5432), override it, e.g.
`POSTGRES_PORT=5433 pnpm infra:up`. See [infra/README.md](infra/README.md).

Copy `.env.example` to `.env` for local configuration. It contains placeholders only; the
local development values are in the table below. `.env` is git-ignored.

## Commands

```bash
pnpm install
pnpm infra:up                 # docker compose: postgres, redis, keycloak, temporal, rustfs
pnpm infra:down               # stop, keep data
pnpm infra:reset              # stop and delete all volumes
pnpm nx serve factory-api
pnpm nx serve factory-portal
pnpm nx affected -t lint,typecheck,test,build
pnpm nx run-many -t lint typecheck test build   # everything
pnpm nx format:check --base=main                # formatting of changed files
pnpm nx graph
```

The database scripts (`db:migrate`, `db:migrate:down`, `db:codegen`, `db:verify`) arrive
with story E01-02 and are listed in CLAUDE.md.

## Local credentials

Local-only development values. They are not secrets and must never be used in any shared
environment. Details and URLs are in [infra/README.md](infra/README.md).

| Account                              | Username              | Password                        |
| ------------------------------------ | --------------------- | ------------------------------- |
| Postgres `factory_migrator` (owner)  | `factory_migrator`    | `local-migrator-password`       |
| Postgres `factory_api` (application) | `factory_api`         | `local-api-password`            |
| Keycloak admin                       | `admin`               | `local-keycloak-admin-password` |
| Portal user (future org owner)       | `alice`               | `local-alice-password`          |
| Portal user (no memberships)         | `bob`                 | `local-bob-password`            |
| S3 (RustFS)                          | `local-s3-access-key` | `local-s3-secret-key`           |

## Workspace layout

Nx integrated monorepo, pnpm. Libraries import each other through `@factory/<folder>/<name>`
aliases. Every project has exactly one `scope:*` and one `type:*` tag, and
`@nx/enforce-module-boundaries` (configured in [eslint.config.mjs](eslint.config.mjs)) rejects
imports that cross a boundary. The rules and the full layout are in
[docs/build/repo-structure.md](docs/build/repo-structure.md). Never disable the rule.

| Project                                                                               | Path                                |
| ------------------------------------------------------------------------------------- | ----------------------------------- |
| `factory-portal` (Angular), `factory-portal-e2e` (Playwright), `factory-api` (NestJS) | `apps/`                             |
| `shared-contracts`, `shared-types`, `shared-utilities`                                | `libs/shared/`                      |
| `api-platform`, `infrastructure-postgres`                                             | `libs/api/`, `libs/infrastructure/` |
| `ui-design-system`, `ui-shell`                                                        | `libs/ui/`                          |
| `testing-test-utilities`                                                              | `libs/testing/`                     |
| `tools` (repo tooling)                                                                | `tools/`                            |

## Toolchain notes

- Dependencies are pinned to exact versions. `pnpm-workspace.yaml` sets `minimumReleaseAge`
  to 14 days so installs refuse packages published more recently, and dependency install
  scripts are denied unless listed in `allowBuilds`.
- Angular 22 requires TypeScript 6.0.x, and `@nx/nest` requires NestJS < 12, so TypeScript
  and NestJS are pinned to 6.0 and 11 until their consumers support newer majors.

## CI

`.github/workflows/ci.yml` runs on pull requests and pushes to `main`: frozen-lockfile install,
format check, `nx affected` lint/typecheck/test/build against the merge-base, database
service container, gitleaks secrets scan, and a report-only `pnpm audit`.
