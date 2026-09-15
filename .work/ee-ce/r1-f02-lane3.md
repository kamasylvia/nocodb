# F02 R1 lane3 — 拦截覆盖面 + 回归 终审报告

**结论：issues 列表（1 error + 3 minor + 1 note）**

- `packages/nocodb/src/db/BaseModelSqlv2.ts:3025` `nestedInsert` 缺 checkPermission 挂点：标量字段写入完全绕过 F02 拦截。v1 数据插入路由 `POST /api/v1/db/data/:orgs/:baseId/:tableId`（datas.service.ts:173 `dataInsert` → nestedInsert）实测 editor 对 nobody-grant 字段写入成功（HTTP 200，Secret 落库，见证据 E1）。public form 提交（public-datas.service.ts:825）走同一 nestedInsert 汇合点 → `enforce_for_form` 后端语义完全落空（前端 Form.vue 隐藏受限字段，直打后端即写入）。建议：在 nestedInsert 的 `validate` 之后（与 insert.ts single 钩子同语义位置）补 `checkPermission({FIELD, fieldPermissionEntityIds(insertObj, columns), RECORD_FIELD_EDIT, request.user, request})`，或让 v1 dataInsert/public form 走 single()。注：nestedInsert 的 **link** 写不受影响（经 prepareNestedLinkQb → 关联钩子，实测 L3 403）。
- `packages/nocodb/src/db/BaseModelSqlv2.ts:10570`（checkPermission grants 循环）多 grant 时仅评 `grants[0]`：同字段存在多条 grant 时结果取决于 list 次序。实测 nobody + user-grant(editor in subjects) 并存时 editor 被 grants[0]=nobody 拒（证据 E2）。建议：Permission.insert 拒绝 (entity, entity_id, permission) 重复行，或遍历全部 grants 任一 allow 即放行。
- `packages/nocodb/src/db/BaseModelSqlv2.ts:4710-4726` updateLTARCols 外壳钩子恒 no-op：`fieldPermissionEntityIds` 按 `column_name` 匹配，而该路径 datas 键是 title（ltar-cols-updater.ts:45 `col.title in d`）→ entityIds 恒空。真实拦截在 LTARColsUpdater 内部（:49，title 检测，CE 既有），无安全缺口（实测 L2/L3 均拦截），但属死代码 + 注释误导（"guard the targeted link columns here" 实非守卫所在）。建议：删外壳钩子或改按 title 匹配。
- `packages/nocodb/src/models/Permission.ts` update：granted_type 改 nobody 时不清 `granted_role`/`subjects` 残留（实测 perm2 转 nobody 后仍带 editor subject + granted_role=editor）。nobody 分支不读这两字段，无行为影响，属脏态。建议：转 nobody 时同时置空。
- NOTE（非 error，fork 限制建议记录）：`enforce_for_automation=false` 无任何豁免通道——服务用户（automation/anonymous 等，无 base_roles）在 checkPermission 中 role=undefined → 有 grant 即拒。与迁移默认 true 一致，但 EE 的 opt-out 语义缺失；`enforce_for_form=false` 仅前端 usePermissions（isFormView opt-out）消费，后端不读。

## 旁路面枚举表（editor + nobody-grant 字段实测，除注明外）

| # | 写入路径 | 路由 | 结果 | 判定 |
|---|---|---|---|---|
| W1 | v2 PATCH 单条 | PATCH /api/v2/tables/:id/records `{Id,Secret}` | 403 | ✓ 拦截 |
| W2 | v2 PATCH 数组 | 同上数组体 | 403 | ✓ |
| W3/W4 | v2 insert 单条/数组（bulkInsert） | POST /api/v2/tables/:id/records | 403，行未落库 | ✓ |
| W5/R1 | v2 非受限字段写 | PATCH `{Title}` | 200 | ✓ fail-open |
| W6c | **v1 数据插入（alias）** | POST /api/v1/db/data/noco/:baseId/:tableId | **200，Secret 写入** | **✗ BYPASS（error 1）** |
| W7c | v1 单行更新（updateByPk） | PATCH /api/v1/db/data/.../:rowId | 403 | ✓ |
| W8c | v1 bulk update | PATCH /api/v1/db/data/bulk/... | 403 | ✓ |
| W9c | bulkUpdateAll | PATCH .../bulk/.../all?where=... | 403 | ✓ |
| W10c | v1 bulk insert | POST .../bulk/... | 403 | ✓（controller 不透传 skipPermissionCheck，仅 job 内部可传） |
| W11c | bulkUpsert（v3 upsert 路由） | POST /api/v3/data/:baseId/:tableId/records/upsert | 403 | ✓ |
| V3-i | v3 insert | POST /api/v3/data/:baseId/:tableId/records | 403 | ✓ |
| V3-u | v3 update | PATCH /api/v3/data/.../records | 403；非受限字段 200 | ✓ |
| L1 | link API addLinks | POST /api/v2/tables/:id/links/:colId/records/:rowId | 403（Links 单独 grant） | ✓ |
| L2 | v2 嵌套 insert 带 Links payload | POST records `{Title,Links:[1]}` | 403 | ✓（bulkInsert→updateLTARCols→LTARColsUpdater title 检测） |
| L3 | v1 嵌套 insert 带 Links payload | POST /api/v1/db/data/... | 403 | ✓（nestedInsert 的 link 分支有钩） |
| L4 | v1 nested addChild | POST .../1/hm/:colId/1 | 403 | ✓ |
| L5 | removeChild/removeLinks/reorderLink | — | code 确认同款 checkPermission 前置（:6835/:8734/:8752），未逐条 live | ✓（code） |
| — | **public form 直打** | POST /api/v1/db/public/shared-view/:uuid/rows | nestedInsert 无钩 → 值写入（code 定性 + W6c 同汇合点实证；live 复测受 fixture 阻，见 E3 注） | **✗（归 error 1）** |
| — | webhook 触发写（只读评估） | — | URL webhook 出站 HTTP 不落库；script 经 ExecuteAction 以 AUTOMATION_USER 执行，无 base_roles → 有 grant 即拒（= enforce_for_automation 默认 true 语义） | ✓（默认语义下） |
| — | meta-diff/recovery | — | 只写 meta 表/结构，不写数据行 | ✓（code 评估） |

## skip 通道

- import.service（3 处）/ at-import / data-import processor：`skipPermissionCheck: true` + `raw: true` + `undo: true` 三重豁免，controller 层不透传该 flag（API 直调无 bypass）→ ✓（code）。
- owner duplicate base 实测：受限字段表复制成功且 Secret 数据完整（副本 p6d8t35hu6ydu7w.t1 逐行核对）✓。
- editor duplicate base → 403 ACL（duplicateBase creator+）✓；row copy 走 v2 insert 路径 = 有 grant 拒（语义正确）。
- undo：`undo: true` 仅在 import/copy 路径出现且必伴 skipPermissionCheck+raw → 不会误拦 ✓。
- onlyUpdateAuditLogs：唯一 caller 在 updateByPk BT 分支（:2902）；BT 列 uidt=ForeignKey 被 fieldPermissionEntityIds 排除、由 addChild 钩（:6432，先于 onlyUpdateAuditLogs 早退）统一拦截——同一用户同一请求语义一致，无误拦 ✓。

## 回归结果

- 无 grant 全路径 CRUD ✓（v2 PATCH/insert、v1 alias、v3、delete 数组体 200、v3 delete 200）。
- F01 unique 错误映射 ✓：editor 插重复 Title → `FIELD_UNIQUE_CONSTRAINT_VIOLATION`（400），非 403 权限错；enable 前置重复校验亦正常（"Found 3 duplicate values"）。
- F05 variables 200 ✓；F07 snapshots 200 ✓；F08 base meta 200 ✓；F10 base dashboards 200 ✓。
- 审计/undo：editor 允许更新后 `nc_audit_v2` DATA_UPDATE 行存在 ✓；onlyUpdateAuditLogs 路径见上 ✓。
- owner 直通 ✓（B1）；权限管理 ACL：editor permissionCreate 403 ✓；entity/permission/granted_type/colId 校验 400 ✓；跨 base colId 被拒（Column.get 按 base 过滤，先前假设不成立）✓。
- 缓存失效双向即时 ✓：nobody→role(editor) 放行、回 nobody 再拒、转 user-subject 放行（B8-B14）。
- 性能：同 base 10 次 editor PATCH，有 grant 688ms vs 无 grant 510ms（≈18ms/req 差，多为网络/DB 噪音）；psql 未见慢查询。
- tsc 0（exit 0）；jest 26/26 ✓。

## 证据（关键）

- E1（error 1 实证）：owner 建 grant `perm2tsxy49zimd282`（field Secret=cmy3yrccikfbwy8, RECORD_FIELD_EDIT, nobody）后，editor：
  `POST /api/v1/db/data/noco/p7rkd95xgnkpa36/m8e5tw2eucki1pn  {"Title":"v1","Secret":"h"}` → 200 `{"Id":3,...,"Secret":"h"}`（DB p7rkd95xgnkpa36.t1 落库核实，行已清理）。同请求体改走 v2/v3 路由均 403。
- E2（grants[0]）：perm2(nobody) + perm5(user-grant 含 editor) 并存 → editor PATCH Secret 403；删 perm5 后行为与单 grant 一致。
- E3 注（测试限制，非实现 error）：public form live 直打复测未能完成——测试用视图/视图列行系 psql 手插，首查早于插列，NocoCache 缓存 NONE 标记（FORM_VIEW_COLUMN scope）且 dev server 禁重启，API PATCH 触发的 evict 亦被同一标记挡住（404）。form 判定依据：nestedInsert 无钩（代码路径唯一）+ W6c 同汇合点实测。复测办法：重启 dev server 后用 UI 建 form view 重打。
- 测试遗留：base p7rkd95xgnkpa36（含 t1/t2、grants perm1/perm2、视图 vwf02r1l3f1/f2）与副本 base p6d8t35hu6ydu7w 保留供实现者复现；测试号 f02r1l3-owner/editor@test.local。
