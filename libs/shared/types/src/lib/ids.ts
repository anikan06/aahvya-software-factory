declare const brand: unique symbol;

/** Nominal typing for string identifiers so an OrganizationId cannot be passed where a UserId is expected. */
export type Brand<T, B extends string> = T & { readonly [brand]: B };

export type OrganizationId = Brand<string, 'OrganizationId'>;
export type UserId = Brand<string, 'UserId'>;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

/**
 * Brands a string as an OrganizationId. Call this only with a value derived from the
 * authenticated identity and validated resource ownership (CLAUDE.md security invariants),
 * never with an id taken from a request body, query string or agent output.
 */
export function asOrganizationId(value: string): OrganizationId {
  if (!isUuid(value)) {
    throw new TypeError('OrganizationId must be a UUID');
  }
  return value as OrganizationId;
}

export function asUserId(value: string): UserId {
  if (!isUuid(value)) {
    throw new TypeError('UserId must be a UUID');
  }
  return value as UserId;
}
