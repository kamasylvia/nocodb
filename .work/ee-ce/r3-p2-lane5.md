# F09 P2 R3 — lane 5（UI 验证重点路）报告

**结论：1 error + 0 minor** — 唯一 error 为 editor「NocoDB Sync」动作卡可见（Overview.vue 无角色 gate，P1 起即此形态；后端 ACL 403 兜底在活体验证）。paste 向导全流程、树菜单三态翻转、Syncing 守卫（Convert/Delete 隐藏）、删除流三腿、detach 转正、API 全链回归、质量门全过。

基线 366e0b7045（HEAD=7db46fce29 仅多 dispatch chore，零代码变更）。审查时间 2026-09-19 凌晨，后端 :8080 = pid 33253 运行 dist（mtime 23:39，P2+R1 修复特征 5/5 命中：sourceInputMode×4 / sharedViewUrl×5 / passwordProtected×7 / bypassSyncedFieldGuard×4 / detach×22）。

## 0. 环境与账号

- f01e2e@ 仅作基础设施（建 4 base + 邀请），lane 资源全 `f09p2r3l5-` 前缀：SRC base（源表 3 列 3 行 + grid view allow_sync+密码）/ D1（api owner，API 抽测）/ D2（ui owner，UI 活体 + editor 邀请）/ D3（空 base，editor 入口验证）
- 账号 f09p2r3l5-api / -ui / -e（UI/API 分离）。实测机制备忘：**浏览器 signin 与 API signin 互踢**（token_version 单一轮换）——UI 账号 API token 每次浏览器登录后需重新 signin
- camoufox session `f09p2r3l5` 专属，全程未动 default

## 1. UI 活体：向导 paste 全流程 —— 过

D2（ui 账号）base home → 「NocoDB Sync」卡 → 向导：
- step0：Browse [checked] / Paste link 单选在位；切 Paste → URL 输入框现、**密码框随 URL 非空才出现**（`v-if="sharedViewUrl"` ✓）、Next 未填时 disabled
- 填共享 URL（`/nc/view/14740851-…`）+ 密码 → 截图 `wizard-step0-paste.png` → Next
- resolve → loadSchema → step1（All fields 默认选中，Back/Next body 渲染可点）→ step2（title 预填源表标题、删除策略单选）→ **Create sync 200**
- 落点：sync active + 镜像表 synced:true（API 双验）；grid 活体 `mirror-grid.png`：**3 records（row1/2/3）数据全**、列头 readonly 锁标、New record disabled（synced 守卫）

## 2. UI 活体：树菜单三态 + Syncing 守卫 —— 过（R1 M3 修复回归实证）

- **Active 态**（`menu-active-state.png`）：Synced table 徽标 + Sync now / Pause sync / Convert to regular table / Delete sync 全项；常规组同屏；**无 Delete table**（`!table.synced` 隐藏 = 删除流腿 C）
- **Paused 态**（`menu-paused-state.png`）：点 Pause sync → 重开菜单即翻转 **Resume sync**（无需 reload——R5 watch open→load 修复在位）；Resume 回 Active 验证
- **Syncing 态**（`menu-syncing-race.png`）：Sync now 点击后立即重开菜单，竞态捕捉成功——状态行「Syncing」，**Sync 组四项全部消失**（Sync now/Pause/Convert/Delete 均无，仅剩常规组）= R1 M3 修复（`v-if="sync.status !== Syncing"` ×4）活体回归 ✓
- 后端守卫同批抽测：resync while Syncing → 400（jest Fork 桶断言在跑）

## 3. UI 活体：删除流三腿 —— 过

- **腿 A｜Delete sync**（`delete-sync-confirm.png` + `after-delete-sync.png`）：确认弹窗（sync id — 表名 + Cancel/红色 Delete sync）→ confirm → 树中镜像表消失（进 trash）+ **redirect 到剩余表 f09p2r3l5_src_tbl**（R6 修复 redirect 腿活体回归 ✓）
- **腿 B｜Convert to regular table**（`after-convert.png`/`after-convert-reload.png`）：树节点闪电徽标消失；转正表数据 3 行保留、**列头锁标消失、New record 变可用**（插行可编辑）；菜单翻转为常规组
- **腿 C｜Delete table 项翻转**（`converted-menu.png`）：synced 表菜单无 Delete table → 转正后菜单出现 Delete table、Sync 组消失（对照 `menu-active-state.png`）

## 4. UI 活体：editor 三入口 —— **1 error**

- **入口 1｜Overview 动作卡 —— error：editor 可见**（`editor-d3-home.png`）：editor 打开空 base D3，动作面板仅渲染「NocoDB Sync Mirror a shared view…」卡（Create New Table / Import Data 卡因 `isUIAllowed('tableCreate')` 正确隐藏，反证面板 role 管线正常）。**`Overview.vue:134-137` 此卡唯独无角色 gate**（`v-if="!isMobileMode && !blockTableSync"`，相邻卡全带 isUIAllowed）→ editor 点卡可开向导（`editor-d3-wizard.png`），paste resolve → **403 toast "Forbidden … roles: Editor"**（`editor-d3-resolve-toast.png`，后端 ACL 兜底活体实证，无数据可建）
  - 归因：gate 形态 71896a841f（P1 实现批）即如此，**非 P2 新回归**；但按 P1 R3 清单第 7 条「editor 三入口不可见」字面属违反，R3 独立实测报 error。修复面极小：卡补 `isUIAllowed('tableCreate')` 或 `!isUIAllowed(...)` 同源角色判定（或 orchestrator 裁决口径若以「ACL 兜底 + 无操作入口」为准可降 minor——实测证据均在案）
- **入口 2｜树 synced 表菜单 —— 不可见 ✓**（`editor-d2-tree-menu.png`）：editor 对 D2 镜像表开三点菜单，仅 TABLE ID 头面板，**Sync 组整块不渲染**（useTableSync load 403 → sync=null → `v-else-if="sync"` gate 生效）
- **入口 3｜Share 模态 allow_sync 开关 —— 不可见 ✓**（`editor-d2-share-modal.png`）：editor Share 模态仅「Share View / Enable Public Viewing」简版（View.vue 路径），无 allow_sync 区块；owner 版 SharePage.vue 才承载该开关
- 附带守卫抽测：editor 对 synced 表 New record disabled（`editor-d2-tree-menu.png` 同屏）

## 5. API 侧回归抽测（D1，api owner 账号；全过）

| 断言 | 结果 |
|---|---|
| resolve 无密码 → `{"passwordProtected":true}`（R1 M1 修复回归，零标题泄露） | PASS |
| resolve 对密码 → 全量坐标（base/table==SRC）；错密码 400 | PASS |
| createSync paste（无 sourceTableId，对齐前端形态）→ 200（R1 E1/E2 回归） | PASS |
| mapping 落 `source_uuid`=uuid 本体 + `source_password_hash` 键存在（明文不落库） | PASS |
| paste resync（无源 base 权限，持久凭证）→ 200 行数 3 | PASS |
| updateSync 减列 → 200 无 500 + 列删（R1 E3 回归）；null 全字段 → 列重建 + resync 后 Note 数据 3/3（R1 E4 回归） | PASS |
| detach → 200 / getSync 404 / synced:false | PASS |
| ACL：editor 五端点（list/resolve/resync/detach/delete）全 403 | PASS |

## 6. 质量门 —— 全绿

- `tsc --noEmit` exit 0
- jest Fork 桶：**3 suites / 41 tests 全过**
- Vite URL 编译强验（`/_nuxt/@fs/` 模块路径）：CreateNewSync.vue 200 + SyncMenuOptions.vue 200，均返回真实编译产物（createHotContext JS），非 html fallback

## 7. 结论与计数

| # | 级别 | 一句话 | 位置 |
|---|---|---|---|
| E1 | error | editor 对「NocoDB Sync」动作卡可见（无角色 gate），可开向导至 resolve 403 兜底；按 P1 R3 清单「editor 三入口不可见」报违反 | Overview.vue:134-137（P1 批 71896a841f 即此形态，非 P2 回归） |

R1 五 error（E1/E2/E3/E4 + paste 链路）修复回归全过（UI + API 双面）；R1 M1/M3 修复活体回归实证；R1 M2（漂移当轮 cast）与 M1 尾项未复打（R2 已闭环，站位轮不重开）。

## 证据索引

- 截图：/tmp/f09p2r3l5/shots/（wizard-step0-paste / wizard-step1-fields / mirror-grid / menu-active-state / menu-paused-state / menu-syncing-race / delete-sync-confirm / after-delete-sync / after-convert / after-convert-reload / converted-menu / editor-d3-home / editor-d3-wizard / editor-d3-resolve-toast / editor-d2-tree-menu / editor-d2-share-modal）
- 脚本：/tmp/f09p2r3l5/（setup.sh、t1.sh、env.sh）
- 质量门日志：/tmp/f09p2r3l5-tsc.log、/tmp/f09p2r3l5-jest.log

## 清理

4 个测试 base（SRC/D1/D2/D3，全 `f09p2r3l5-` 前缀）经 f01e2e 软删 200，base 列表残留 0；lane 账号 3 个留存（f01e2e 基建模式惯例，含测试口令不入仓）；camoufox session f09p2r3l5 已 close。
