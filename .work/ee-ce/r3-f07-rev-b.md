# r3-f07-rev-b — F07 前端第 3 轮收敛确认（第 4 路：int + rev）

审查对象：`packages/nc-gui/components/dashboard/settings/base/Snapshots.vue`（R2 修复后：轮询按 id 定点 24×2.5s、/nc/ 跳转、菜单门收敛）
环境：前端 :3000 / 后端 :8080（nocodb-dev）/ camoufox-cli UI 实测 / 独立账号 f07r4ui@iso.local（本轮因共享账号互踢自建，DB 提权 super，后续轮可复用）

## rev（代码复审）

vitest：`npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → **10/10 passed**（2 files）。

Snapshots.vue 逐项：
- 轮询（L40-53）：按 newId 定点 GET `/snapshots/{newId}`，24×2.5s=60s 封顶，completed/error break；findIndex 原位替换/头部插入；外层 catch 兜底 ✓（UI 实测创建后行状态收敛为 COMPLETED）
- 跳转（L68-72）：restore 拿 base_id → `navigateTo('/nc/{id}')`，实测跳转可达且页面正常渲染（见 int-O1）
- 门：组件无内嵌 gate；挂载点 components/project/View.vue（`!blockSnapshots && isUIAllowed('baseSnapshotList')`），useEeConfig.ts:427 `blockSnapshots = computed(() => false)` ✓；settings 侧栏「Manage Snapshots」菜单可见可用、无 upgrade 弹窗（UI 实测）
- i18n：en.json 全 key 在位（baseSnapshotsSubtitle/Empty/Create、baseSnapshotDeleteTitle/Description、baseSnapshotsRestoreHint L5797-5802；baseSnapshotCreated/Restored/Deleted L6163-6165；labels.manageSnapshots L2739；general.restore L647）；zh-Hans baseSnapshot 相关 10 条在位 ✓
- 类型/标记/杂项：SnapshotType from nocodb-sdk ✓；`// [CE-EE]` 标记 L2/L33/L70 ✓；statusColor 三态 ✓；isCreating loading 防重复提交 ✓；created_at 解析实测正常 ✓；deleteSnapshot Modal 确认流（代码审查 OK，未列必测）

rev 结论：**Snapshots.vue 无 error**。

## int（UI 浏览器实测）

链路（camoufox-cli 独立 session，UI 表单登录 → 纯点击/SPA 导航）：
1. API 建 base `pzjft5krvr6ha68`（f07r4ui_snapiso，含 Table1）→ UI 打开
2. Settings → 侧栏 Manage Snapshots 菜单可见 → Snapshots.vue 面板完整渲染（标题/空态/hint/New Snapshot 按钮）
3. UI 点 New Snapshot → 行出现 `Snapshot 2026-09-12T14-20-17 | COMPLETED`（按 id 轮询收敛实测 ✓）
4. UI 点 Restore → 跳转 `/nc/{restoredBaseId}` → 新 base「F07r4ui_snapiso (restored)」渲染 ✓

### issues

- **int-E1（error）restore 产物间歇性静默丢表**
  - 位置：`packages/nocodb/src/services/base-snapshots.service.ts:167-181`（restoreSnapshot → duplicateService.duplicateBase）及 DuplicateBase job 数据复制链路；前端无从感知
  - 问题：同一快照 restore 两次——第 1 次产物 `pna1db52igeyobp` tables=[]（API GET 确认，UI 显示 No tables），而快照副本 base `pbfu1slbim4zz5k` 有 Table1；第 2 次产物 `pkf0bpkzqjera6r` 有 Table1（正常）。两次 restore HTTP 均 200、UI 均提示成功并跳转——**产物不完整时无任何失败信号**。后端日志同期存在 `!! JOB FAILED !!`（TypeError: Cannot read properties of undefined (reading 'id')，`src/helpers/dataHelpers.ts:50` ← `export.service.ts:920 streamModelDataAsCsv`）。非确定性（1/2 复现）。混淆因素：第 1 次 restore 处于共享账号 token_version 互踢的 401 噪音窗口内，不排除 job 内用户上下文受损；但「产物丢表 + 200 成功提示」矛盾本身即缺陷
  - 建议：① 复盘 DuplicateBase job 对 snapshot copy base 的数据导出失败路径（dataHelpers.ts:50 空 model 防御 + job 失败时向 restore 调用方传播失败状态）；② restore 产物落库后校验表数量与副本一致，不一致将 restore 置 error 并让 UI 可见；③ 修复后用独立账号在无 401 噪音窗口复测 ≥2 次

- int-O1（观察）`Snapshots.vue:71` 硬编码 `navigateTo('/nc/' + restoredBaseId)`，与本站常规路由 `/{workspaceId}/{baseId}` 不一致。实测 `/nc/{id}` 前缀路由可达、页面正常（兼容行为），非 error；建议后续改用 `useGlobal()` 的 navigateToProject 对齐
- int-O2（观察）创建轮询 60s 封顶后不再自动收敛，行停留 processing 需手动刷新才见终态。当前副本 job 实测 <60s 完成，风险低
- int-O3（环境/基础设施，非 F07 范畴，报裁决者）本轮 UI 实测被两类环境问题反复干扰：
  - 多路会审共用 f01e2e 账号 + fork「单会话强制」（users.service.ts:751 每次 signin rotate token_version）→ jwt.strategy.ts:39 大量 "Token Expired" 401、各路互相踢下线；建议每路子代理用独立账号（本轮已自建 f07r4ui@iso.local 可复用）
  - `nc-shared-execution-refreshToken-result` 残留 `{"status":"success","result":null}` 会短路后续 refreshToken（actions.ts `_refreshToken` 静默 return null 被 useSharedExecutionFn 缓存为 success）；另 `composables/useApi/interceptors.ts:76` 传 `skipLogout: true` 但 `_refreshToken` 形参名为 `skipSignOut`，参数不匹配该开关无效。均与 F07 无关，仅登记
  - 本轮后端一度遭 rspack 反复 "Restarting app..." 致 :8080 失联数分钟，已用 dev-backend.sh 重启恢复

### 清理

已删：快照行 snap6xp3bccmtrl2rr（连带副本 base softDelete，二次 DELETE 返 404 即已随钩子清除）、pzjft5krvr6ha68、pna1db52igeyobp、pkf0bpkzqjera6r、pzvdpccqaik5nvo（f07r4ui_snapbase）。剩余 f07r4ui 相关 base：无。浏览器 session f07r4ui 已保留 tab（登录态为 iso 账号）。

## 裁决

- int：1 error（int-E1 restore 间歇丢表，实测定锤，附日志栈）
- rev：PASS（Snapshots.vue 前端无 error；vitest 10/10）
- **总裁决：error（int-E1 计入；需修 F07 restore 数据完整性链路后开新一轮）**
