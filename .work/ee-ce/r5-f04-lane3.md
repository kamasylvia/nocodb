# F04 R5 复审报告 — lane3（重派轮）

PASS（0 error）

- 审查 HEAD：main = 1480308312（含 R4 修复批 9188e0f1ff + R5 hardening 64b720d877）
- 环境实测：后端 :8080 / 前端 :3000 全程存活（仅一次 curl 与 UI 的 token 互踢，为已知机制，见观察项 4）
- 测试账号：f05r5l3-owner/editor/viewer@t.local（owner 经 f03r3-owner invite 入 base）；测试数据全部 f05r5l3-* 前缀；base 已删、浏览器会话已关、/tmp 凭证已清
- 注：本文件覆盖上一轮 R5 lane3 报告（Sep 17 01:31 版），本轮为 R5 重派独立复审

## 1. R5 专属附录验证（核心）

### 1.1 resync 乐观置位锁（9188e0f1ff）— PASS

- 代码审：`packages/nc-gui/components/project/Sync/index.vue:147-153` — `syncingId.value = row.id` 与 status 置位移至 `atImportTrigger` POST **之前**，位于 try 外（catch 可达）。resync handler 同步段在第一个 await 前完成置位，第二个 click 事件必然命中 `if (syncingId.value)` guard。
- 实测（camoufox session f05r5l3，owner UI）：扩容 `performance.setResourceTimingBufferSize(8192)` 后，同一 eval 内同步双击 Resync（比真实鼠标双击更严苛的零间隔场景）：
  - performance resource entries 中 `operation=atImportTrigger` 请求 = **1 发**（`http://localhost:8080/api/v2/internal/w9qi3ljd/p08xokzkbr2hphj?operation=atImportTrigger&syncId=ncx0nwfkagdiejk5`）
  - `.ant-message-notice` 仅 1 个 toast："Syncing…"（第二击 guard 反馈）
  - 不依赖后端 400 去重：guard 先于 POST 命中 ✅

### 1.2 锁释放路径完备 — PASS

四条路径逐一核实（index.vue）：

| 路径 | 位置 | 清锁 | 状态文本 | 实测 |
|---|---|---|---|---|
| COMPLETED | :181-185 | clearInterval + watchdogTimers 移除 + syncingId=null | syncsSyncDone | 代码审 |
| FAILED | :186-193 | 同上 | syncsSyncFailed | **实测**：伪凭证 job 数秒 failed → 按钮 loading 消失、btnDisabled=false、行显示 "Sync failed" |
| timeout (polls≥30) | :194-200 | 同上 | syncsSyncTimeout(failed) | 代码审 + R3 计划外实测命中沿袭 |
| catch（POST 被拒） | :206-214 | syncingId=null | **后端错误文本(failed)**（64b720d877 修复：不再残留灰色 "Syncing…"） | 代码审（diff 确认 catch 先取 msg 再双写 syncStatus + message.error） |

- **失败终态后 Resync 可再点**：实测 FAILED 后再次双击成功触发新 trigger（1.1 的第二次双击实验即建立在首次 FAILED 之后）✅

## 2. R4 修复批回归验证

1. **watchdog 卸载清理（b6c95cb3ac）— PASS**：实测制造真实打断场景——纯 SPA hash 导航（document 全程未重载，以 `window.__alive` 标记验证）内点击 Resync、1 秒内离开（离开时按钮仍 loading、watchdog 首个 3s tick 未到），导航后 100 秒 resource entries 中 `/api/v2/jobs/` 请求 = **0**（若清理失效应有 ~30 个）。探针纯净性：`loadJobsForBase`/`jobs.list` 消费者仅 Sync/index.vue 与未开启的 AirtableImport 弹窗。代码审：`index.vue:40-47` watchdogTimers 登记（:183/:188/:197/:205）+ onUnmounted 全清。
2. **二次 resync 反馈 — PASS**：guard 命中弹 "Syncing…" info toast（1.1 实测同场验证；不再静默 return）。
3. **90s 超时文案 — PASS**：en.json:4210 `"Still syncing after 90s — check back later or retry."` / zh-Hans.json:2804 `"90 秒后仍在同步——请稍后回来查看或重试。"`——均不提及 job list。

## 3. 全矩阵复核（R1 规格回归）

- **diff 审查**：F04 commit 链 2fd09efccf → dbfefe5a63 → b6c95cb3ac → 9188e0f1ff → 64b720d877 逐一 `git show --stat`：**均零 packages/nocodb/src 变更**（后端零改动保持）。64b720d877 为 HEAD 祖先。blockSync=false（useEeConfig.ts:158）；View.vue:173 去 isEeUI 仅限 syncs watch、:572 tab flag 化；BaseSettingsMenu.vue:166-183 flag 化；store/sync.ts 未动。
- **i18n**：14 个 syncs* 键 + manageSyncs 在 en/zh-Hans 双份且键集合一致；组件 t() 消费 15 键全部有定义。
- **ACL 矩阵（API 实测）**：owner 对 `/api/v2/meta/bases/:id/syncs` list/create + `/api/v2/meta/syncs/:id` patch/delete 全 200；editor 四操作全 403；viewer 四操作全 403；匿名四操作全 401。internal op `atImportTrigger`：owner 200（返回 job id）、editor 403。
- **CRUD e2e**：create（type Airtable + details JSON）→ list 含行 → PATCH title+details 落库复核（`{"apiKey":"fake2"}`）→ DELETE 200 → relist 归零 → 重建 UI 测试行。
- **UI 段（owner 会话）**：面板渲染（卡片/title/type/details keys/hint）✅；Edit 回填 title+JSON → 改 title 保存 → toast "Sync source updated" → UI 刷新 + API 落库（f05r5l3-ui-sync-v2）✅；Delete 确认框（title/描述插值正确）→ 确认 → 行消失 + 空态文案 + API 归零 ✅；console error 与 Nuxt overlay 双零 ✅。
- **editor UI 隔离**：独立会话登录 editor，settings 侧栏 testid 清单 = base-collaborator/base-mcp/access-settings/mcp——**无 base-syncs**；直接 URL `#/nc/:baseId/settings/syncs` 不渲染面板（无 `.nc-base-syncs`）✅。
- **App Sync 隔离**：`isSyncFeatureEnabled` 恒 false（store/sync.ts:19）；base Integrations tab 实测无 "App Sync" 文本、无 add-connection 入口（AUTH 类 integration 被 Integrations.vue:123 门过滤）；workspace 页无 integrations/App Sync 入口 ✅。
- **回归 smoke**：F02/F03 permissionList 200；F05 variables 200（v2 路径）；F07 snapshots 200；F08 base GET 200；F10 dashboards 200；base 侧栏 Variables/Snapshots/Integrations 菜单齐全；Import 菜单 Airtable 入口在（向导未回归）✅。
- **质量门**：`npx tsc --noEmit` exit 0；jest 3 suites **41/41 passed**（Fork 桶较 R1 基线 26 增至 41，系后续功能新增 Fork.spec，全绿）。

## 观察项（非 error）

1. `syncStatus` 文本为组件会话态：Edit 保存刷新列表后行内仍显示上轮 "Sync failed"，面板重进即清。无害反馈残留，不建议改。
2. 侧栏 Manage Syncs 的 `LazyPaymentUpgradeBadge`（BaseSettingsMenu.vue:181，`:feature-enabled-callback="() => !isEEFeatureBlocked"`）在解锁态渲染为 hidden——与 F07 Snapshots 菜单行为逐字节一致（对照实测），F07 先例模式。
3. 双击实验采用同任务零间隔双 click，严于真实 dblclick；真实双击间隔更大，锁置位只会更早，结论不受影响。
4. shell 侧 curl `signin` 会使 UI 侧 auth token 失效（token_version 递增互踢），本轮 owner UI 会话被自建脚本踢过一次后重登完成剩余测试。R4 纪律「每路自建专属账号」正确性再次实证；lane 内脚本应避免对 UI 在用账号 signin。
5. workspace 主页 SPA 导航时偶发一帧 "Page Loading Error"（reload 即消失）——上游框架瞬态，非 F04 引入。

## E3（不计 error，沿袭 + 本轮新增证据）

- FAILED 详情恒泛型（上游 setJobResult 零调用）：本轮实测伪凭证 job `result.error` 为 null → UI 显示 "Sync failed" 泛型，与已知 E3 一致。
- v1 bulkUpsert 500 / v1 title 寻表 404 / sharedView meta / duplicate >1000 行 / v2 upsert 旗标 / dev 库 700+ 测试账号噪声：未复测，沿袭 R4 清单。
- 重同步全链路需真实 Airtable 凭证（fork 限制）：本轮以伪凭证覆盖 trigger/watchdog/FAILED 路径，均在 fork 限制范围。

## 资产清理

- base p08xokzkbr2hphj（f05r5l3-base）已删除（DELETE 200，GET 复核 Base not found）
- camoufox 会话 f05r5l3 / f05r5l3-ed 已 close；/tmp 下 lane token/脚本已删
- 账号 f05r5l3-owner/editor/viewer@t.local 保留（与其他轮次测试账号同样留存于 dev 库，属 E3 噪声口径）
