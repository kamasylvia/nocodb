# F04 R5 复审报告 — lane 2

**PASS（0 error）+ 1 minor**

- HEAD：9188e0f1ff（R4 修复批，本轮唯一增量）。审查期间 `git diff b6c95cb3ac..HEAD -- packages/` 仅 `Sync/index.vue` +5/-2，无其他漂移。
- 环境：后端 :8080（全程存活）；前端 nuxt dev 自起（并行 lane/patrol 竞争 .nuxt，三次实例崩溃后于 [::1]:3000 稳定，见 E3）。
- 账号：creator=f05r5l2-owner@ce-ee.local（base role creator）、editor/viewer=f05r5l2-editor/viewer@ce-ee.local；base=f05r5l2_base_1789574345（owner 借 f03r3-owner 建，已删）。camoufox --session f05r5l2 专属。

## 1. R5 增量：9188e0f1ff 回归（syncingId 乐观置位）

**PASS，运行时实证。**

- diff 审：锁置位（`syncingId.value = row.id` + syncStatus）移至 `atImportTrigger` await 之前；catch 仍 `syncingId.value = null`（失败放锁）；成功路径 COMPLETED/FAILED/90s 超时三分支均放锁 + watchdog 句柄从 watchdogTimers 移除。仅 nc-gui 1 文件，后端零改动。
- UI 实测（camoufox + 页面 realm XHR 计数器）：同 tick 双击 Resync → **恰 1 发 atImportTrigger**（`document.documentElement.dataset.f04xhr = "1"`），第二击命中 guard → info toast "Syncing…"，按钮 loading=true。旧代码此场景必发 2 发（toast 不会出现）——修复确认生效。
- 全环路：触发 → job 假凭证 FAILED → watchdog 捕获 → 状态 "Sync failed" + 锁释放（btnLoading=false）。重复验证两轮一致。
- 测量方法注记：camoufox eval 沙箱 realm 补丁（XHR/fetch wrap）对页面请求**不可见**（两轮假 0 计数假象）；须注入 `<script>` 进页面 realm 并经 DOM dataset 回读。已作为流程教训附末尾。

## 2. 全矩阵（R1 同规格）

- **diff/gate**：blockSync=false（useEeConfig.ts:158）；View.vue:572 tab-pane `!blockSync && isUIAllowed('sourceCreate')...`（:173 watch 已去 isEeUI）；BaseSettingsMenu syncs 项 `!blockSync` gate + badge `:feature-enabled-callback="() => !isEEFeatureBlocked"`（照 snapshots 模式）；`store/sync.ts` 未动（isSyncFeatureEnabled 恒 false）。
- **ACL**：creator list/create/patch/delete 全 200（PATCH title+details 落库复核一致）；editor list/create/patch/delete 全 403；viewer list/create 全 403；匿名 list/create 全 401。
- **UI（creator）**：双入口在位（侧栏菜单项 `data-testid=base-syncs` 含 badge、settings tab `proj-view-tab__syncs`）；面板渲染 title/subtitle/卡片/details 键行/提示；Edit 预填 title+JSON → 改名改 JSON → Save → 卡片更新 + API 复核（keys 变 `note/shareId/syncId`）；Delete 确认弹窗文案正确 → OK → 行消失；Resync/失败路径见 §1；Nuxt/vite overlay 双零。
- **UI（editor）**：settings 侧栏无 Manage Syncs 菜单项（`base-syncs` testid 不存在）；无 syncs tab；直接 URL `/w9qi3ljd/pxhw3n2x7x759el/settings/syncs` **不渲染面板**（无 .nc-base-syncs）。结构性保证：`ProjectSync` 位于 v-if 含 `isUIAllowed('sourceCreate')` 的 tab-pane 内（View.vue:572-587），editor 下整 pane 不挂载。
- **App Sync 隔离**：base Integrations tab 渲染 Database（MySQL/PostgreSQL/SQLite）无 App Sync/AUTH 入口（body 无 "app sync"）；workspace Integrations 页同（hasAppSync=false）；三消费组件（IntegrationsTab/AddConnectionDropdown/dashboard settings Integrations）静态复核仍依赖 `isSyncFeatureEnabled=false`。
- **watchdog 卸载清理（R3 项回归）**：代码 onUnmounted 全清 watchdogTimers；UI 行为验证——Resync 后 1s 内导航离开 → 20s 后重进面板正常、按钮无卡 loading、无死锁。
- **i18n**：16 键 en+zh 双份齐（2740/4196-4210、2083/2790-2804）；90s 超时文案无 "job list" 字样（R3 项维持）。

## 3. 质量门

- `npx tsc --noEmit`：无错误输出（干净）。
- jest：**26/26 PASS**（2 suites：baseVariableValidators.Fork / uniqueConstraintHelpers.Fork，534s）。

## 4. 回归 smoke

| 功能 | 探针 | 结果 |
|---|---|---|
| F02 | GET /api/v2/meta/bases/:id/permissions | 200 |
| F03 | 待做，无端点 | 不适用 |
| F05 | GET .../variables | 200 |
| F07 | GET .../snapshots | 200 |
| F08 | GET base meta | 200，is_private=false |
| F10 | GET .../dashboards | 200 |

## 5. issues

1. **minor** `packages/nc-gui/components/project/Sync/index.vue:206-209` — R4 乐观置位引入的边角：resync 的 **catch 路径**（POST 本身 reject，如网络错/入队失败）释放了 `syncingId` 但未复位 `syncStatus[row.id]`，行内状态停留灰色 "Syncing…" 文本（误导"仍在同步"），直到下一次 resync 才被覆盖。建议 catch 内补 `syncStatus.value = { ...syncStatus.value, [row.id]: { text: <错误文案>, failed: true } }`。注：当前实测主失败路径（job FAILED）走 watchdog 分支无此问题；触发即拒的场景在本环境未复现（假凭证为 job 级失败）。**不构成 error**（错误 toast 仍弹出、锁正确释放、无功能阻塞）。

## 6. E3（不计 error）

- 前端 dev server：并行 lane 实例 + patrol 自愈 pkill 竞争 `.nuxt`，EPIPE 崩溃 ×3，~50min 后 [::1]:3000 稳定（仅 IPv6 loopback，浏览器/curl 需 `[::1]` 地址）。环境性，非 fork 缺陷。
- 登录态整页 reload 偶发丢失 + 跨 origin（localhost:3002 → [::1]:3000）不共享 token——上游 dev 已知行为（ui-smoke-f01-f05-f07.md 记录），绕法重登。
- 重同步全链路需真实 Airtable 凭证（fork 限制）——本轮以 job FAILED 报错路径验证触发/watchdog/锁闭环。
- dev 库存量测试账号噪声（沿袭）。

## 7. 流程教训（供 orchestrator 入 LESSONS）

- **camoufox eval 是沙箱 realm**：eval 内 patch `XMLHttpRequest/fetch` 或写 `window.*` 对页面 realm 不可见（读自家变量却"正常"，造成探针生效假象）。请求计数/页面 realm 断言必须：注入 `<script>` 标签执行 + 结果写 `document.documentElement.dataset.*` 经共享 DOM 回读。
- nuxt dev 多实例并发同项目目录 = `.nuxt` 竞争 + 相互 kill，全部难以就绪；多 lane 并行时应共享单一实例（orchestrator 起、lane 只用），而非各自 `pnpm dev`。

## 8. 资产清理

- base `f05r5l2_base_1789574345`（含 2 条 sync）已删（DELETE 200，复核 404）。
- camoufox session f05r5l2 已 close。
- f05r5l2-* 三账号留存（与 dev 库既有测试账号噪声同类，未提权删除）。
- 脚本/截图在 /tmp/f04r5l2/（易失，不入仓）。
