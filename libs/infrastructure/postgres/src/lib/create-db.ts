import { Kysely, PostgresDialect } from 'kysely';
import { Pool } from 'pg';
import type { DB } from '../generated/db';

export type Db = Kysely<DB>;

export interface PostgresConfig {
  /** Connection string for the `factory_api` login role. Never the migration/owner role. */
  readonly connectionString: string;
  /** Maximum pooled connections. Default 10. */
  readonly poolMax?: number;
  /** Per-statement timeout enforced by the server. Default 15 000 ms. */
  readonly statementTimeoutMs?: number;
  /** Server kills sessions idle inside a transaction, so a stuck request cannot pin a connection. Default 30 000 ms. */
  readonly idleInTransactionTimeoutMs?: number;
  /** Shown in pg_stat_activity. Default `factory`. */
  readonly applicationName?: string;
  /**
   * Called when an idle pooled client errors (e.g. the server restarts). Required so the caller
   * routes it to the shared logger; without a listener `pg` would crash the process.
   */
  readonly onPoolError: (error: Error) => void;
}

const DEFAULT_POOL_MAX = 10;
const DEFAULT_STATEMENT_TIMEOUT_MS = 15_000;
const DEFAULT_IDLE_IN_TRANSACTION_TIMEOUT_MS = 30_000;

function requireIntInRange(
  name: string,
  value: number,
  min: number,
  max: number,
): number {
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new RangeError(
      `${name} must be an integer between ${min} and ${max}`,
    );
  }
  return value;
}

/**
 * Creates the Kysely instance over a `pg` pool. Services call this once at startup (composition
 * root) and run every request through `withTenantContext` / `withUserContext`.
 */
export function createDb(config: PostgresConfig): Db {
  if (config.connectionString.trim().length === 0) {
    throw new TypeError('connectionString must not be empty');
  }
  const pool = new Pool({
    connectionString: config.connectionString,
    max: requireIntInRange(
      'poolMax',
      config.poolMax ?? DEFAULT_POOL_MAX,
      1,
      200,
    ),
    statement_timeout: requireIntInRange(
      'statementTimeoutMs',
      config.statementTimeoutMs ?? DEFAULT_STATEMENT_TIMEOUT_MS,
      1,
      600_000,
    ),
    idle_in_transaction_session_timeout: requireIntInRange(
      'idleInTransactionTimeoutMs',
      config.idleInTransactionTimeoutMs ??
        DEFAULT_IDLE_IN_TRANSACTION_TIMEOUT_MS,
      1,
      600_000,
    ),
    application_name: config.applicationName ?? 'factory',
  });
  pool.on('error', config.onPoolError);
  return new Kysely<DB>({ dialect: new PostgresDialect({ pool }) });
}
