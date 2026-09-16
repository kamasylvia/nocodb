# F04 R5 lane3 复审报告

issues（1 minor，0 error）

## R5 增量项：R4 修复批 commit 9188e0f1ff 回归（resync syncingId 乐观置位）

### diff 审查
- 单提交 9188e0f1ff，仅 `packages/nc-gui/components/project/Sync/index.vue`（+5/-2）：`syncingId.value = row.id` + `syncStatus` 置位从 `await $api.internal.postOperation(atImportTrigger)` 之后移到之前（L150-151），带 `// [CE-EE]` 标记。与修复方案一致；未触碰 store/sync.ts、后端零改动（git show --stat 确认仅此 1 文件）。
- 失败路径核查：catch（L206-208）清 `syncingId`（锁不泄漏）；watchdog 三路（COMPLETED/FAILED/90s 超时）均 clearInterval + 从 watchdogTimers 移除 + 清锁；onUnmounted 全清（R3 修复沿袭完好）。

### 双击不发第二发 atImportTrigger（实测，决定性证据）
- 方法：camoufox eval 在页面内以 120ms 间隔连点 Resync（shell 双击间隔不可控，弃用），以**服务端 at-import job 计数**为判据（jobs 端点 `POST /api/v2/jobs/:baseId` 返回数组）。job 无真实 Airtable 凭证时秒级 failed → 后端 dedup（UiPost.operations.ts L730-733 只查在跑 job）不可能拦截第二发 → job 增量是纯 UI 层证据。
- 结果：三组双击实验 job 增量**恒为 1**（3→4→5→6）。若锁失效第二击会在 await 窗口内发出第二发（job 秒 failed 不构成 dedup 条件）→ 增量 2。实测排除。
- 锁窗口内行为：按钮 loading 态生效（`:loading="syncingId === row.id"`），状态行显示 "Syncing…"；锁在 3s 轮询见 FAILED 后正确释放。

### catch 路径实测（1 minor）
- 场景：API 删除 sync row 后不刷新面板，点 UI 残留行的 Resync → atImportTrigger 404（`Sync Source not found`）→ catch 清锁（btnLoading=false 实测）✓
- **minor**：`packages/nc-gui/components/project/Sync/index.vue:206-208` catch 分支只清 `syncingId` 未清 `syncStatus[row.id]` → 状态行**永久残留 "Syncing…"**（实测 4s 后仍在，至下次操作/刷新才消失）。系 R4 乐观置位引入（旧代码失败时 status 尚未置位无残留）。无功能损害（按钮解锁、无请求泄漏）。建议 catch 中一并覆写 `syncStatus`（如 `{ text: t('labels.syncsSyncFailed'), failed: true }`）或 delete 该 key。

## 全矩阵回归（R1/R4 任务书同规格）

### ACL 矩阵（API 实测，专属 base）
- owner/creator：list/create/PATCH/DELETE/internal-ops 全 200 ✓
- editor/viewer：list/create 403；PATCH/DELETE 403（直接端点 `/api/v2/meta/syncs/:id` 与 internal ops 双路径一致）；editor 对 owner 行越权 PATCH/DELETE 403 ✓
- 匿名：list/create/PATCH/DELETE 全 401 ✓
- editor/viewer internal ops：syncSourceList/syncSourceUpdate/syncSourceDelete/atImportTrigger 全 403 ✓
- 注：正确路径下无 404 异常；editor PATCH 后数据未变（row intact 验证）。

### CRUD e2e
创建→列表含→PATCH（title+details）→重查一致→DELETE→重列归零，全 200 ✓；internal ops syncSourceUpdate（creator 200）/syncSourceDelete（editor/viewer 403 后 row 保留）✓

### UI 段（camoufox owner 会话）
- 空态文案、卡片渲染（title/type 徽标/details keys）、Edit 预填（title + JSON）→ 保存 → UI 与 DB 一致（`f05r5l3-sync1-edited` + 3 keys）、Delete 确认弹窗（含数据保留文案）→ 行消失 → 空态、DB 0 行 ✓
- 侧栏 Manage Syncs 菜单（owner 可见，`proj-view-tab__syncs` tab 键在）✓
- Resync 触发 → job 创建（API 计数）✓；Nuxt error overlay 双零（owner/editor 页面多次检查 `vite-error-overlay`/`nuxt-error-overlay` 均无）✓

### editor UI 隔离（专属会话 f05r5l3e）
- settings 侧栏无 Manage Syncs 菜单项（`[data-testid=base-syncs]` 数 0；侧栏仅 Invite Members/MCP Server）✓
- 直 URL `#/nc/:baseId/settings/syncs` 无 `.nc-base-syncs` 面板 ✓

### App Sync 隔离
- 源码：`store/sync.ts:19 isSyncFeatureEnabled = ref(false)` 未动；三消费组件（IntegrationsTab/AddConnectionDropdown/base Integrations）引用保留。
- UI：base Integrations tab 与 workspace Integrations 页均无 App Sync 文本/创建入口 ✓

### 回归 smoke（API 探针，专属 base）
F02/F03 permissionList 200 / F05 variables 200 / F07 snapshots 200 / F10 dashboards 200 / F08 base meta 含 `is_private` / tables list 200。Import > Airtable 入口存在（建表后实测），向导深走属 E3 沿袭。

### i18n
16 键 en+zh-Hans 双份全在；90s 超时文案 en "Still syncing after 90s — check back later or retry." / zh "90 秒后仍在同步——请稍后回来查看或重试。" 均无 job list 字样（R3 修复项沿袭验证 ✓）。

### 质量门
- `cd packages/nocodb && npx tsc --noEmit` exit 0
- jest：Test Suites 2 passed / **Tests 26 passed 26**，exit 0

## E3 / 已知沿袭（不计 error）
- FAILED 详情恒泛型：job `result=null` 实测复现（上游 setJobResult 零调用），UI 回落泛型失败文案——沿袭 R1-R4 清单。
- 重同步全链路需真实 Airtable 凭证（fork 限制）。
- AirtableImport 向导深走（无凭证段）。
- dev 库 869 用户噪声；v1 bulkUpsert 500 / v1 title 寻表 404 / sharedView meta / duplicate >1000 行等沿袭项本轮未重点复测（非 F04 触碰面）。

## 环境备注（流程观察，非 issue）
- :3000/:3100 前端 dev server 在多 lane 并发（4 个 nuxt dev 实例 + usePolling watcher）下 HTTP 不服务；本 lane 改用 `nuxt build` + 生产 SSR（:3200，`NUXT_PUBLIC_NC_BACKEND_URL=http://localhost:8080`）完成全部 UI 实测，结束后已停。首次 build 因 stale `.output` ENOTEMPTY 失败，清除后重试成功。
- 共享 owner（f03r3-owner）多路互踢复现：API token 被 UI 同账号登录失效。本 lane 全程改用专属 owner（f05r5l3-owner）+ creator 做 API，互踢不再影响；UI 与 API 分账号。

## 测试资产清理
专属 base `f05r5l3-base`（pdsh7dpygo2r3p9）DELETE 200；f05r5l3-{owner,creator,editor,viewer}@t.local 四账号全删；`f05r5l3-*` 前缀用户残留 0（users list 复查）。camoufox 两会话（f05r5l3 / f05r5l3e）已关。
