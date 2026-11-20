import { sql, type Transaction } from 'kysely';
import {
  isUuid,
  type OrganizationId,
  type UserId,
} from '@factory/shared/types';
import type { DB } from '../generated/db';
import type { Db } from './create-db';

/** Transaction handle handed to repositories. Repositories never open their own connection (D-004). */
export type Tx = Transaction<DB>;

export interface TenantContext {
  readonly organizationId: OrganizationId;
  readonly userId: UserId;
}

export interface UserContext {
  readonly userId: UserId;
}

/**
 * Runs `fn` in one transaction with `app.current_org_id` / `app.current_user_id` set for
 * row-level security (D-004). `set_config(..., true)` is transaction-local, so the settings cannot
 * leak to the next request that reuses the pooled connection.
 *
 * The ids must come from the authenticated identity and validated ownership, never from a request body.
 */
export async function withTenantContext<T>(
  db: Db,
  context: TenantContext,
  fn: (trx: Tx) => Promise<T>,
): Promise<T> {
  assertUuid('organizationId', context.organizationId);
  assertUuid('userId', context.userId);
  return db.transaction().execute(async (trx) => {
    await sql`select set_config('app.current_org_id', ${context.organizationId}, true),
                     set_config('app.current_user_id', ${context.userId}, true)`.execute(
      trx,
    );
    return fn(trx);
  });
}

/**
 * For lookups that happen before an organization is chosen, e.g. "which organizations does the
 * caller belong to". Only `app.current_user_id` is set, so tenant tables stay invisible; the RLS
 * policies expose just the caller's own membership rows (and the organizations they lead to).
 */
export async function withUserContext<T>(
  db: Db,
  context: UserContext,
  fn: (trx: Tx) => Promise<T>,
): Promise<T> {
  assertUuid('userId', context.userId);
  return db.transaction().execute(async (trx) => {
    await sql`select set_config('app.current_user_id', ${context.userId}, true)`.execute(
      trx,
    );
    return fn(trx);
  });
}

// Branded types can be forged with a cast; fail closed before anything reaches the database.
function assertUuid(name: string, value: string): void {
  if (!isUuid(value)) {
    throw new TypeError(`${name} must be a UUID`);
  }
}
