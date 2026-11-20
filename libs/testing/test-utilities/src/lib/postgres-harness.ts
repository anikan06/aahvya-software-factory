import { execFile } from 'node:child_process';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { PostgreSqlContainer } from '@testcontainers/postgresql';
import { createDb, type Db } from '@factory/infrastructure/postgres';
import { findWorkspaceRoot } from './workspace-root';

const execFileAsync = promisify(execFile);

// Same pinned image as infra/docker-compose.yml and CI.
const POSTGRES_IMAGE = 'postgres:16.15';
const SUPERUSER_PASSWORD = 'test-only-postgres-superuser-password';
// Passwords are set by infra/containers/postgres/init/01-roles.sql (local/test-only values).
const MIGRATOR_PASSWORD = 'local-migrator-password';
const API_PASSWORD = 'local-api-password';

export interface PostgresHarness {
  /** Connected as `factory_api`: subject to row-level security. Use this for the code under test. */
  readonly db: Db;
  /** Connected as `factory_migrator` (table owner, bypasses RLS). For seeding and assertions only. */
  readonly adminDb: Db;
  /** Errors reported by idle pooled clients; tests can assert it stays empty. */
  readonly poolErrors: readonly Error[];
  stop(): Promise<void>;
}

/**
 * Starts a throwaway PostgreSQL 16, runs the same role bootstrap script as local infra, applies
 * every migration as `factory_migrator`, and hands back connections for both roles.
 * Requires a reachable Docker daemon.
 */
export async function startPostgresHarness(): Promise<PostgresHarness> {
  const root = findWorkspaceRoot();
  const container = await new PostgreSqlContainer(POSTGRES_IMAGE)
    .withUsername('postgres')
    .withPassword(SUPERUSER_PASSWORD)
    .withDatabase('postgres')
    .withCopyFilesToContainer([
      {
        source: join(root, 'infra/containers/postgres/init/01-roles.sql'),
        target: '/docker-entrypoint-initdb.d/01-roles.sql',
      },
    ])
    .start();

  const hostPort = `${container.getHost()}:${container.getMappedPort(5432)}`;
  const migratorUrl = `postgres://factory_migrator:${MIGRATOR_PASSWORD}@${hostPort}/factory`;
  const apiUrl = `postgres://factory_api:${API_PASSWORD}@${hostPort}/factory`;

  try {
    await execFileAsync(
      process.execPath,
      [
        join(root, 'node_modules/node-pg-migrate/bin/node-pg-migrate.js'),
        '-m',
        join(root, 'db/migrations'),
        '-d',
        'HARNESS_MIGRATION_URL',
        '--no-verbose',
        'up',
      ],
      {
        env: { ...process.env, HARNESS_MIGRATION_URL: migratorUrl },
        cwd: root,
      },
    );
  } catch (error) {
    await container.stop();
    throw error;
  }

  const poolErrors: Error[] = [];
  const onPoolError = (error: Error): void => {
    poolErrors.push(error);
  };
  const db = createDb({ connectionString: apiUrl, poolMax: 1, onPoolError });
  const adminDb = createDb({
    connectionString: migratorUrl,
    poolMax: 2,
    onPoolError,
  });

  return {
    db,
    adminDb,
    poolErrors,
    async stop() {
      await Promise.allSettled([db.destroy(), adminDb.destroy()]);
      await container.stop();
    },
  };
}
