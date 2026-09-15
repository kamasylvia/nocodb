# r7-f07-lane3 — 第 3 路（int 抽验 + rev 后端终审）

## 裁决

- **int（集成抽验）：PASS**
- **rev（后端终审）：1 issue（低危，优雅降级，非 error 级）**
- **总裁决：0 error；1 个低危功能缺口 issue，见下。是否计入本轮 0-error 由 orchestrator 裁定。**

## issues

1. `packages/nocodb/src/services/base-snapshots.service.ts:60-73`（createSnapshot）/ `:166-180`（restoreSnapshot）:
   **问题**：标题过长的 base（title 约 >118 字符）无法创建快照；>139 字符的 base 无法恢复。
   原因：副本 base 标题由 `duplicateBase` 经 `basesService.baseCreate` 落地，走 swagger `ProjectReq.title` maxLength=150 校验；快照副本标题为 `Snapshot <ts> of <base.title>`（实测该值覆盖 `generateUniqueName` 的 `... copy` 后缀，见 duplicate.service.ts:111-123 的 `...(body.base || {})` 展开顺序），故源标题上限 ≈ 150-32=118；restore 标题 `<orig> (restored)` 上限 ≈ 139。
   **实测**：120 字符标题 base → `POST /snapshots` → 400 `Validation failed: 'title' must be at most 150 characters`（graceful，无副本残留、无 500）。
   **建议**：create/restore 前预检 `title` 长度并给出指向性错误（如"Base title too long to snapshot (max 118)"）；或截断副本标题。属功能缺口（EE 对任意合法标题均可快照），非崩溃/数据/安全问题。
   **严重度**：低。

除上项外攻击性找茬**无**其它有 API 可达链的问题。以下非 error 的观察（不构成 issue）：
- createSnapshot 在 `duplicateBase` 成功后、`BaseSnapshot.insert` 前崩溃会留孤儿副本 base（status='job' 无 registry 行）——窄崩溃窗口，与 R1 已记录的 mutex check-then-insert 残留风险同类。
- 副本标题同秒可撞（`generateUniqueName` 被 body.base.title 覆盖失效）——纯外观。
- listSnapshots 每行一次 cache-free metaGet2 探测（N+1）——典型 N<10，无感。
- 无 token 访问不存在的 baseId 返回 404（真实 baseId 返回 401）——上游 CE extract-ids 先于鉴权解析 base 的统一行为，非 fork 引入。

## int 集成抽验记录（全部实测通过）

环境：dev server :8080（main.js 01:03 构建 > 最晚源码 23:50，运行代码 = 当前工作树）；新测用户 `lane3r7_33888@example.com`（signup 后 DB 补 default workspace owner，与其它 lane 数据隔离）；pg8000 直查 `nocodb-dev`（严禁生产库，已验证 `current_database()=nocodb-dev`）。

1. **全生命周期 1 轮**：
   - 建 base `phojcisnq2nlld8` → `POST /snapshots` → `snapqhoegasj9e1104`（processing，副本 `p3rry5dvw6pst5g`）→ list 3s 内派生 completed → GET 单个 completed。
   - restore → 新 base `p1n85v2d64s0dh0`，标题 `Lane3F07Src (restored)`，工作 base 未动。
   - title 校验：`{"title":123}` → 400；600 字符 → 400。
   - `DELETE snapshot` → 200，list=[]，DB 副本 `deleted=true`。
   - **副本被清路径**（R3/R4 核心场景）：直删副本 base → GET 派生 `error` → restore 400 `Snapshot is not ready for restore (status: error)`。
   - `DELETE /bases/:id`（删源）→ 200。
2. **删源 base 清理 DB 核验（pg8000）**：`nc_snapshots` 中该源 base 行 = 0；两条 snapshot id 均无残留；两个副本 base `deleted=true`；源 base `deleted=true`。✓ `cleanupByBaseIdWithCopies` 生效。
3. **R4 统一自愈实测**：DB 强制把已 completed 的快照行改回 `error`（模拟重启竞态误标，副本实际 live+completed）→ GET 派生回 `completed`（终态也重推导，持久层误标被纠正）。
4. **权限负路径**：workspace editor 用户 create/list/delete snapshot 全 403；无 token 对真实 baseId 401。creator+/editor- 与代码 ACL 推导（exclude 型 creator/owner 放行、include 型 editor 不可达）一致。
5. **全局一致性**：全库 `nc_snapshots` 左连副本 base 无 dangling 行（5 行全有实体）；本轮我方 base/snapshot id 在 backend.log 中 0 error 行（log 内 4 条 JOB FAILED 均为并发其它 lane/更早活动，ids 非本轮）。库中存留 1 个无 registry 引用的 live `Snapshot %` 副本（`pk6o9kpj4xh17ks`，约 22:51 创建，早于本轮，属更早轮次/它路测试残留，无法归因当前代码——本轮实测两条删除路径均无孤儿）及 2 条 stale `processing` 行（源、副本均 live，按设计读时自愈）。

## rev 后端终审记录

- **R4 六项逐一核过**：
  1. unified deriveStatus（service:220-252）：list/get/restore 全走单点重推导；restore 的 `?? snapshot.status` fallback 仅在（copyRow 缺失 且 已标 error）时兜底为 error → 400，正确。**实测自愈通过**。
  2. `getCopyBaseRow` RootScopes.WORKSPACE（service:258-273）：对照 meta.service.ts:266-290 contextCondition——`fk_workspace_id = ws` 且 base_id===WORKSPACE 时不追加 base 条件，PROJECT 表走 `id = snapshotBaseId`，`deleted===true` 视为 null。修复正确。
  3. `ensureCopyExists`（service:121-136）：restore 前探，缺失即标 error + 400，不泄露内部 id。实测 purge 后 restore 400。
  4. `cleanupByBaseIdWithCopies`（BaseSnapshot.ts:182-208）：接线于 Base.softDelete 与 Base.delete 两处（diff 核实）；逐副本 try/catch + 动态 import 防循环依赖；递归链有界（副本的 registry 行通常为空）。实测删源清理生效。
  5. 删快照守卫（service:185-218）：副本在→softDelete，不在→跳过，行总是删，无 500。实测副本被清后删行 200。
  6. title 校验（service:34-39）：非字符串/512 上限 → 400，实测通过；DB 列恰 512，一致。
- **service/model 全文再扫**：cache 物化顺序（insert R1 修复）、list 缓存 key 与 deepDel 方向匹配、`getSnapshotWithBaseCheck` base_id 双重校验（metaGet2 上下文条件 + 显式比较）防跨 base 读取、`deleteByBaseId` DB 条件删除不依赖缓存、restore 自构造 context 与 duplicateBase 的 Base.get 兼容——未发现新问题。
- **ACL 面**：`baseSnapshot*` 注册于 `permissionScopes.base`（utils/acl.ts:274-277）；ProjectRoles.CREATOR/OWNER（exclude 型默认放行）、WorkspaceUserRoles.OWNER（exclude {}）可达；editor/commenter/viewer（include 型）不可达。与 F05 同款模式，实测 editor 403 佐证。op-names.ts 未注册 snapshot op——op-names 属 command-registry，与 ACL 无关，非缺口。
- **构建与测试**：`npx tsc --noEmit` = 0 错误；`npx jest baseVariableValidators --runInBand --forceExit` = 12/12 通过。
- **附带 diff**：dataHelpers.ts（base undefined → 404，NcError 已 import，tsc 过）；uniqueConstraintErrorHandler.ts（F01 贪婪捕获 ×3 处）——正确无害。
