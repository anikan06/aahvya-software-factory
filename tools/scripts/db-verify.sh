#!/usr/bin/env bash
# Runs db/tests/schema-guards.sql then db/tests/rls-coverage.sql as the migration (owner) role.
# Uses a local psql when present (CI); otherwise runs psql inside the local factory-postgres
# container over its unix socket (local-only convenience).
set -euo pipefail
cd "$(dirname "$0")/../.."

if command -v psql >/dev/null 2>&1; then
  : "${MIGRATION_DATABASE_URL:?MIGRATION_DATABASE_URL must be set (see .env.example)}"
  for f in db/tests/schema-guards.sql db/tests/rls-coverage.sql; do
    echo "==> $f"
    psql "$MIGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  done
elif docker inspect factory-postgres >/dev/null 2>&1; then
  echo "psql not found; running inside the factory-postgres container (local only)"
  for f in db/tests/schema-guards.sql db/tests/rls-coverage.sql; do
    echo "==> $f"
    docker exec -i factory-postgres psql -U factory_migrator -d factory -v ON_ERROR_STOP=1 < "$f"
  done
else
  echo "error: need psql on PATH, or the local factory-postgres container (pnpm infra:up)" >&2
  exit 1
fi
echo "db:verify passed"
