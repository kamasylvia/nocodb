# r3-f07-int-b — F07 第 3 轮会审（第 2 路：集成测试 + 代码复审）

账号：f07r3b@ce-ee.local（org-level-viewer）/ f01e2e@ce-ee.local（org-level-creator+super，回落主测）。认证 header 实测须用 `xc-auth`（`xc-token`/`Bearer` 均 401）。

## int（对抗收敛）

1. 非法输入矩阵：**PASS**
   - create title=123（number）→ 400 `Snapshot title must be a string`
   - create title 601 字符 → 400 `Snapshot title exceeds 512 characters limit`
   - restore / delete / GET 不存在 snapshot id → 404 `Snapshot not found`（三者均验）
   - 跨 base 混用（base B 路径访问 base A 的快照）→ 404 `Snapshot not found`
2. 状态机：
   - processing 期 restore（create 后毫秒级紧邻请求）→ 400 `Snapshot is not ready for restore (status: processing)` **PASS**
   - completed 后 restore ×2 → 两个独立新 base（实测共 3 次 restore 均成功、id 互异、title `f07r3b_src (restored)`、GET 200）**PASS**
   - completed 后副本被删 → **FAIL**（见 issue 1）
3. 删快照后清理链：**PASS**
   - 删快照 → 200 true；副本 GET → 404 ERR_BASE_NOT_FOUND；DB nc_bases_v2.deleted=true；快照行从 nc_snapshots 删除；后续 GET/restore 快照 → 404
   - 变量零残留：删前向副本 DB 注入一行 nc_base_variables（F07R3B_RESIDUE），删后查证该行被 Base.softDelete 变量清理链清除，副本变量 0 行
4. 源 base 软删 → nc_snapshots 行清零（R2 钩子回归）：**PASS**（DELETE /api/v2/meta/bases/:id 后 DB 查证 base_id 行数 0，base deleted=true）
5. 权限 401/403 矩阵：**PASS**
   - 无 token create/list → 401 ERR_AUTHENTICATION_REQUIRED
   - org-level-viewer 对 create/list/get/restore/delete 全操作 → 403 ERR_FORBIDDEN

## rev

- BaseSnapshot.ts（src/models/BaseSnapshot.ts）vs Extension.ts 惯例逐项对照：get（cache→metaGet2→set）、list（getList→isNoneList 判定→metaList2→setList）、insert（metaInsert2→先 materialize get→appendToList）、update（metaUpdate→NocoCache.update→get 回读）、delete（metaDelete→deepDel CHILD_TO_PARENT）、deleteByBaseId（metaDelete{base_id}→deepDel PARENT_TO_CHILD）形态全部一致。nc_snapshots 无 deleted 列（information_schema 实证 10 列），无 includeDeleted 过滤需求，硬删语义自洽。CacheScope.SNAPSHOT 已注册（globals.ts:568）。
- controller：4 个 ACL op（baseSnapshotList/Create/Restore/Delete）全注册于 src/utils/acl.ts:274-277（与 baseVariable 同组 = creator+），viewer 403 实测印证生效；v1+v2 路由全仓 grep 唯一注册于 base-snapshots.controller.ts，无冲突；noco.module.ts:236/328 已注册 controller/service。
- rev 实跑门：`npx tsc --noEmit` exit 0；jest baseVariableValidators **12/12 passed**。
- rev 独立新洞：无（restore 路径问题归并 issue 1，不重复计）。

## issues

1. packages/nocodb/src/services/base-snapshots.service.ts:195-201（deriveStatus 终态短路）+ :113-156（restoreSnapshot）：快照注册行进入 completed 后，deriveStatus 永久停止探测副本（snapshot base）存活性。副本 base 事后经正常 API trash 删除（DELETE /api/v2/meta/bases/:id，真实用户路径，实测复现）后：
   - GET 快照仍返回 `status: completed`，不派生 `error`（任务验收要求「GET 派生 error」）；
   - restore 返回 404 `ERR_BASE_NOT_FOUND: Base pvgt6pll9l6o6bn not found`（内部 base id 泄漏、语义错位）而非任务要求的 400。
   - 复合症状（同根因）：副本仅 DB 级软删（deleted=true，绕 API 注入）时，Base.get 3 天缓存 TTL（NC_REDIS_TTL 默认 3d，redisHelpers.ts:7）内命中陈旧缓存，restore 甚至能成功复制出一个已删除 base（实测产出 p0tym3jn96okeqz）。
   建议：restoreSnapshot 在 duplicateBase 前显式 Base.get 副本校验存在性，缺失时 NcError.badRequest（如 `Snapshot copy is missing, snapshot is not restorable`）；deriveStatus 对 completed 状态同样探测副本存在性（Base.get 返回 null → 'error'）。

## 资源清理

f07r3b_ 前缀资源全部清除：6 个测试 base（probe + 5 个 restored 产物）API trash 删除均 200；DB 复核 live base / nc_snapshots(base_id=p2hyywbqdwhv05x) / nc_base_variables 残留均为 0 行。/tmp 凭证与脚本已删。
