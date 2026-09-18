// [CE-EE] F09 P2: request-filtering-agent is ESM-only — ts-jest
// (isolatedModules) can't parse it via the columns.service import chain.
// Webhook agent behaviour is not exercised by fork specs; serve a stub.
class FilteringAgent {}
module.exports = {
  RequestFilteringHttpAgent: FilteringAgent,
  RequestFilteringHttpsAgent: FilteringAgent,
  useAgent: () => new FilteringAgent(),
}
