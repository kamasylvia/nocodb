# F09 P2 R2 修复回归 — lane 3（安全审计重点路）报告

**结论:PASS — 0 error + 0 minor**。R1 五 error 修复逐项活体回归全过（E1/E2 paste 建同步、E3 减腿、E4 增腿进数、resolveLink 零泄露、M3 菜单守卫），安全三重点（凭据面/detach ACL/映射一致性）全绿，P1 全矩阵回归全绿。质量门 tsc 0 + jest Fork 桶 41/41 + Vite URL 双 SFC 200。测试数据（base×2 + 账号 f09p2r2l3-*）测完删除，零残留。

基线：HEAD 7db46fce29（R2 派遣批）= 修复批 366e0b7045 直子提交，工作树无源码改动。运行 dist：mtime 09-18 23:39 < 进程启动 09-19 01:24:06（pid 33253），P2+修复特征齐（sourceInputMode×4 / resolveLink×6 / bypassSyncedFieldGuard×4 / updateSynced×2 / detach×22 / sharedViewUrl×5 / passwordProtected×7）。前端 :3000 nuxt dev = 当前源码。camoufox session `f09p2r2l3`（已关闭；其余 f09p2r2l1/l2/l5 系他路 session，未触碰）。

## 1. R1 五 error 修复回归（逐项活体）

- **E1+E2（paste createSync）— PASS**：`POST /table-syncs {sourceInputMode:'paste', sharedViewUrl:<uuid>, sharedViewPassword:<对>}`（不带 sourceTableId，前端实发形态）→ 200 建镜像，full-create 拉源 3 行，Title 对齐 row1-3。R1 症状（无 id 报 'Shared view not found' / 带 id 报 'no syncable columns'）均不复现。修复面源码核验一致：`Model.get(srcContext, view.fk_model_id)` + `getColumns(srcContext)`（service.ts:460-469），且 `sharedViewPassword` 错值 400、缺值 400（'This shared view is password protected'）。
- **E3（减腿 500）— PASS**：干净 paste sync（初始 ['Title']）PATCH `selected_fields:['Title','Qty']` → 200 → 再 PATCH `['Title']` → **200 无 500**（R1 'Undefined binding' 不复现）；镜像 Qty 列已删；resync 200、数据 3 行对齐。修复按 (fk_table_sync_id, source_column_id) 复合键删映射行（service.ts:902-909），listColumnMappings 未动（仍不 select id，与修法自洽）。
- **E4（增腿 dest_column_id 落 model id）— PASS**：加 Qty 后 readonly=true；**resync 后 Qty=1,2,3 真实进数**（R1 症状为引擎 updates 执行但新列恒 null）。行为闭环证明映射 dest_column_id 已是真实列 id（engine fieldMap 以 (source→dest) id join，数据进数 = join 命中）。修复取法：columnAdd 后按 title 从 `addedModel.columns` 提取列 id，缺命中 fail-fast 400（service.ts:930-937）。[] → 400、null → 全字段恢复（Note 列补回 + readonly=true）、未知字段 400，均过。
- **resolveLink 无密码零泄露（lane5 M1 升格修）— PASS**：设密视图无密码 resolve → 响应**恰为** `{"passwordProtected": true}` 单键（live 捕获原文），无 sourceTableTitle/sourceViewTitle/sourceBaseId/sourceTableId 任何坐标；错密码 → 400 且无标题泄露；对密码 → 200 全坐标 + passwordProtected:false。sourceSchema paste 分支同形状（无密码单键 / 错密码 400 / 对密码 3 列 schema）——R1 lane1 M1 所述「错密码静默返全 schema」与 P2 实现源码（a4959c27cd 起 :289-296 即有 `if (!ok) 400`）及本轮 live 行为均不符，实测 400 正确，判 lane1 观察误差，非缺陷。
- **M3（Syncing 态菜单守卫）— PASS（UI 活体）**：camoufox `f09p2r2l3`，UI 账号 f09p2r2l3-ui（dest owner）。Active 态 sync_t1 树菜单四项全在：Sync now / Pause sync / **Convert to regular table** / **Delete sync**（shots/active-menu.png）。API 触发 resync（源已灌 ~1500 行拉长 Syncing 窗口）后 1.2s 重开同一菜单：**Sync 组四项全部消失**，仅常规项 + `Syncing` 徽标（shots/syncing-menu.png，快照文本双证）。窗口结束后 active 恢复。源码 v-if 双守卫在位（SyncMenuOptions.vue Convert/Delete 两 NcMenuItem `v-if="sync.status !== TableSyncStatus.Syncing"`）。
- **Syncing 态后端守卫活体（R1 M3 互补面，本轮新增证据）**：resync 触发后窗口内 PATCH → 400、detach → 400（race 探针双双命中守卫，非窗口错过）。

## 2. 安全审计重点

### 2.1 paste 凭据面 — PASS
- **存储**：写点唯一（insertMainMapping service.ts:757-762）：`source_uuid` = 视图 uuid；`source_password_hash` = 视图侧 bcrypt hash 原值；**明文密码从不入库**（createSync 入参明文仅用于当场 bcrypt.compare）。
- **读取面**：getSync 实测 mapping `{source_uuid:'8469d777…', source_password_hash:'$2a$10$…'（60 字符）}`；整响应 grep 明文口令 = 0 命中；hash 暴露 = 上游 SDK 类型既有字段（nocodb-sdk/src/lib/sync/table-sync.ts:48-49），非 fork 新增泄露面。视图列表 GET 不回显明文口令。
- **密码错误路径**：三入口（resolveLink / createSync / sourceSchema）错密码全 400 'Invalid shared view password'，无密码 400/单键占位，语义三口一致。
- **resolveLink 泄露面**：见 §1 第 4 条，零泄露实测。

### 2.2 detach ACL 边界 — PASS
- 路由 `@Acl('tableSyncDelete')`（controller:191-193）与 deleteSync 同权，base-scope creator+（utils/acl.ts permissionScopes.base exclude 模型）。
- **editor**（f09p2r2l3-e，仅 dest editor）：detach → 403，且镜像表 synced 仍 true（拒绝即无副作用）；11 端点矩阵（list/get/source-schema/create/update/delete/resync/freeze/resume/resolve-link/detach）**11/11 → 403**。
- **匿名**：list/resolve-link/detach/source-schema → 401×4。
- **owner**：detach 200 → getSync 404、mirror synced=false、镜像列 readonly 全解（Title/RemoteId false,false）、数据 3 行保留、插行 200 可编辑。

### 2.3 selected_fields 映射一致性 — PASS
- 增腿：dest_column_id = 真实列 id（§1 E4 行为证明）；readonly 强制 meta 落到正确列 id（修复后 metaUpdate 打 addedCol.id 非 model id）。
- 减腿：列删（forceDeleteSystem+skipTrash）+ 映射行删同键成对；残留映射无（resync 数据对齐佐证）。
- 列映射表不经 getSync 暴露（.mappings 仅 main 行，SDK 设计），无越权读面。

### 2.4 paste 权限边界（灰区面）— PASS
- api2（f09p2r2l3-api2，仅 dest owner、**无源 base 任何角色**）：resolve-link 200 + 对既有 paste sync resync 200 —— 凭持久 uuid+hash 凭证，符合规格「paste 不复检 base 权限」；browse 侧 assertSourceReadAccess 分支未动（service.ts:1064-1070 仅非 paste 走）。

## 3. P1 全矩阵回归 — PASS

- **引擎 e2e（paste sync 载体，delete 策略）**：源增 row4 + 改 row1→row1b → resync upsert（row1b,row2,row3,row4，Qty=4 进数）；源删 row3（`DELETE /tables/:id/records` body=[{Id:3}]）→ resync → 镜像 row1b,row2,row4（delete 策略生效）；freeze 200 → paused resync 400 + paused PATCH 400 → resume 200。
- **灰区复检**：allow_sync 关 → 既有 paste sync resync 400 / resolve-link 400 / createSync 400（三口全拒）；重开 allow_sync 恢复。
- **守卫链**：synced 镜像 owner 插行 400、owner 删表 400；付费锁 syncTrigger=realtime → 400。
- **Syncing 态**：PATCH 400 / detach 400（§1 race 探针）。

## 4. 质量门

- `tsc --noEmit`（packages/nocodb）exit 0。
- jest Fork 桶（testRegex Integration|Source|Fork）：3 suites / **41 tests 全过**。
- Vite URL 法：`/_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` 与 `/_nuxt/components/project/Action/CreateNewSync.vue` 均 200 text/javascript，编译产物含组件标记（onDetach/sourceInputMode 等 7 处）。

## 5. 观察项（不计级）

1. 增腿按 title 从 addedModel.columns 找新列——若镜像已有同名孤儿列（如上次增腿 insert 映射失败残留），`.find` 命中首个同名旧列，映射 join 仍成立（同型同名）但镜像可能留重复列。极端时序，未构造成功，纯理论。
2. resync 不复验 source_password_hash（视图后设密码时既有 paste sync 凭 uuid 仍有效）——lane5 R1 观察项顺延，规格未要求，EE 语义未定。
3. lane1 R1 的 sourceSchema 错密码 M1 与源码/实况不符（见 §1），建议后续对照历史报告下结论时以实测为准。

## 6. 测试资产与清理

- 账号：f09p2r2l3-api / -api2（dest owner；api2 无源权限探针）/ -e（dest editor ACL 探针）/ -ui（UI owner）。base：f09p2r2l3-src（pv5vkhpp2t8xhga）/ f09p2r2l3-dest（pkxh40xbqi34d8p）——**两 base 已删（HTTP 200），残留 0**；账号留存无害。
- 脚本：/tmp/f09p2r2l3/{setup,t1,t2,t3,t4}.sh；截图：/tmp/f09p2r2l3/shots/{active-menu,syncing-menu}.png。
- 脚本侧 4 处 bug（jq 嵌套引号 / 矩阵 URL 双斜杠 / list 裸数组形态 / 删行 body 需对象数组）已修正重测，均非产品问题，相关断言以修正后实测为准。
