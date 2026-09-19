# F09 P3 R3 lane5 审查报告（UI 验证重点路，2026-09-20）

**结论：PASS（0 error + 0 minor；1 观察级注记）**

- 审查员：lane5（f09p3r3l5-* / camoufox session f09p3r3l5，已关）
- 基线：5d25acfc51（R2 修复批）= HEAD，工作树零 diff；:8080 = pid 75970（02:21 启动，晚于 dist mtime 02:10），dist 内 grep `P3-R2(lane4 E1')` = 1 处（sweep 修复在跑的是修复后 dist）；前端 :3000 Nuxt dev。全程零构建/零重启/零 psql。
- 测试数据：`f09p3r3l5-` 前缀。src base pxix7yrilp082dc / dst base p6va3r8smtfeh8i、sync ×2（tssmta03htvjbaeub realtime、tsszjg7srt6facltr manual）——两 base 已删，infra 视角 bases 列表复查 **f09p3r3l5 残留 NONE**；我名下两个 sync id 日志 `run failed`/`catch-up enqueue failed` = **0**。账号 f09p3r3l5-api / f09p3r3l5-ui / f09p3r3l5-ed @example.com（密码 Xc9!vR3tQw7#pLm5）**保留供后续轮次**（R2 lane5 先例）；api=owner×2、ui=owner×2、ed=editor×2，随 base 删除自动脱离。
- 截图存证：/tmp/f09p3r3l5/（wizard-step1-dual / wizard-step3-settings / menu-active / menu-paused / menu-syncing-live / convert-confirm-modal / delete-sync-modal / owner-overview-card / editor-overview-redirect 等 13 张）

---

## 0. R3 重点回归主结论（先立后破）

### 0.1 Convert 确认弹窗（R2 lane5 minor 修复回归）——**全链 PASS**

修复体：`SyncMenuOptions.vue:38` `isConvertConfirmOpen` + `:176` 菜单项改置 open + `:227-251` NcModal（Cancel `table-sync-convert-cancel` / Convert `table-sync-convert-confirm`）。Vite 产物（`/_nuxt/@fs/` 200 text/javascript）内 convert 标记 8 处——跑的即修复产物。

| 腿 | 活体证据 | 结果 |
|---|---|---|
| 菜单 Convert → 弹窗出现 | convert-confirm-modal.png：标题 + Cancel / Convert to regular table 双按钮，data-testid 齐全 | ✓ |
| Cancel 不动作 | 点 Cancel → 弹窗关、sync GET 仍 200 | ✓ |
| Esc 不动作 | 弹窗开 → Esc → 弹窗关（modalAfterEsc=false）、sync GET 仍 200 | ✓ |
| Convert 转正生效 | 点 confirm → sync GET **404**、表 meta `synced:false`、镜像 insert（post-detach-writable）**200 可写** | ✓ |

### 0.2 E1' sweep 修复回归（R2 四路同判 error 的 UI 驱动重演）——**两窗口 delete 腿全收敛，ghost 零复现**

**paused 窗口（R2 E-lane5-1 同场景决定性重演）**：
1. UI 树菜单 Pause sync → status=paused（API 实证）。
2. 窗口内源表三写全 200：update Id=1→`pa3-upd`、insert `pa3-ins`、**delete Id=5（seed-a5）**。
3. 窗口内镜像冻结 5 行旧态 ✓（paused 不泄漏）。
4. UI 树菜单 Resume sync（菜单三态：paused 态 Resume 替换 Pause，menu-paused.png）→ 日志 `enqueued watermark catch-up run jobmg8cuv1028yd8e` → catch-up `[incremental]: source rows=5 inserts=1 updates=4 deletes=1` —— **deletes=1 出现**（R2 时代此处恒 deletes=0，sweep 生效的直接日志证据）。
5. 镜像终态 5 行 = `pa3-upd` ✓ + `pa3-ins` ✓ + **seed-a5 消失 ✓**——R2「update/insert 补齐、delete ghost 残留」症状零复现，任务书「三写全部追平（含 delete 腿）」达成。

**Syncing 窗口（resync 中三写）**：
- 扩表（bulk 800 + 500×7 批）至 4804 行 → API resync 200 → run 在飞期间源表 delete Id=4（seed-a4）+ update Id=2→`win-upd-a2` 全 200。
- 日志：`[full-resync]: rows=805/4804` → run 一结束 `enqueued watermark catch-up run jobv0wnuggmtgskaf` → 补齐 `[incremental]: rows=804 ... deletes=1`。
- 镜像终态：seed-a4 **消失**（ghost 清除）、win-upd-a2 进、status 回 active，零发散。

### 0.3 树菜单三态 + Syncing 守卫（UI 活体）——**PASS**

- **active**：Synced table 标签 + Sync now / Pause sync / Convert to regular table / Delete sync 全项（menu-active.png）。
- **paused**：Resume sync 替换 Pause，其余在位（menu-paused.png）。
- **syncing**：4804 行 resync 拉长窗口，菜单打开时活体捕获——`[data-testid=table-sync-menu-status]` 文本 = **Syncing**，menuitem 仅剩 5 个非 sync 项（Rename/Icon/Duplicate/Description/Permissions），**Sync now/Pause/Convert/Delete 全部隐藏**（menu-syncing-live.png，与 `SyncMenuOptions.vue:123/:173/:185` 的 `status !== Syncing` 守卫一致）。捕获探针教训见 §3。

---

## 1. PASS 面（P3 站位继承，全部实测/截图/API 复核）

**质量门**：`npx tsc --noEmit` exit 0；jest Fork 桶 **44/44**（3 套件，table-syncs.Fork.spec.ts 101s）；Vite URL 编译法 4/4 = 200 text/javascript（CreateNewSync.vue / TreeView/Table/SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts）。

**向导双模式（UI 活体）**：
- Browse/Paste 双 radio 在位（wizard-step1-dual.png）；Browse 三步流（源 base→表选择 → 字段 → Sync settings）完整走通。
- **allow_sync 前置守卫活体**：源表无共享视图时向导显示 `Let other bases sync data from this view` 提示且 Next disabled（`CreateNewSync.vue:319-321` + `:408-414` `!schema?.view`）；API 开启 `allow_sync:true` 后重开向导 Next enabled——守卫链双向实证。
- **Automatically/Manually 双档** + 删除策略双档（Deleted 默认/Retained）在位（wizard-step3-settings.png）；选 Automatically 建成 `sync_trigger:'realtime'`、on_delete_action=delete（API 落库实证）+ 镜像 5 行种子。
- **paste 模式**：shared view URL 填入 → Next 解析（后端 resolve-link 200：sourceBaseId/TableId/ViewId 正确回填）→ 三步建成 manual sync（FsrcM）✓。

**E-bulk 修复回归（附带站位）**：源表数组体 POST 800 行 → 日志**恰一条** `enqueued incremental run (insert, 800 ids)` → 镜像 ~10s 内 800 行全进（where 抽查 bulk-w799 命中）。R1 症状零复现。

**Manual sync P1 行为不变**：源 insert `manual-x` 后 5s 镜像无此行（不跟随）✓；UI 树菜单 Sync now → `[full-resync]` run → manual-x 追平 ✓。

**删除流三腿（UI 活体）**：
1. Delete sync：确认弹窗（表名 FsrcM 明示 + Cancel/Delete sync，delete-sync-modal.png）→ 确认 → sync 404 + **镜像表 404** ✓
2. Convert：§0.1 全链 ✓
3. Pause/Resume：§0.2 ✓

**editor Overview 卡 gate（UI 活体，双层）**：
- owner（ui 登录态）：`/#/nc/:baseId/overview` → NocoDB Sync 卡 **VISIBLE**（owner-overview-card.png）✓
- editor（ed 登录态）：直达 `/#/nc/:baseId/overview` → **重定向回表视图**（终 URL `/w9qi3ljd/.../fsrc-fsrc`），Sync 卡不可见（editor-overview-redirect.png）✓

**UI/API 账号分离**：UI 流全程 f09p3r3l5-ui / f09p3r3l5-ed 登录态驱动；API 写/断言走 f09p3r3l5-api（xc-auth），符合纪律。

---

## 2. Minor / 观察级

- **观察 O1（不计修）**：向导建成 sync 后，树节点菜单的 sync 操作项可能不出现（菜单仅 Delete table），直到 tables store 重载（页面 reload）——树 `table.synced` 标志在创建回调路径上未即时进入 store；`SyncMenuOptions` 的 `v-if="table.synced"`（Node.vue:858）门在旧 store 值上不渲染。与 R5 修复的「dropdown overlay keeps mounted 状态冻结」同族但不同点（那是 sync 记录冻结，这是树元数据滞后）。reload 后完全正常、不阻断、无数据风险；建议后续在建 sync 成功回调里补一次 `loadTables()` 顺带修复。注：Browse/paste 两模式未分别标定（sync1 建成后我也执行了 reload，即时不成立性无法归因到单一模式）。
- **API 上界注记（非缺陷）**：v2 records 单次数组体 POST 1500 行 → 422，500 行 200——bulk 有单请求上限（~500-1000 行级），大表场景分批即可。

---

## 3. 方法学注记（供裁决）

- **Syncing 菜单捕获探针两代**：初版只过滤 `[role=menuitem]`，Syncing 态输出 `[]`（statusLabel 是 `span[data-testid=table-sync-menu-status]` 非 menuitem）——该 `[]` 形态本身就是「sync 操作项全隐藏」的证据（try2-5 恰落在大 catch-up 与 full-resync 的 syncing 窗口内），二版探针直读 status span 定格 `Syncing|items=5` 并截图。教训与 R2 lane3「探针缺陷≠产品回归」同款。
- **Shared view 前置**：Browse 模式要求源表已开 allow_sync 共享视图（UI 提示 + Next disabled 引导）；本轮经 API `POST /api/v2/meta/views/:id/share` + `PATCH {allow_sync:true}` 预置（R2 同款），非绕过——提示文案与守卫行为本身即活体验证对象。
- **token 时序坑**：同账号后登录会使先前 API token 失效（NocoDB token_version 机制）——UI 登录 ui 账号后 ui 的 API token 作废；API 断言改走 api 账号即规避。非产品缺陷。
- 新注册用户 org-level-viewer 无 baseCreate——沿用 R2 lane3 模式：infra 账号（f01e2e@ce-ee.local）建 base + 邀请本 lane 三账号入角色组。
- 共享 :8080 多 lane 流量；日志断言均按我名下 sync id（tssmta03htvjbaeub / tsszjg7srt6facltr）归因。
- 未覆盖（他路站位 / 非本轮焦点）：Retained（mark_deleted）策略在窗口补齐下的行为（R2 lane5 未覆盖遗留，本轮同样未跑——base 已清，可下轮补）；paste resync hash 复验（已知遗留豁免）；多 worker 补齐（单实例不可构造）。
