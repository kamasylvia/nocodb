# F09 P2 R2 修复回归 — lane 2 报告（账号 f09p2r2l2-*，camoufox session f09p2r2l2）

**结论：PASS — 0 error + 0 minor**

基线 HEAD = 366e0b7045（R1 修复批）。:8080 活体核验：进程 pid 33253（01:24 启动）晚于 dist mtime（23:39），dist 含修复批独有标记 `Failed to create mirror column for`（E4 fail-fast，仅修复批存在）——运行代码 = 修复后代码。前端 :3000 HMR 即当前源码。R1 五 error（E1/E2/E3/E4/M1+M3）全部活体复测通过，P1 全矩阵回归通过。测试数据全 `f09p2r2l2-` 前缀，已全部删除（0 残留）。

## 1. E1+E2 paste 建同步（R1：双路必 400）—— **PASS**

对齐前端实发形态（`CreateNewSync.vue` paste 分支不传 sourceTableId）：

- `POST /table-syncs {sourceInputMode:'paste', sharedViewUrl:<uuid>}`（**无 sourceTableId**）→ **200**，sync `tss54ws29m9k0q47c` 建立，job 启动 → status active、last_error null
- 镜像表 `me4k34v9voqgpjm`：Title/Qty/Note readonly:true + RemoteId/RemoteDeleted system:true
- 引擎拉数：3 行全进（row1/2/3 + Qty 10/20/30 + Note）
- 映射落库：`source_uuid = 6e9724e7-…`（uuid 持久化）；无密码故 `source_password_hash = null`（正确）
- R1 症状（无 sourceTableId → "Shared view not found"；带 → "no syncable columns"）双消
- 静态复核：paste 分支统一 `srcContext = {workspace_id: view.fk_workspace_id, base_id: view.base_id}`，`Model.get(srcContext, view.fk_model_id)` + `getColumns(srcContext)`（service.ts:462-478）——sourceTableId 参数不再参与匹配（前端不发送，静默忽略可接受）

**密码版全链**（R1 E-blocked 补测）：视图设密 → 无密码 createSync 400「This shared view is password protected」/ 错密码 400「Invalid shared view password」/ 对密码 → 200 `tsseslwbsmh0pacb9`；映射 `source_password_hash = $2a$10$Xlit3oos…`（bcrypt，明文 `f09p2r2l2-pass1` 在库值 grep 0 命中）；job 完成 5 行全拉。

## 2. E3 减字段（R1：500 undefined binding + 半态）—— **PASS**

干净样本 sync1（初始 null 全字段）：

- `PATCH selected_fields:["Title"]` → **200**（R1：500 `Undefined binding [id]`），selected_fields 持久化 `["Title"]`，status active 无错
- 镜像列清单：Qty、Note **消失**，Title 保留 → 列删腿生效
- 减后 resync 200 → 数据对齐（仅 Title 列 + 4 行）
- 静态复核：映射删除改按 `(fk_table_sync_id, source_column_id)` 键控（service.ts:902-908），不再依赖 listColumnMappings 未 select 的 `id`；`TableSync.ts:211-224` 语义注释同步

## 3. E4 增字段数据永不同步（R1：dest_column_id 落 model id）—— **PASS**

同一 sync1 减后回加：

- `PATCH selected_fields:["Title","Qty"]` → 200；Qty 列重现且 **readonly:true**（metaUpdate 强制通道生效）
- **决定性断言**：resync 后 Qty 数据真实进——row1-edit/10、row2/20、row3/30、row4/40 全对齐；**插入路径**复测：源加 row5(Qty 50) → resync → 镜像 `{Title:"row5", Qty:50}`（R1 lane5 曾证此路径永 null）
- `[]` → 400、`null` → 200 语义保持
- 静态复核：增腿 `columnAdd` 返回的 Model 上按 title 从 `.columns` 取实际列 id，取不到 fail-fast 400（service.ts:916-934）

## 4. resolveLink 密码保护（R1 lane5 M1：标题泄露）—— **PASS**

设密视图三态：

- 无密码 resolve → **仅 `{"passwordProtected":true}`**——sourceTableTitle/sourceViewTitle/sourceBaseId 零泄露（R1 泄露实锤已消）
- 错密码 → 400「Invalid shared view password」
- 对密码 → 全量坐标（sourceBaseId/sourceTableId/sourceViewId/双 title/passwordProtected:false）
- 静态复核：sourceSchema paste 分支同批一致（无密码只返 `{passwordProtected:true}`，错密码 400——`if (!ok) NcError.badRequest` 在 a4959c27cd 已存在，lane1 M1 表述与源码不符，现状两分支行为一致）

## 5. M3 菜单守卫（R1 lane5 M3：Syncing 态可点 Convert/Delete）—— **PASS（UI 双态活体）**

400 行大表 mirror-big（sync `tss94508ndhx70xwd`）制造可观测 Syncing 窗口，API 后台触发 resync，UI 即时打开树菜单（菜单 open 时 `load()` 拉新 status，SyncMenuOptions.vue:46-49）：

- **Syncing 态**：菜单仅 Rename/Change icon/Duplicate/Edit description/Edit permissions + 「Syncing」徽标——**`table-sync-menu-convert` 与 `table-sync-menu-delete` 节点不存在**（v-if 生效）。截图 `shots/m3-syncing-menu-hidden.png`
- **完成后对照**（job 完 704 行，status active）：菜单出现 Synced table / Sync now / Pause sync / **Convert to regular table** / **Delete sync**。截图 `shots/m3-active-menu-convert-visible.png`
- 静态复核：两 NcMenuItem 均加 `v-if="sync.status !== TableSyncStatus.Syncing"`（SyncMenuOptions.vue:160-181）

## 6. P1 全矩阵回归 —— **PASS**

- **E1 六格（角色 × 模式 create 矩阵）**：owner-browse 200（`tssdac4mzn2pv9mow`）/ owner-paste 200（sync1/2）/ editor-browse 403 / editor-paste 403 / **无关系用户-browse 404**（f09p2r2l2-ui 无 src base 关系，create + source-schema 均 404，不泄露）/ 无关系用户-paste 200（uuid+allow_sync+密码 = 设计授权通道，`tss9gt05ubkqfepry`）
- **ACL 十端点**（editor f09p2r2l2-e on dest）：list/get/source-schema/create×2/update/delete/resync/freeze/resume/detach/resolve-link 全 **403**；匿名 list/resolve 全 **401**
- **引擎 e2e（browse sync）**：full-create 5 行 → RemoteId 键控（1-5）；源改 row1-edit → resync upsert 进镜像；**delete 策略**：源删 row3 → 镜像硬删；**mark_deleted 策略**：源删 row6 → 镜像保留 `RemoteDeleted:true`；freeze → status paused + resync 400「Sync is paused. Resume it before syncing」→ resume → active + resync 200；deleteSync → 200 + sync 404 + 镜像 meta 404
- **paste 不复检 base 权限 resync 面**（R1 E-blocked）：无源权限用户（ui）对自建 paste sync resync → **200**，镜像与源对齐（行集 row1-edit/row2/row5 一致）
- **守卫链**：editor 写镜像 readonly 列 400「Column "Title" is readonly column and cannot be updated」；editor columnUpdate 403；**系统列网格不可见**：mirror-big 网格仅 Title 列 + 行号（RemoteId/RemoteDeleted 不可见，截图 `shots/ui-grid-state.png`，704 records）
- **付费锁**：`syncTrigger:"realtime"` → 400「Only the manual sync trigger is supported (automatic sync is not enabled)」
- **detach 回归**：sync2（密码 paste）detach → 200、getSync 404、synced:false、Title/Qty readonly:false、PATCH 记录 200（可编辑）；UI 树中 detached 表显示常规表图标（与 active 镜像闪电标对照，见 `shots/wizard-paste-created.png` 树区）
- **UI 向导 paste 全流程活体**（E1/E2 用户前门）：NocoDB Sync 卡片 → Paste link 单选 → 填 uuid + 密码 → Next（resolve+loadSchema 过）→ Fields 步（All fields 默认）→ Create sync → 模态关、树新增镜像 `f09p2r2l2_src_tbl`（闪电标）→ API 侧 status active + 数据 3 行对齐。截图 `shots/wizard-paste-created.png`

## 7. 质量门 —— **全绿**

- `tsc --noEmit`（packages/nocodb）exit 0
- jest Fork 桶（testRegex Integration|Source|Fork）：**3 suites / 41 tests 全过**（165s）
- Vite URL 编译检查：`CreateNewSync.vue` 200 + `SyncMenuOptions.vue` 200（:3000 dev server）

## 8. 观察项（不计 error/minor）

1. **create/update 字段命名不对称**：create 收 camelCase `onDeleteAction`，update 白名单只认 snake_case `on_delete_action`（controller 类型即如此声明）；发 camelCase PATCH 会 200 静默 no-op（响应体可看出未生效）。实测教训：本轮首次 PATCH `{"onDeleteAction":"mark_deleted"}` 即踩中。上游 SDK 类型为 snake_case，非本 fork 引入的破坏；建议后续统一或在 update 拒绝未知键。
2. **resync 端点响应体回显完整 job data**（含 req.rawHeaders 中调用者自己的 xc-auth）：仅泄露给调用者本人，P1 已知面，语义未定。
3. **paste sync 源视图后设密码**：已建 sync 持久凭证仍有效（resync 未复验 source_password_hash）——R1 lane5 同项观察，EE 语义未定，规格未要求。

## 9. 结论

| R1 项 | R2 状态 | 证据 |
|---|---|---|
| E1 paste 缺 sourceTableId 400 | 修复 ✓ | §1 活体 200 + 引擎拉数 |
| E2 paste getColumns dest context | 修复 ✓ | §1 活体（镜像列/数据/映射全对） |
| E3 减字段 500 + 半态 | 修复 ✓ | §2 活体（200/列删/映射删/resync 对齐） |
| E4 增列 dest_column_id 落 model id | 修复 ✓ | §3 活体（Qty 10/20/30/40 + row5 插入路径 50） |
| M1 resolveLink 标题泄露 | 修复 ✓ | §4 三态活体 |
| M3 Syncing 态菜单未藏 | 修复 ✓ | §5 双态截图 |

**0 error + 0 minor → PASS**。修复面（commit 366e0b7045）与 R1 裁决逐项对应，未引入回归；P1 矩阵与 P2 其余面（detach/漂移修复外围/灰区复检/原子清理静态面）无新异常。

## 证据索引

- 截图：`/tmp/f09p2r2l2/shots/`（m3-syncing-menu-hidden.png = M3 Syncing 态；m3-active-menu-convert-visible.png = 对照态；wizard-paste-created.png = 向导建后树态 + detach 图标对照；ui-grid-state.png = 704 行网格 + 系统列隐藏）
- 脚本与凭据（lane 自建）：`/tmp/f09p2r2l2/`（env.sh、tok-*、create*.txt、sync*.json）
- 测试资产：src base `pf8v1n4k1bidbng`、dest base `pdno5o5o7y8fsfy`、syncs `tss54ws29m9k0q47c`/`tsseslwbsmh0pacb9`/`tssdac4mzn2pv9mow`/`tss9gt05ubkqfepry`/`tss94508ndhx70xwd`/`tssayz3tncyshtk8p`——**已全部删除**（3 个 deleteSync 200 + 双 base delete 200，bases 列表 grep 前缀 0 命中）；账号 f09p2r2l2-api/ui/e 留存（与历轮惯例一致）
- 隔离声明：仅读 r2-p2-lane-prompt.md、r1-p2-lane-prompt.md、f09-p2-impl-report.md、r1-p2-lane1.md、r1-p2-lane5.md、r3-f09-lane-prompt.md（任务书与指定历史报告），未读任何他路 R2 报告
