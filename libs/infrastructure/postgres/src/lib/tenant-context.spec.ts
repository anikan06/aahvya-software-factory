import {
  asOrganizationId,
  asUserId,
  type OrganizationId,
  type UserId,
} from '@factory/shared/types';
import { createDb } from './create-db';
import { withTenantContext, withUserContext } from './tenant-context';

const VALID = '3f2b8c1e-5d4a-4b7e-9a1c-0e6d2f8b7a10';

describe('context ids are re-validated before any database call', () => {
  // Port 1 refuses connections: if validation did not run first, these would fail with ECONNREFUSED instead.
  const db = createDb({
    connectionString: 'postgres://u:p@127.0.0.1:1/factory',
    onPoolError: () => undefined,
  });
  const callback = jest.fn();

  afterAll(async () => {
    await db.destroy();
  });

  it('rejects a forged organizationId', async () => {
    const forged = "x'; drop table users;--" as OrganizationId;
    await expect(
      withTenantContext(
        db,
        { organizationId: forged, userId: asUserId(VALID) },
        callback,
      ),
    ).rejects.toThrow('organizationId must be a UUID');
    expect(callback).not.toHaveBeenCalled();
  });

  it('rejects a forged userId', async () => {
    await expect(
      withTenantContext(
        db,
        { organizationId: asOrganizationId(VALID), userId: 'nope' as UserId },
        callback,
      ),
    ).rejects.toThrow('userId must be a UUID');
    await expect(
      withUserContext(db, { userId: 'nope' as UserId }, callback),
    ).rejects.toThrow('userId must be a UUID');
    expect(callback).not.toHaveBeenCalled();
  });
});
