# Local infrastructure

Docker Compose stack for local development (D-015). Requires Docker with Compose v2.

```bash
pnpm infra:up      # start everything and wait until every service is healthy
pnpm infra:down    # stop, keep data
pnpm infra:reset   # stop and delete all volumes (clean slate; re-runs DB init and realm import)
```

**All credentials below are local-only development values. They are not secrets and must
never be used in any shared environment.** Ports bind to `127.0.0.1` only. If a port is
taken, override it, e.g. `POSTGRES_PORT=5433 pnpm infra:up` (variables: `POSTGRES_PORT`,
`REDIS_PORT`, `KEYCLOAK_PORT`, `TEMPORAL_PORT`, `TEMPORAL_UI_PORT`, `S3_PORT`,
`S3_CONSOLE_PORT`), and adjust your `.env` to match.

| Service | URL / port | Notes |
|---|---|---|
| PostgreSQL 16 | `localhost:5432` | database `factory` |
| Redis 7 | `localhost:6379` | |
| Keycloak 26 | http://localhost:8080 | realm `factory`; admin console at `/admin` |
| Temporal | `localhost:7233` (gRPC) | dev server, unused until E04 |
| Temporal UI | http://localhost:8233 | |
| S3 API | http://localhost:9000 | bucket `factory-artifacts`, created on start |
| S3 console | http://localhost:9001 | |

The S3-compatible store is RustFS: MinIO no longer publishes community container images.
The S3 API is what the platform depends on, so the choice is local-only.

## Local credentials

| Account | Username | Password |
|---|---|---|
| Postgres `factory_migrator` (owner, migrations) | `factory_migrator` | `local-migrator-password` |
| Postgres `factory_api` (application, subject to RLS) | `factory_api` | `local-api-password` |
| Postgres superuser (container bootstrap only) | `postgres` | `local-postgres-superuser-password` |
| Keycloak admin | `admin` | `local-keycloak-admin-password` |
| Portal user (will become org owner) | `alice` | `local-alice-password` |
| Portal user (no memberships) | `bob` | `local-bob-password` |
| S3 | `local-s3-access-key` | `local-s3-secret-key` |

The two Postgres role passwords come from `infra/containers/postgres/init/01-roles.sql`.

## Keycloak realm

`infra/containers/keycloak/factory-realm.json` is imported on first start (use
`infra:reset` after editing it). It defines the public client `factory-portal`
(Authorization Code + PKCE S256, redirect `http://localhost:4200/*`, direct grants off)
with an audience mapper so access tokens carry `aud: factory-api`.

## Quick checks

```bash
docker exec -e PGPASSWORD=local-api-password factory-postgres \
  psql -h 127.0.0.1 -U factory_api -d factory -c 'select current_user'
curl -s http://localhost:8080/realms/factory/.well-known/openid-configuration | jq .issuer
```
