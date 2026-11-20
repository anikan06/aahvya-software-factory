import { createDb } from './create-db';

const URL = 'postgres://factory_api:unused@127.0.0.1:1/factory';
const noop = (): void => undefined;

describe('createDb', () => {
  it('creates an instance without connecting (pool is lazy)', async () => {
    const db = createDb({ connectionString: URL, onPoolError: noop });
    await db.destroy();
  });

  it('rejects an empty connection string', () => {
    expect(() =>
      createDb({ connectionString: '  ', onPoolError: noop }),
    ).toThrow(TypeError);
  });

  it.each([
    ['poolMax', { poolMax: 0 }],
    ['poolMax', { poolMax: 1.5 }],
    ['statementTimeoutMs', { statementTimeoutMs: -1 }],
    ['idleInTransactionTimeoutMs', { idleInTransactionTimeoutMs: 0 }],
  ])('rejects out-of-range %s', (name, override) => {
    expect(() =>
      createDb({ connectionString: URL, onPoolError: noop, ...override }),
    ).toThrow(new RegExp(name));
  });
});
