// [CE-EE] F09 P2: the integrations core dist is ESM — ts-jest
// (isolatedModules) can't parse it via the columns.service import chain.
// Fork specs don't exercise integrations; serve the named surface as stubs.
module.exports = {
  setExternalDbSsrfEnforcement: () => {},
  getIntegrationEntry: () => undefined,
}
