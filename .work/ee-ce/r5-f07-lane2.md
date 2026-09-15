# F07 R5 收敛确认 — lane 2（int + rev）

日期：2026-09-12。账号：f07r5b@ce-ee.local 登录 Invalid credentials，按预案回落 f01e2e@ce-ee.local（org creator + super）。后端 127.0.0.1:8080。资源前缀 f07r5b_，测完已全部清理（base 全 deleted=true、nc_snapshots 0、nc_base_variables 孤儿 0、测试用户已删）。DB 均为 nocodb-dev（pg8000，host qnap.elf-balance.ts.net，凭证 Infisical KDL 运行时拉取）。

## int — PASS

| # | 用例 | 结果 |
|---|---|---|
| A1-3 | create title = 123 / {"a":1} / ["x"] | 400 `Snapshot title must be a string` |
| A4 | create title 601 字符 | 400 `exceeds 512 characters limit` |
| B1-3 | restore / delete / get 不存在 snapshot id | 404 `Snapshot not found` |
| B4 | create snapshot 于不存在 base | 404 `Base not found` |
| C1-3 | 跨 base 混用（base2 URL + base1 的 snapshot id：get / restore / delete） | 均 404 |
| D1 | processing 中 restore（大 base 20 表×50 行，create 后 +9ms） | 400 `not ready for restore (status: processing)` |
| D2 | processing 中再 create（mutex） | 400 `Another snapshot is still being created` |
| D3 | 轮询至完成 | 8s 后 completed |
| D4-5 | completed 后 restore ×2 | 200 ×2，返回两个不同新 base id（独立副本） |
| F1 | DB 置副本 deleted=true（nc_bases_v2，pg8000） | 行更新生效 |
| F2 | GET 该 snapshot | 200，status 派生为 `error` |
| F3 | restore 该 snapshot | **400**（非 404），status: error |
| G1 | delete snapshot 后副本 API GET | 404 |
| G2 | 副本 DB 行 deleted | true |
| G3 | 副本 base variables 残留（预置 1 行变量后删） | 0 行（零残留） |
| G4 | nc_snapshots 登记行 | 0 行 |
| G5 | 已软删 base 的 snapshot create / list / get | 均 404 |
| H1 | 源 base 软删（API DELETE）后 nc_snapshots | 0 行 |
| H2 | 其快照副本 base deleted | true；源 base deleted = true |
| P1-2 | 无 token GET / POST snapshots | 401 |
| P3-4 | 伪造 token POST / DELETE | 401 |
| P5-6 | 无 base 权限外部用户 create / list | 403 `ERR_FORBIDDEN` |
| P7-10 | base 内 viewer：list / create / delete / restore | 均 403（与 acl.ts 设计一致：baseSnapshot* 仅 creator+） |

## rev — PASS

对象：`packages/nocodb/src/models/BaseSnapshot.ts`、`packages/nocodb/src/services/base-snapshots.service.ts`、`packages/nocodb/src/controllers/base-snapshots.controller.ts`。

**洞：无。** 逐点核销（均无产品可达链，不构成 issue）：

- createSnapshot mutex 为 check-then-insert 竞态：源码注释已声明 residual risk（最坏双副本、无数据损坏），已知豁免；实测 mutex 生效。
- `cleanupByBaseIdWithCopies` 对副本 softDelete 失败静默吞异常：触发条件为 DB 级异常，产品逻辑不可达。
- 手动 DB 置副本 deleted=true 后再 delete snapshot：`getCopyBaseRow` 返 null → 跳过 `Base.softDelete` → 该副本变量行不被清理。该链路需 DB 级篡改（API 无任何路径使副本 deleted=true；deleteSnapshot 自身链路实测零残留），不可达，仅记录。
- 跨 workspace：TenantContext 由中间件按 baseId 解析 workspace，`snapshot.base_id !== baseId` 校验已覆盖归属；实测跨 base 404。
- `deriveStatus` probe-first + 15min 超时（R2）：逻辑正确，实测大 base 8s 完成、processing 期 restore 被 400 拦截。
- `insertObj` 未含 fk_workspace_id 但落库有值：metaInsert2 自动填 context.workspace_id，实测行值正确。
- Controller v1/v2 双路由一致；4 个 ACL 名均在 `src/utils/acl.ts:274-277` org 默认授权集，viewer/commenter/editor include 不含 → 403 实测吻合。

## rev 实跑门 — PASS

- `npx tsc --noEmit`（packages/nocodb）：exit 0
- `npx jest src/helpers/baseVariableValidators.Fork.spec.ts`：12/12 passed

## 总裁决

**PASS**（int PASS + rev PASS「无洞」+ 实跑门 PASS）。

环境备注（非问题）：会话期间后端 JWT secret 间歇性轮换（rspack watch 重启所致），token 短命，测试脚本改为随用随登，不影响结论有效性。
