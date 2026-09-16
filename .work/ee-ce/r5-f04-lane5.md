# R5 F04 Manage Syncs — Lane 5 报告（R4 修复批回归）

PASS（0 error）

## 审查对象

R4 修复批单提交 `9188e0f1ff`（fix(nc-gui): F04 R4 review minor — optimistic syncingId lock on resync）。HEAD = main 含该 commit（`git log` 确认，前一提交 `18c443b9bb`）。

## 1. 代码审查（9188e0f1ff）

- 单文件 `packages/nc-gui/components/project/Sync/index.vue`，+5/-2，diff 不含 `packages/nocodb/src`（后端零改动 ✓）
- 改动本质：`syncingId.value = row.id` 与 `syncStatus[row.id] = { text: Syncing }` 从 `await $api.internal.postOperation(atImportTrigger)` **之后**移到 **try 块前置（同步执行）**。JS 单线程语义下，第一 click 的 handler 同步段先于任何微任务/后续事件执行 → await 窗口内第二 click 进入 `resync()` 时 `syncingId` 已置位 → 走 `if (syncingId.value)` 分支（info toast + return），不再发出第二发 `atImportTrigger`。UI 锁不再依赖后端 job 去重 ✓
- 锁释放路径完备：COMPLETED / FAILED / 90s timeout 三分支均清 `syncingId` 并从 `watchdogTimers` 移除 interval（R3 修复未回归）；trigger 抛错 catch 分支清锁 ✓
- 与既有 R2/R3 修复（jobs-list 轮询、watchdog 卸载清理、二次反馈、超时文案）无冲突，逻辑未被重排破坏 ✓

## 2. 核心回归实测（camoufox，`--session f05r5l5` 专属）

环境：production build（`nuxt build` 产 `.output`）以 `PORT=4000 NUXT_PUBLIC_NC_BACKEND_URL=http://localhost:8080` 独立 serve；账号 `f05r5l5-ui@t.local`（workspace-level-creator）。

- **双击不发第二发（R5 主项）**：`performance.getEntriesByType('resource')` 过滤 `atImportTrigger`，clear → 同步 `btn.click(); btn.click()` → **count = 1**（唯一一发，query `operation=atImportTrigger&syncId=ncqecezgy4cvw569`）。第二 click 被前置锁拦截 ✓
- **锁释放**：job FAILED 终态（面板显示 "Sync failed"）后 `syncingId` 清空，再单击 → 同一计数器 **totalAfter = 2**（新请求正常发出）✓
- **resync 全流程**：click → trigger 200 → watchdog 3s 轮询 jobs list → 假凭证 job 快速 `failed` → 面板终态文案 "Sync failed"（failed 红样式）→ 锁释放 ✓
- 面板渲染：Manage Syncs 菜单（creator 可见）→ 面板 `.nc-base-syncs` 渲染；空态文案 "No syncs yet…" 正确；卡片（title/type AIRTABLE/details 键展示/底部 hint）正确 ✓
- Edit：Edit 打开回填 title + details JSON；坏 JSON 保存 → 内联 "Details is not valid JSON"；修正后保存 → toast "Sync source updated"、面板刷新、API 复核 title/details 已落库 ✓
- Delete：确认弹窗（标题 "Delete sync source"，内容含 title 与 "Imported tables and data are kept"）→ 确认后面板回空态、API list 归零 ✓
- editor 隔离（`f05r5l5-editor@t.local` 独立会话 `f05r5l5e`）：直接 router 跳 `/w9qi3ljd/:baseId/settings/syncs` → **无 `.nc-base-syncs` 面板**（hasPanel=false）；settings 侧栏**无 Manage Syncs 菜单项** ✓
- error overlay / 模态残留：无 vite-error-overlay / nuxt overlay DOM，无残留 dialog ✓

## 3. API / ACL spot（f05r5l5-owner 专属 token）

- owner(workspace-level-owner) 对 `/api/v2/meta/bases/:id/syncs` list/create/patch 200 ✓
- editor：list/create/patch/delete 全 **403** ✓；匿名 list **401** ✓
- App Sync 隔离：`store/sync.ts` 未动，`isSyncFeatureEnabled = ref(false)` 无任何赋 true 路径（grep 证实）；F04 diff 未触碰 store ✓

## 4. 质量门 + 回归 smoke

- `cd packages/nocodb && npx tsc --noEmit` → **exit 0** ✓
- jest（后端桶）→ **26/26 passed**（2 suites）✓
- 功能探针（只读，对既有 base）：F02/F03 `/meta/bases/:id/permissions` 200；F05 `/meta/bases/:id/variables` 200；F07 `/meta/bases/:id/snapshots` 200；F10 `/meta/bases/:id/dashboards` 200；F08 base meta get 200 ✓

## 5. 观察项（不计 error）

1. **in-flight info toast 未在受控双击中捕获 DOM**：双击实验 count=1 证明锁生效，但第二次 click 的 "Syncing…" toast 未被 MutationObserver / `.ant-message` 捕获。旁证：保存 toast（message.success）通道正常。最可能解释是 `NcButton :loading`（optimistic 置位后按钮立即进入 loading）使 antd Button 吞掉第二次 click —— 等效于按钮级第二道锁，行为目标（不发第二发）已达成。R4 对 toast 的验收场景（后端慢返回窗口）与本次按钮 loading 场景不同。无需修复；如后续轮要统一表现，可考虑 loading 之外仍保留 click 通路。

## E3（外部限制，沿袭清单）

- 重同步全链路需真实 Airtable 凭证（fork 限制，R1 裁定）——本次以假凭证 FAILED 终态路径覆盖 trigger→watchdog→清锁全流程。
- FAILED job 的 `result.error.message` 恒空、面板显示泛型 "Sync failed"（上游 `setJobResult` 零调用，R3 沿袭）。

## 环境与资产

- nuxt dev server 在本环境挂起（监听但不响应），改用 production build + 独立 serve :4000 完成 UI 实测；结束后已停。
- 共享 owner `f03r3-owner` 存在并行 lane signin 互踢（token_version 频繁轮换），全程使用自建账号：`f05r5l5-owner`（API）/ `f05r5l5-ui`（UI creator）/ `f05r5l5-editor`（隔离测试）。
- 清理：两个 `f05r5l5` 前缀测试 base 已 DELETE（404 复核）；camoufox 会话（f05r5l5 / f05r5l5e）已 close；:4000 serve 进程已停；8080 后端未触碰（未重启、未 kill）。
