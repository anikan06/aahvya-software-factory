import { asOrganizationId, asUserId, isUuid } from './ids';

const VALID = '3f2b8c1e-5d4a-4b7e-9a1c-0e6d2f8b7a10';

describe('ids', () => {
  it('accepts UUIDs, case-insensitively', () => {
    expect(isUuid(VALID)).toBe(true);
    expect(isUuid(VALID.toUpperCase())).toBe(true);
  });

  it.each([
    ['empty string', ''],
    ['not a uuid', 'acme'],
    ['sql injection attempt', `${VALID}'; DROP TABLE users;--`],
    ['too short', VALID.slice(0, -1)],
    ['number', 42],
    ['undefined', undefined],
  ])('rejects %s', (_label, value) => {
    expect(isUuid(value)).toBe(false);
  });

  it('brands valid ids and returns the same string', () => {
    expect(asOrganizationId(VALID)).toBe(VALID);
    expect(asUserId(VALID)).toBe(VALID);
  });

  it('throws on invalid ids', () => {
    expect(() => asOrganizationId('nope')).toThrow(TypeError);
    expect(() => asUserId('nope')).toThrow(TypeError);
  });
});
