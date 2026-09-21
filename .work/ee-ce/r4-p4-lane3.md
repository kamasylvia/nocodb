# F09 P4 R4 — lane 3（安全审计重点路）报告

**结论：PASS / 0 error + 0 minor**

审查基线 = 840c4218aa（R2 修复批）；HEAD = 8431d4ed8c，其与基线之间**仅一个 chore(work) 流程件提交**（r3-p4-lane-prompt.md），零代码功能变更——与任务书「R3 后仅 i18n/注释清理与流程件」一致（i18n/注释清理在 8de55d0b24，属基线内，已核）。后端 :8080 存活（pid 38535，`GET /api/v1/health` → 200），dist 双条件核验：dist mtime 2026-09-22 01:34:28 < 进程启动 01:41:12 ✓，且运行 dist（`~/.nocodb-run`）grep 命中守卫特征串（`manage the links in the source table` ×2、`ERR_SYNC_TABLE_OPERATION_PROHIBITED` 族 ×7）→ **:8080 运行的确含 R2/R3 修复**。账号前缀 `f09p4r4l3-*`（owner/editor/ui 三账号，API/UI 分离）；camoufox session `f09p4r4l3`。脚本：`.work/ee-ce/f09p4r4l3-run1.sh`（v3 守卫活体，ALL PASS）、`f09p4r4l3-run2.sh`（安全面活体，ALL PASS）、`f09p4r4l3-run3.sh`（updateSync 级联 + 窗口收敛活体，ALL PASS）、`f09p4r4l3-ui-setup.sh`（UI 环境）。

## E 系列

无。

## M 系列

无。（R3 两条 minor 均已消：M1 zh-Hans `labels.convertToRegularTable` 由 8de55d0b24 落键，本轮 11/11 键静态闭环核验；M2 维持项中 spec 用例不在本批范围，见「已知遗留维持」——不新增、不升级。）

## R3 小修验证（任务书第 2 条，通过）

1. **zh-Hans `labels.convertToRegularTable` 弹窗全中文**（8de55d0b24 已落）：
   - 静态：zh-Hans.json:1432 `"convertToRegularTable": "转换为普通表"`（en.json:1890 对应）；SyncMenuOptions.vue 三处引用（菜单行/弹窗 title/确认文案）。
   - **弹窗全中文闭环**：SyncMenuOptions.vue 全部 11 个 i18n 键逐一对照 zh-Hans.json —— `general.cancel`（取消）/ `general.loading`（加载中）/ `labels.convertToRegularTable`（转换为普通表）/ `labels.deleteSync`（删除同步）/ `labels.errored`（错误）/ `labels.freezeSync`（暂停同步）/ `labels.paused`（已暂停）/ `labels.resumeSync`（恢复同步）/ `labels.syncedTable`（同步表）/ `labels.syncing`（正在同步）/ `labels.syncNow`（立即同步）——**11/11 全命中，无 English fallback 残留**。
   - 活体：dev 前端（:3000）ui 账号经 `nocodb-gui-v2` localStorage lang=zh-Hans 切换成功，页面渲染全中文（数据/详细信息/分享/字段/筛选/分组/排序/新增记录）。编辑器树节点下拉无 SyncMenuOptions（owner-gated，与 R3 分工一致，弹窗渲染走查归 lane5 owner 会话；键级证据已闭环）。
2. **processor/realtime 注释腐化清理无新问题**：table-sync.processor.ts 与 table-sync-realtime.ts 的 watermark/sweep/CAS 注释逐一读毕，与现行实现一致（status 无预滤 → CAS miss → markSkippedDuringSync → catch-up 全量 pass；junction raw-knex 不 tap；role IN (main, linked_shadow)）；无 `watermarkStart` 死导出残留。

## 安全面（run2 活体，全部通过；静态复审同批闭合）

1. **paste 凭据面**：sourceSchema password gate 生效（无密码 → `{passwordProtected:true}`；错密码 → 400 Invalid shared view password）；paste schema **不列 link 列**（`columns=["Title","Qty"]`，源表实有 Lnk link 列被裁剪）；paste+link createSync → **400**，消息含 browse-mode 指引；paste 纯标量 createSync 成功不误伤。静态：sourceSchema 与 createSync 两处 password gate + createSync paste 分支 `syncableLinks` 经源 context 真实加载（P4-R1 lane3b E2 安全裁定注释在位：share 凭据是单视图暴露，link sync 会读相关表 → 400 路径可达非死代码）。
2. **响应凭据剥离**：createSync / GET sync 详情 / GET sync list 三响应均**零命中** `source_uuid` / `source_password_hash`。静态闭环：`TableSync.toType()` 白名单字段（sync 行级不含凭据列）+ `listSyncs`/`getSync` 对 mappings 显式 delete（F09 P2-R3 lane2 注释在位）。
3. **detach ACL**：editor 对 detach → **403**（五端点 ACL 全查见下）；owner detach → `{ok:true,tableId}`，mirror `synced=false` + 插行 200（三表转正可写语义）✓。静态：detach 路由 `@Acl('tableSyncDelete')`（table-syncs.controller.ts:193）。
4. **ACL 抽查**：editor 对 table-syncs list/create/resync/detach/delete 五端点 → **全 403** ✓。
5. **七 tap 防环**（静态）：BaseModelSqlv2 七个行事件 hook（afterInsert/afterBulkInsert/afterDelete/afterBulkDelete/afterBulkRestore/afterBulkUpdate/afterUpdate）+ P4 'link' funnel（updateLastModified 单漏斗，:9215）共 8 tap 位。防环闭合：tap 匹配 `TABLE_SYNC_MAPPINGS.source_table_id` = 源表 id 且 role IN (main, linked_shadow)，junction mapping 无 source_table_id 且写走 raw-knex（processor `dbDriver(destTn).insert` raw:true 通道）→ 引擎 junction 写**永不 tap**；引擎 mirror/shadow 写是 dest 表，不匹配自身 mapping 的 source_table_id → 自激励不成环。

## R3 全部验证项同规格复跑（任务书第 1 条）

### v3 LTAR 通道守卫（run1 活体，全部通过）

三层 sync（mirror+shadow+junction，full-create 后 junction 配对 = 2）：

| # | 断言 | 实测 |
|---|---|---|
| 1 | owner 对镜像 `POST/DELETE /api/v3/data/{baseId}/{modelId}/links/{colId}/{rowId}` | **422** `ERR_SYNC_TABLE_OPERATION_PROHIBITED` ✓ |
| 2 | **editor** 对镜像 v3 POST/DELETE（R2 原症状 200/201） | **422** 同上，不复现 ✓ |
| 3 | 拦截后 junction 配对数 | 仍 = 2，无部分写入 ✓ |
| 4 | 合法路径不误伤：owner 源普通表 v3 POST；editor dest 普通表 v3 POST/DELETE | 200 / 200 / 200 ✓ |
| 5 | 读路径：owner v3 GET 镜像 links | 200（返回 shadow 关联数据）✓ |
| 6 | v3 PATCH 镜像标量 | 400 `Column "Title" is readonly...`——P1 镜像列 readonly 既有语义，非守卫误伤 ✓ |
| 7 | 引擎通道无 bypass：源加配对 → resync | junction 2→3，raw-knex 通道照常回填 ✓ |
| 8 | P2 站位：editor junction 直写 / editor bulk 删镜像行 | 422 / 422 ✓ |

### updateSync 级联 + 窗口收敛（run3 活体，全部通过；本轮新增覆盖）

- **级联 a keep**：同 selectedFields PATCH → mapping 仍 ×1，结构不变 ✓
- **级联 b 加 link**：scalar-only sync PATCH 加 T2s → mapping ×1→**×3**（shadow+junction 生长），full-resync 回填 junction 配对 = 2 ✓
- **级联 c 删 link**：PATCH 移除 T2s → mapping **×3→×1** ✓
- **级联 d null**：全字段 PATCH → mapping 回 ×3 ✓
- **级联 e []**：空数组 PATCH → **400**（`selectedFields must be a non-empty array or null`）✓
- **freeze 守卫**：freeze → paused；paused 下 updateSync → **400**（Resume before updating）；resume → active ✓
- **窗口 delete 收敛档一**（on_delete_action=delete）：删源行 → resync → 镜像行 3→**2**（级联真删）✓
- **窗口 delete 收敛档二**（mark_deleted）：PATCH 切档 → 删源行 → resync → 镜像行仍 **2** 且 `RemoteDeleted=true` 恰 **1** 行 ✓

### P1-P3 站位（run1/run2 活体）

- **三层构建**：run1/run2/ui-setup 三次建 sync 均 main+linked_shadow+junction 三 mapping 齐、full-create 后 junction 配对精确（2）。
- **AUTO 双档**：realtime sync 建成 active，源插行 **~2s** 出现在 mirror（P3 realtime 链路无回归）；manual 档 resync 回填正常（run1 #7、run3 各级联 PATCH 后回填）。
- **守卫链**：junction 直写 422、editor 删镜像行 422（run1 #8）——P2 语义无回归。
- **UI 活体**：editor（ui 账号）打开 dest base——树菜单 sync 表条目可见（mirror `f09p4r4l3-uisync-*` + shadow `f09p4r4l3_w2`）；aria snapshot 抓到 **`button "New record" [disabled]`**（editor 对 synced 镜像 UI 卡 gate 真实 DOM 证据）；zh-Hans 全局渲染生效（见上节）。

## 质量门

- `npx tsc --noEmit`（packages/nocodb）：**exit 0**。
- `npx jest --testPathPattern 'Fork'`：**60/60，3 suites 全过**（202s）。
- Vite URL 门：`npx vitest run test/formula-url-xss.test.ts --config test/vite.config.ts --hookTimeout 60000`：**5/5 过**。

## 未覆盖（环境/范围限制，非「通过」）

1. zh-Hans convert 弹窗的 owner 会话渲染走查：SyncMenuOptions 为 owner-gated，editor 会话树节点无该下拉（行为正确）；静态 11/11 键闭环 + zh-Hans 全局渲染活体已覆盖 R3 小修验证点，弹窗动态渲染属 lane5 UI 分工（同 R3）。
2. 编辑器 UI 写路径 422 toast 展示：本轮 grid 在 dev 前端渲染同 R3 环境态，后端 422 与 editor gate 已由 API 活体 + aria disabled 按钮覆盖。
3. 删除用户账号：NocoDB 无删除用户 API，`f09p4r4l3-{owner,editor,ui}` 三账号保留（全前缀可辨，与历轮 lane 账号同惯例）。

## 已知遗留维持（不重复报，R4 任务书第 3 条）

i18n 死键 `msg.warning.syncPasteLinkUnsupported`；spec 缺 v3 通道用例；createSync 蛇形 `selected_fields` 不认；源 link 列删除孤儿；bulkUpdateAll 不 tap；paste resync 不复验 hash；afterBulkRestore CE 无调用方——本批零代码变更，各项维持 R3 判定，无恶化。

## 纪律

只读审查（`git status` 无源码改动；本 lane 仅新增 `.work/ee-ce/f09p4r4l3-*.sh` 脚本与本报告）；未构建/未重启/未 pkill/未跑 `dev-backend*.sh`；无 psql、未提权；隔离未读他路 R4 报告（对照材料 r4-p4-lane-prompt/r3-p4-lane-prompt/r3-p4-lane3 为任务书指定）；测试数据全部删除（清零核验：bases 列表 `f09p4r4l3*` 计数 = **0**，run1-3 经 trap 自清 + ui-setup 两 base 手动补删 200，测试记录行随 base 删除）；camoufox session 已 close；无凭证写入 git 跟踪文件（账号口令仅存于 `.work` 白名单脚本，遵循既有惯例）。
