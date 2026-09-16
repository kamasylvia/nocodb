# F04 R5 — lane 1 报告

PASS（0 error）

- HEAD：`9188e0f1ff`（fix(nc-gui): F04 R4 review minor — optimistic syncingId lock on resync）已确认
- 审查对象：R1 全规格矩阵 + R5 增量（R4 修复批 `9188e0f1ff` 逐项实测回归）
- 测试前缀：`f05r5l1-*`（账号/base/sync 全部自建；资产已清：3 个 base 删除 200，sync 随 base 级联归零）

## R5 增量：R4 修复批回归（commit 9188e0f1ff）

1. **resync syncingId 乐观置位** — 实测通过，双证据：
   - 代码审（`packages/nc-gui/components/project/Sync/index.vue:147-156`）：`syncingId.value = row.id` + syncStatus 置位移至 `try` 之前同步执行（await 窗口前生效）；失败路径 `catch`（:206-209）清锁 + error toast——乐观置位后伪凭证失败不会残留死锁。
   - 浏览器实测（camoufox owner 会话，Performance API 计数）：双击 Resync → `performance.getEntriesByType('resource')` 中 `atImportTrigger` 请求**恰好 1 发**（`POST /api/v2/internal/w9qi3ljd/:baseId?operation=atImportTrigger&syncId=…`）；第二击命中 `if (syncingId.value)` 分支仅产生 info toast "Syncing…"，无第二发网络请求。UI 锁不依赖后端去重达成。复跑第二轮（clearResourceTimings 后再双击）trigCount 仍恒 1。
   - 失败闭环：伪凭证 trigger 后 watchdog 轮询至 job FAILED，状态行 "Sync failed"、按钮 loading 解除可再点（两轮均复现）。

## R3 修复批沿袭回归（均通过）

- **watchdog 卸载清理**（b6c95cb3ac）：触发 resync 后 0.5s 导航离开 base → 离开后即时与 10s 后 jobs 轮询计数恒 1（零新增）= 组件卸载时 interval 被 `onUnmounted` 清除，无孤儿轮询。代码审同步确认（index.vue:44-47 + 各终态 clearInterval + watchdogTimers 同步过滤）。
- **二次 resync 反馈**：in-flight 时点击 → info toast "Syncing…" 实测捕获（`ant-message-notice` 文本）。
- **90s 超时文案**：`syncsSyncTimeout` = "Still syncing after 90s — check back later or retry."（en）/「90 秒后仍在同步——请稍后回来查看或重试。」（zh），无 "job list" 字样。

## R1 规格矩阵

### 1. diff 审查
- 实现批 `2fd09efccf`（7 文件：Sync/index.vue 主体 + View.vue/BaseSettingsMenu.vue 双入口 gate + useEeConfig blockSync + i18n en/zh + 调研文档）；修复批 `b6c95cb3ac`（index.vue + i18n×2）；R4 修复批 `9188e0f1ff`（index.vue 单文件 +5/-2）。**后端 `packages/nocodb/src` 零改动**（三批 diff 均不含）✓
- `blockSync = computed(() => false)`（useEeConfig.ts:158）+ `// [CE-EE]` 注释 ✓；View.vue:173-176 深链 watch 已去 `isEeUI`（flag 化）✓；`store/sync.ts` 未动、`isSyncFeatureEnabled` 恒 false（store/sync.ts:19 无赋 true 路径）✓
- i18n 15 键（syncsSubtitle…syncsSyncTimeout）en.json:4196-4210 与 zh-Hans.json:2790-2804 一一对齐，路径与组件 `t()` 消费一致 ✓

### 2. ACL 矩阵（API 实测，/api/v2/meta/bases/:id/syncs + /api/v2/meta/syncs/:id）
| 操作 | owner | creator | editor | viewer | 匿名 |
|---|---|---|---|---|---|
| list | 200 | 200 | 403 | 403 | 401 |
| create | 200 | 200 | 403 | 403 | 401 |
| patch | 200 | 200 | 403 | 403 | 401 |
| delete | 200 | 200 | 403 | 403 | 401 |
| trigger（REST + internal op 双路） | 200 | — | 403 | 403 | 401 |
- owner 判定注明：本轮 owner = `f03r3-owner@t.local`（super，历轮共享 bootstrap；base 级 owner 角色语义由邀请 creator 补证）。遵守 R4 纪律：无 psql 提权、账号仅动本 lane 前缀。

### 3. CRUD e2e
create（type=Airtable + details）→ list 含行 → PATCH title 落库 → DELETE → 重列归零 ✓。atImportTrigger 伪凭证（fake apiKey/baseId）：REST `/trigger` 与 internal op 双路均 200 受理 → jobs-list 终态 `failed`（干净失败无 500/hang；FAILED result 为空 = 上游 setJobResult 零调用，已知沿袭）。

### 4. UI 段（camoufox owner 会话，:3002/:3005 前端 dev）
- base settings 侧栏 **Manage Syncs 菜单存在**（`data-testid=base-syncs`，badge `:feature-enabled-callback` 形态）→ 点击 → 面板渲染（标题/副标题/卡片：title、AIRTABLE 类型、details 键、Resync now/Edit/Delete 按钮）✓
- 空态：Delete 后显示 "No syncs yet. Create one via Import > Airtable on the base home." ✓
- Edit：title 改名 → Save → 成功 toast "Sync source updated" + 卡片回显新名（loadSyncs 数据源=API，即服务端确认落库）✓
- Delete：确认弹窗标题/描述正确（含「已导入表与数据保留」）→ 确认后卡片消失 ✓
- 深链 `#/nc/:baseId/settings/syncs`（owner）直开面板 ✓
- console error / Nuxt overlay 双零（error/unhandledrejection/console.error 收集器 + overlay DOM 检查）✓

### 5. editor UI 隔离（camoufox editor2 会话）
- settings 侧栏**无** Manage Syncs 菜单项（截图 `/tmp/f05r5l1-editor-syncs-menu.png`：侧栏仅 Invite Members to Base / MCP Server）✓
- 深链 `#/nc/:baseId/settings/syncs`：`.nc-base-syncs` **不渲染**（panelRendered=false，内容区空白）✓
- 观察（沿袭 R4 已知非问题「editor 顶栏标题/上游框架」）：editor 深链时页头标题栏仍显示 "Manage Syncs" 文案（View.vue:242 标题映射不随 tab v-if 联动，纯文案零数据零交互，面板本体不渲染）——不计 error。

### 6. App Sync 隔离
- base settings → Base Integrations 页：仅 Database 连接器（MySQL/PostgreSQL/SQLite），无 App Sync/Sync Config 字样 ✓
- workspace Integrations 页（`/:wsId/integrations`）：同上，无 App Sync 创建入口 ✓
- `isSyncFeatureEnabled` 三消费组件门未动（代码审）✓

### 7. 回归 smoke
F05 variables list 200 / F02 permissions list 200 / F03 permissions list 200（`/api/v2/meta/bases/:id/permissions` 即 F03 端点） / F07 snapshots list 200 / F08 base meta `is_private=False` 正常读 / F10 dashboards list 200 / F01 表列 meta 可读（8 列标准 schema）——七探针全绿。

### 8. 质量门
- `cd packages/nocodb && npx tsc --noEmit` → **exit 0**
- `npx jest` → **26/26**（2 suites passed）

## E3（环境限制，不计 error）
1. **前端 dev 实例不稳定**：审查窗口内外置盘（UNITEK）冷缓存导致 `nuxt dev` 多实例（:3000/:3002/:3100/:3005）长时间无响应或中途退出（I/O wait，GOAL-STATE 已知问题）。:3002 曾恢复完成 owner 段走查；其后再次死亡，:3005 第三次启动约 25min 后恢复，补完 editor 段。editor 段的浏览器断言最终全部实测完成，无降级。
2. **共享 bootstrap 互踢**：`f03r3-owner` 为多 lane 共享 super，任意 lane UI/API 登录即触发 token_version 互踢（本轮 API 段 3 次遇 401 重 signin 自愈）。属共享账号固有语义，非 F04 缺陷。
3. dev 库 700+ 历轮测试账号噪声（base users 列表返回全量历史账号）——上游分页行为，沿袭已知。

## 已知非问题沿袭（R4 清单）
成员下拉截断（不存在）、editor 顶栏标题（上游框架）、v1 bulkUpsert 500 / v1 title 寻表 404 / sharedView meta / duplicate >1000 行 / v2 upsert 旗标（上游）、FAILED 详情恒泛型（上游 setJobResult 零调用）。
