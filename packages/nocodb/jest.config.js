// jest.config.js
// In the following statement, replace `./tsconfig` with the path to your `tsconfig` file
// which contains the path mapping (ie the `compilerOptions.paths` option):

module.exports = {
  moduleFileExtensions: ['js', 'json', 'ts', 'tsx', 'jsx', 'node'],
  rootDir: 'src',
  // [CE-EE] add 'Fork' bucket: unit tests owned by this fork (upstream CE has no
  // files matching this regex, CI suites arrive via the ee/ overlay)
  testRegex: '(Integration|Source|Fork)\\.spec\\.ts$',
  collectCoverageFrom: ['**/*.(t|j)s'],
  coverageDirectory: '../coverage',
  testEnvironment: 'node',
  moduleNameMapper: {
    // [CE-EE] F09 P2: nanoid v5 is ESM-only — ts-jest (isolatedModules) can't
    // parse it when a spec's import chain reaches columns.service; serve a
    // deterministic CJS stub instead
    '^nanoid$': '<rootDir>/__mocks__/nanoid.js',
    '^request-filtering-agent$': '<rootDir>/__mocks__/request-filtering-agent.js',
    '^@noco-local-integrations/core$': '<rootDir>/__mocks__/noco-local-integrations-core.js',
    '^src/(.*)$': [
      '<rootDir>/$1',
      // '<rootDir>/$1/index'
    ],
    '^~/(.*)$': [
      '<rootDir>/ee/$1',
      '<rootDir>/$1',
      // '<rootDir>/ee/$1/index',
      // '<rootDir>/$1/index',
    ],
    '^@/(.*)$': ['<rootDir>/ee/$1', '<rootDir>/$1'],
  },
  // [...]
  // moduleNameMapper: pathsToModuleNameMapper(
  //   compilerOptions.paths /*, { prefix: '<rootDir>/' } */,
  // ),
  // modulePaths: [compilerOptions.baseUrl],
  // moduleNameMapper: pathsToModuleNameMapper(compilerOptions.paths, {
  //   prefix: '<rootDir>/../',
  // }),
  transform: {
    '^.+\\.tsx?$': [
      'ts-jest',
      {
        tsconfig: 'tsconfig.json',
        // [CE-EE] transpile-only: the legacy ts-jest language service crashes
        // with TS 5.8 (document registry race); type checking stays with the
        // rspack/tsc pipeline
        isolatedModules: true,
      },
    ],
  },
};
