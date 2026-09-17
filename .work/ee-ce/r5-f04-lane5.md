# F04 R5 — lane 5 报告

PASS（0 error）

- HEAD 确认：main @ 1480308312；审查对象 = R4 修复批 `9188e0f1ff`（乐观置位锁）+ hardening `64b720d877`（rejected resync 清 optimistic 状态，R5 轮内已落 main，一并纳入回归）
- 测试前缀 `f05r5l5-*`：base `f05r5l5-base`（p2ysmdhtu5849xh，已删 200）、sync `f05r5l5-sync1/2`（已删）、用户 `f05r5l5-owner/editor@t.local`（已删 200×2）、camoufox `--session f05r5l5`（已 close）。复现用临时 base `f05r5l5-repro`（已删 200）。资产全部归零
- 隔离声明：仅触碰自建前缀资产；`f03r3-owner` 仅作 super bootstrap（见「流程记录」）

## R5 增量 1：resync 乐观置位锁（9188e0f1ff）——实测 PASS

- UI（owner 会话，`f05r5l5-sync1` 行）同 tick 双击 Resync（`btn.click(); btn.click()` 单 JS tick）：
  - `performance` resource 计数 `atImportTrigger` = **1 发**（第二击未出网）✓
  - 第二击命中 guard → **"Syncing…" info toast**（antd `.ant-message-notice` DOM 实抓）✓ 不依赖后端 400 去重 ✓
  - 按钮 `loading` class 置位（`:loading="syncingId === row.id"`）✓
- 代码审：置位（index.vue L150-151）先于 trigger POST（L153）；guard（L141-146）在最前。与 R4 修复 diff 一致

## R5 增量 2：锁释放路径完备——PASS（FAILED/卸载实测，COMPLETED 沿袭，timeout/catch 代码审）

| 路径 | 验证方式 | 结果 |
|---|---|---|
| FAILED 终态 | UI 实测：伪 Airtable 凭证 trigger → watchdog 轮询 → 行状态红字 "Sync failed"、按钮 loading 解除 | ✓ |
| 失败终态后可再点 | UI 实测：FAILED 后单击 Resync → 第 2 发 `atImportTrigger` 发出（计数 1→2）、loading 重启 | ✓ |
| watchdog 卸载清理 | UI 实测：trigger 后 200ms 内 SPA 导航离开（popstate → 面板卸载 panelGone=true）→ 25s 后 `/api/v2/jobs/:baseId` 轮询计数 6→6，**孤儿轮询 = 0**（若未清应有 ~8 次） | ✓ |
| COMPLETED | 沿袭 R1-R4 多轮（真实 Airtable 凭证 fork 限制无法产生）；代码审 L181-185 全清（interval + watchdogTimers + syncingId + status） | ✓ |
| timeout（~90s） | 代码审 L194-200（polls>=30 全清 + failed 文案）；R3 轮已计划外实测命中过该路径；本轮未重演（需 90s 挂起 job，收益低） | ✓ |
| catch（POST 被拒，64b720d877） | **代码审** L206-213：catch 无条件 `syncingId=null` + 后端 msg 替换行状态（failed=true）+ error toast。UI 实测：删除行后点 stale 行 Resync → 终态无灰色 "Syncing…" 残留、按钮解锁。后端行为锚定：对已删 syncId 的 atImportTrigger 实测返回 **404 `ERR_GENERIC_NOT_FOUND` "Sync Source '...' not found"**（f05r5l5-repro 最小复现），即 UI catch 路径真实可达，终态行为与修复逻辑吻合 | ✓ |

## R4 增量回归（沿袭复核）

1. watchdog 卸载清理：见上表（孤儿轮询 0 实测）✓
2. 二次 resync 反馈：双击测试中 guard info toast 实抓 ✓
3. 90s 超时文案：en `Still syncing after 90s — check back later or retry.` / zh `90 秒后仍在同步——请稍后回来查看或重试。`，均无 "job list" 字样 ✓

## R1 全规格复核（回归轮快矩阵）

- **diff**：`2fd09efccf`（实现，6 文件全前端 + research md）+ `dbfefe5a63` + `9188e0f1ff` + `64b720d877`（修复链）——**后端 `packages/nocodb/src` 零改动** ✓；`store/sync.ts` 未动 ✓；`isSyncFeatureEnabled` 仍恒 false（store/sync.ts:19）✓；i18n 16 键 en+zh 双份、路径与组件 t() 一致 ✓
- **ACL 矩阵**（API 实测，creator=f05r5l5-owner base creator 角色）：create/list/patch/delete 全 200（PATCH title+details 落库回读验证）；editor `f05r5l5-editor` list/create/patch/delete 全 403；匿名 list/create 全 401 ✓
- **CRUD e2e**：建→列表含→PATCH 落库→删 200→归零（删除有效性由 repro 404 佐证：行已不存在）✓
- **UI 段**（owner）：settings 侧栏 Manage Syncs 菜单在；面板渲染（标题/副标题/卡片 title+type+details keys/Resync/Edit/Delete/底部 hint）；URL 直连 `#/nc/:baseId/settings/syncs` 渲染正常 ✓；无 Nuxt error overlay ✓
- **editor UI 隔离**：侧栏无 Manage Syncs 菜单项（菜单集合 Members/MCP Server/General）；直连 URL 无 `.nc-base-syncs`、无 Resync 按钮 ✓。顶栏可见 "Manage Syncs" span = 已知非问题沿袭（上游框架页头）
- **App Sync 隔离**：base Integrations tab 无 App Sync / Add Connection 入口（body 文本断言）；三消费组件依赖的 `isSyncFeatureEnabled=false` 未翻 ✓
- **回归 smoke**（自建 base 上）：F02 permissions 200 / F05 variables 200 / F07 snapshots 200 / F08 base meta 200（is_snapshot 字段在）/ F10 dashboards 200 ✓
- **质量门**：`tsc --noEmit` exit 0；jest **41/41**（3 suites，含 F09 新增 table-syncs.Fork.spec.ts，比 R1 时 26 多为 F09 增量，全绿）✓

## observations（非 error）

1. **stale 行 resync 的 POST 响应延迟**：UI 实测删除行后点击 Resync，POST ~10s 才返回终态（repro 中同请求秒回 404；差异疑为当时后端负载/中间件链），期间行显示 optimistic "Syncing…"、按钮 loading——锁语义正确（未提前解锁），终态无残留。不影响判定，记录备查。
2. **watchdog FAILED fallback 文案恒泛型**：实测再现 "Sync failed"（`job.result?.error?.message` 恒空 → fallback）——已知非问题沿袭（上游 setJobResult 零调用，R3 清单）。
3. 90s timeout 路径本轮未重演（代码审 + R3 实测沿袭），见 R5 增量 2 表。

## 流程记录

- `f03r3-owner` 登录互踢实测应验（并发 lane 共用致 token_version 失效，两次 401）：bootstrap 全部收进单 signin 窗口执行；lane 自身账号 `f05r5l5-*` 全程专属无互踢。注意：同账号 **UI 登录也会踢 API token**（本次 UI 登录 f05r5l5-owner 后其 API token 401）——后续轮次账号内 UI/API 混用时应改走浏览器内 fetch。
- 未动 dev-backend*.sh / 未 pkill / 未重启后端；8080 全程健康（未触发轮询路径）。
