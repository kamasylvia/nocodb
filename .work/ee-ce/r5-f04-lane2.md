# F04 Manage Syncs R5 复审报告 — lane 2

PASS（0 error）

审查基准：R4 修复批 commit 9188e0f1ff + 审后 minor 64b720d877（catch 清乐观状态，已在 HEAD）。

## R5 专属附录验证

1. **resync 乐观置位锁 — 过**。代码：`Sync/index.vue:150` syncingId 置位 + 状态文案均在 `atImportTrigger` POST 之前（await 窗口内锁已生效）。UI 实测（camoufox session f05r5l2，owner/creator 会话）：同 tick `btn.click()` ×2 → performance API `getEntriesByType('resource')` 过滤 `/api/v2/internal/` 计数 = **1**（URL 确认 `operation=atImportTrigger&syncId=ncevv773bbi6vama`），第二击命中 guard 弹 `.ant-message` **"Syncing…"** info toast。不依赖后端 400 去重。
2. **锁释放路径完备 — 过**。四路径全验：
   - FAILED 终态：假 Airtable 凭证 job 失败 → 行状态 "Sync failed"（红）、按钮非 loading 非 disabled、可再点 ✓
   - catch 路径（64b720d877 修复）：API 删除 sync 后 UI 点 Resync → POST 4xx → 状态置错误原文红字 "Sync Source 'ncevv…' not found"（非灰 "Syncing…" 残留）、按钮解锁 ✓
   - COMPLETED / timeout：代码审 `index.vue:181-200` clearInterval + watchdogTimers 过滤 + syncingId=null 三处齐 ✓
3. **R4 附录回归 — 过**：watchdog onUnmounted 全清（:44-47）+ 实测 Resync 后立即导航离开（切 Data view）→ 8s 后重进面板正常渲染、无 Nuxt overlay；二次 resync 反馈（"Syncing…" toast）已在 R5-1 实测；90s 超时文案 en.json:4210 / zh-Hans.json:2804 双份，均无 "job list" 字样。

## R1 全矩阵回归

- **gate 无回归**：useEeConfig.ts:158 `blockSync=false`；View.vue:572 tab pane（`!blockSync && isUIAllowed('sourceCreate')`）+ :175 watch 无 isEeUI；BaseSettingsMenu.vue:168 `!blockSync`。creator settings 侧栏见 Manage Syncs 菜单项。
- **ACL 矩阵（API 实测，f05r5l2-* 账号）**：creator list/create/patch/delete 全 200；editor/viewer list/create 403；匿名 list/create 401、patch 404。
- **CRUD e2e**：create(type Airtable+details) → 列表含该行 → PATCH title+details 生效（重列确认）→ DELETE → 重列归零。
- **editor UI 隔离**：editor settings 侧栏无 Manage Syncs 菜单项（仅 Invite Members / MCP Server）；直 URL `/settings/syncs` 无 `.nc-base-syncs` 面板。
- **App Sync 隔离**：base Integrations tab 无 "App Sync" 文本、无 Add Connection 入口；store/sync.ts:19 `isSyncFeatureEnabled = ref(false)` 恒 false（三消费组件无暴露）。
- **回归 smoke**：F02/F03（Data Permissions 面板渲染）、F05（Variables 面板 + Add 空态）、F07（Snapshots 面板 + New Snapshot）、F08（API `is_private` 字段在）、F10（dashboards API 200）全探针过；Import Data（AirtableImport 向导入口）在。
- **质量门**：`tsc --noEmit` 无错误输出 exit 0；jest **41/41**（3 suites，含 F09 新增 table-syncs.Fork.spec 15 测试，超 26 基线零失败）。
- **F04 后端零改动保持**：实现 commit 2fd09efccf 仅 7 文件（6 前端 + 调研文档），无 packages/nocodb/src。

## Observations（不计 error）

1. `index.vue:194` timeout 分支（polls>=30）位于 try 块内：若 job 列表查询连续 90s+ 全部抛错，timeout 分支不达、锁不释放。实际影响趋零（onUnmounted 兜底清理；网络全断时面板本身不可用），R1-R4 沿袭语义，留观。
2. 流程：公共 owner 账号（f03r3-owner）实测每次 signin 轮换 token_version，并行 lane 同账号 signin 互踢致 JWT 秒级失效。本轮绕法：base-scoped API token（xc-token，不互踢）做管理面 + 专属 creator 账号做 UI。建议后续轮 UI 测试建 lane 专属 owner。

## E3 沿袭（不计 error）

v1 bulkUpsert 500 / v1 title 寻表 404 / sharedView meta / duplicate >1000 行 / v2 upsert 旗标（上游）；FAILED 详情恒泛型（本轮实测仍泛型 "Sync failed"，上游 setJobResult 零调用）；重同步全链路需真实 Airtable 凭证（fork 限制）。

## 测试资产清理

f05r5l2-ui-sync/ui-sync2、acl-probe-* sync、f05r5l2-base、api-token #47、6 账号（creator/editor/viewer + 上轮遗留 owner/editor/viewer@ce-ee.local）全删；camoufox session f05r5l2 已关；/tmp 凭证文件已删。
