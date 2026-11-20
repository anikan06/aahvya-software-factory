module.exports = {
  displayName: 'testing-test-utilities',
  preset: '../../../jest.preset.js',
  testEnvironment: 'node',
  // Integration specs start a PostgreSQL container (Docker required).
  testTimeout: 120000,
  transform: {
    '^.+\\.[tj]s$': ['ts-jest', { tsconfig: '<rootDir>/tsconfig.spec.json' }],
  },
  moduleFileExtensions: ['ts', 'js', 'html'],
  coverageDirectory: '../../../coverage/libs/testing/test-utilities',
};
