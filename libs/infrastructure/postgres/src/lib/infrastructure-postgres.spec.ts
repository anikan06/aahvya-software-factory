import { infrastructurePostgres } from './infrastructure-postgres';

describe('infrastructurePostgres', () => {
  it('should work', () => {
    expect(infrastructurePostgres()).toEqual('infrastructure-postgres');
  });
});
