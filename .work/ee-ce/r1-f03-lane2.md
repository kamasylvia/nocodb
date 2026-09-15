# r1-f03-lane2 — F03 Data permissions 复审报告（lane2，2026-09-14，全量重写版）

审查对象：commit 7b10716231（F03）+ 整个 F02 触碰面（git log 4b26d7a23f^..HEAD -- '*.ts' '*.vue'，27 文件 +2240/-71）。
方法：全量 diff 代码复审 + nocodb-dev 全量集成测试（独立 base `p8yaajxkfv0ydd8` / Tasks `muhaxo3cxgux97d` / Notes `mlayopjo3gdcfku`，账号 l2f03-{owner,editor,creator}@t.local，grant 全走 API 写）。

## 结论：issues 列表

1. **`packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts:520-820 (tableIdToCheck 提取) + :1360-1378 (F03 VISIBILITY 块)`：v1 data-alias 全家族绕过 TABLE_VISIBILITY 遮蔽（安全 gap，必修）**。`tableIdToCheck` 只从 `params.tableId || params.modelId` 提取；v1 路由参数名是 `:tableName`（data-alias.controller `/api/v1/db/data/:orgs/:baseName/:tableName`、bulk-alias `/api/v1/db/data/bulk/...`、old-datas `/nc/:baseId/api/v1/:tableName`）→ `ncTableId` 永不设置 → F03 块与上游 `hasModelRoleVisibilityAccess` 块双双跳过。实测（VISIBILITY nobody，editor，Notes 表 id 已知）：
   - `GET /api/v1/db/data/noco/:baseId/:tableId`（list）→ **200 全量数据**
   - `GET .../:tableId/1`（read）→ **200**、`/count` → **200**
   - `POST .../:tableId`（insert）→ **200**、`PATCH .../2` → **200**、`DELETE .../2` → **200**
   - creator 同样 200；v2 同条件 404（唯一被遮蔽面）。
   影响：知道 table id（历史链接 / link 列 fk_related_model_id 泄露面，正是 f03-research §2.3 钦定的威胁模型）的非 owner 可读可写隐藏表，`data-table.service.ts:398` 修正后的注释「TABLE_VISIBILITY is enforced in the extract-ids middleware」仅对 v2 成立。修法：tableIdToCheck 提取增加 `params.tableName` 分支（`Model.getByIdOrName` 已支持按名解析；实测本 build v1 仅认 table id，按名解析 404 对 owner 也如此，属上游 alias 解析既有行为，可一并修或记 fork 限制）。
   注：本次先于我收到的同路径文件旧稿将此项列为 E3-1（只报 read）——定性错误：这是实现缺口非外部限制，且 leak 面 = 读+写+count 全量。

2. **`packages/nocodb/src/services/permissions.service.ts:33-99 (create)`：entity×permission 配对校验缺口**。entity=dashboard/document 等非 field/table 实体 × 任意合法 key（如 TABLE_RECORD_ADD）→ 200 创建。实测 `{"entity":"dashboard","entity_id":"x","permission":"TABLE_RECORD_ADD","granted_type":"nobody"}` → 200。无权限提升（checkPermission/findGrants 按 entity=TABLE/FIELD 过滤，垃圾行不参与判定），但污染 permissionList 返回面。建议统一 entity×key 白名单，其余 400。

3. **`packages/nocodb/src/db/BaseModelSqlv2/insert.ts:354-371`：bulk 路径权限钩在行级循环内，O(B×2×(1+G)) meta 查询**。FIELD+ADD 两钩位于 `for (const [index, d] of datas.entries())` 内，每次 checkPermission 都 `Permission.list`（cache-free = 1+G 条查询，G=grant 行数）。与 bulkUpsert/bulkUpdate 的「Set 收集批级一次查」不一致；import/copy 有 skip 豁免，但 v2 `POST /records` 数组、undo 等常规批量受影响。建议仿 bulkUpsert 上提为批级。次要：checkPermission 不复用中间件已预置的 `context.permissions`，单条写也有一次重复 list。

4. **`packages/nc-gui/components/dlg/Table/Permissions.vue:150-151,184-185`：SPECIFIC_USERS 未选人时 payload=undefined**。save() 对 undefined 落入 PATCH/POST 分支：无 existingId 时 POST undefined body → 400 "Invalid entity undefined" 中断循环，其余 dirty key 丢失；有 existingId 时空转。建议 undefined 显式 continue。

5. **`packages/nc-gui/components/dlg/Table/Permissions.vue`：enforce_for_form 无 UI 开关**（f03-research §7 第 7 项）。loadCurrent 读取但 buildPayload 不发送；默认 true = 匿名 fail-closed，安全方向正确，API PATCH 实测生效。建议补开关或记 fork 限制。

## 观察项（非 error）

- 上游既有 bug：v1 bulk upsert 纯 update 批 → 500 `afterUpdate`（BaseModelSqlv2.ts:6065，"Cannot read properties of undefined (reading 'Id')"）；owner 无 grant 同样复现，该函数与 base commit 逐字节一致，非 F03 引入。F03 语义本身正确（mixed 批 403、纯 update 批不要求 ADD）。
- shared-view 公开面（`/api/v2/public/shared-view/:uuid/meta|rows`）不受 TABLE_VISIBILITY 约束：VISIBILITY nobody 下匿名 meta 200、匿名提交 200。capability-URL 语义，上游预埋同样不查；需范围裁定（EE 对齐 or fork 限制）。
- `permissions.service.ts` update/delete 的 "does not belong to this base" 400 分支不可达（`Permission.get` 先 404）；404 语义更安全，仅死代码。
- `Permission.findGrants` / `rolePowerOfRole` / `getPermissionColor` 无调用方（死代码可清理）。
- v1 路由按 tableName 访问对 owner 也 404（"Table 'Notes' not found"）——上游 alias 解析既有行为，与本次 gap 修复方式选择相关（见 issue 1 修法注）。

## 逐项验证结果（集成实测）

### 全矩阵（最终版全过；早期 3 个 mismatch 均为我方脚本用 signin 响应无 id 字段导致 subject id 取成 "null"，以 psql 真实 id 重测全过）

| grant \ 角色 | editor | creator | owner |
|---|---|---|---|
| ADD nobody | 403（v2 单/批、v1 nestedInsert） | 403 | 200 |
| ADD role:editor | 200 | 200 | 200 |
| ADD role:creator | 403 | 200 | 200 |
| ADD user:[editor] | 200 | 403 | 200 |
| ADD user:[creator] | 403 | 200 | 200 |
| DELETE nobody | 403（v2 delete、v1 delByPk、v1 bulkDelete、v1 deleteAll 四路） | 403 | 200 |
| DELETE role:creator | 403 | 200 | 200 |
| DELETE user:[editor] | 200 | 403 | 200 |

- 正交性：ADD 拦时 delete/update/list 200；DELETE 拦时 insert/update 200 ✓
- bulkUpsert 拆分（v1 upsert 路由）：纯 update 批（toInsert 空）不要求 ADD ✓；mixed 批 403 ✓；纯 insert 批 403 ✓。v2 `POST /records` 数组进 bulkInsert，带 Id 也是 insert 语义 → 403 正确（非 bug）
- owner 直通：三型 grant 全操作 200 ✓

### fail-open
- 无 grant 全路径 200；delete grant 后下一请求放行（ADD/DELETE/VISIBILITY 各验一轮）✓

### 校验对称
- create 400 全对：nobody+subjects、role 缺 granted_role、非法 granted_role、role:viewer 低于 ADD minimumRole(editor)、user 缺 subjects、非法 granted_type、table×RECORD_FIELD_EDIT、field×TABLE_RECORD_ADD、team subject、subject 缺 id、table 不存在、跨 base table、重复 (entity,entity_id,permission) ✓（唯一漏网 = issue 2 的非 field/table entity）
- update 400 全对：PATCH nobody+subjects、granted_role ''/null、nobody→role 缺 role、非法 granted_type、PATCH team subjects ✓；user PATCH 不带 subjects 保留 existing subjects（设计如此，实测生效）✓
- ACL：editor permissionList 200 / create+patch+delete grant 403 ✓；跨 base permissionId 404（get 先 404，死分支见观察项）✓
- 未实测：synced 表拒配（dev 无 synced 表；`table.synced` 拒配代码路径已复核）

### VISIBILITY
- nobody：editor/creator meta 404、**v2** data 404、写 404、表列表消失（editor 0 / owner 1）；owner 全通 ✓
- role:viewer：editor meta 200（≥viewer 梯次）✓；Everyone（删 grant）恢复 ✓
- 中间件：匿名回落 default visibility、service user 豁免、空 grant fail-open ✓
- ⚠️ v1 路由面不遮蔽 = issue 1（本项其余断言全过；早前我 V3「v1 read 404」为假阳性——当时 Notes 尚无该行，404 来自 record-not-found，已复测纠正）
- link 面：隐藏相关表经 link cell / nested link list 仅暴露 pk+pv（与 tableHelpers 折叠契约一致；fields 扩展实测不泄漏非 pv 列，owner 同样仅 pk+pv）✓

### 公开表单
- ADD nobody + 匿名提交 → 403（enforce_for_form 默认 true）→ PATCH false → 200 → 复原 true → 403 ✓
- 认证用户走 v1 view-submit 路径不受 form 豁免（datas.service 有意不设 isPublicForm）→ 403 ✓
- 匿名 shared-form 不受 VISIBILITY 约束（见观察项）

### 回归
- F02 字段权限 7/7：field nobody 下 insert 带受限字段 403 / 不带 200 / update 受限字段 403 / update 其它 200 / owner 200 / 删 grant 恢复 ✓
- F05 variables list+create（key/value）200 ✓；F07 ADD+DELETE nobody 并存时 snapshot create → completed（skip 通道生效）✓；F08 bases list 200 ✓；F10 dashboards list 200 ✓；owner xc-token 写入 200（owner 直通随 token 身份成立）✓
- `tsc --noEmit` exit 0；jest 26/26（2 suites，109s）✓

### 代码复审要点（F02 触碰面）
- fieldPermissionEntityIds：Set 去重 ✓；system/pk/uidt=FK/isSystemColumn 四重过滤 ✓；column_name/title/id 三键全命中防 R6 decoy 劫持（over-block 安全方向）✓
- checkPermission：owner 直通 → list → 空短路 → 逐 entityId any-deny 即 403（break，顺序无关）✓；匿名 isFormContext + enforce_for_form=false 豁免、非 form 匿名拒 ✓；reqContext 取 req.context 防实例缓存陈旧（R1）✓
- update() resolved-type 三守卫先于写库；subjects 重建后 nobody 再清一次（R3 顺序无关）✓；validateGrantShape create/update 两态正确 ✓
- 探针残留：diff 内 console.log/debugger = 0 ✓；[CE-EE] 标记齐全 ✓；错误文案无内部信息泄漏（VISIBILITY 统一 404）✓

### 环境备注（E3 类，不计 error）
- 测试中 2 次瞬时 curl 000（并发 lane 触发 rspack 重建窗口），重试即 200。
- 测试遗留清理：grant 清零 ✓、API token 已删 ✓；base `p8yaajxkfv0ydd8` 保留于 nocodb-dev 供裁决复核。
