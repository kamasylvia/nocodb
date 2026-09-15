# R1 F02 lane5 — 安全审计（拦截绕过面 / 注入面 / 提权面）

审查对象：commit 4b26d7a23f（F02 Edit field permissions）。语义契约：fail-open（无 grant=allow）+ owner 直通 + SDK evaluatePermission 共享决策。方法：源码走查 + dev server（localhost:8080 / nocodb-dev）API 实测。测试号 f02r1l5-o-1789329460@t.io（super）/ f02r1l5-e-1789329460@t.io（editor）；测试脚本 `.work/ee-ce/f02r1l5-run*.sh`。

## 结论：issues

1. `packages/nocodb/src/db/BaseModelSqlv2.ts:3025`（nestedInsert）:nestedInsert 自建 knex insert（~3148 `this.dbDriver(this.tnPath).insert(insertObj)`），不经 `db/BaseModelSqlv2/insert.ts` 的 checkPermission 挂点，导致**两条路由完全绕过字段写权限**：①`packages/nocodb/src/services/public-datas.service.ts:825`（shared form 匿名提交，实测匿名带受限字段 Secret 提交 200 落库，违反 enforce_for_form=true 默认契约）②`packages/nocodb/src/services/datas.service.ts:173`（v1 data 单条 insert，实测 editor 带 nobody-grant 的 Secret 200 落库）。建议：在 nestedInsert 的 mapAliasToColumn 之后（~3057）补与 insert.ts 同款 checkPermission（FIELD/RECORD_FIELD_EDIT）；form 场景结合 enforce_for_form 判定（true=拒/剥离，false=放行）。
2. `packages/nocodb/src/db/BaseModelSqlv2.ts:10583`（checkPermission 仅评估 `grants[0]`）+ `packages/nocodb/src/models/Permission.ts`（insert 无 (entity,entity_id,permission) 去重，migration nc_083 无唯一索引）:同字段多条 grant 仅按首行判定 → **权限收紧静默失效**。实测：先建 role:editor 再建 nobody，editor 写 Secret 仍 200（"lockfail" 落库）；反序（nobody 在前）则 403。建议：service 层拒重复 grant（同 entity+entity_id+permission 已存在则 400），checkPermission 改为对全部 grants 求值（最严语义或 EE union 语义二选一），并补 DB 唯一索引。
3. `packages/nocodb/src/services/permissions.service.ts:create/update`:granted_role 未按 PermissionRole 枚举校验（实测 `' OR 1=1 --'` 被接受；效果=deny-all，安全方向但产出垃圾配置）；entity=table + RECORD_FIELD_EDIT 组合被接受（实测 200，为惰性行、永不匹配 FIELD 检查）；subjects type 非 user/team 静默过滤后可产生空 subjects 的 user grant（实测=deny-all）。均无提权面，属输入校验缺口。建议：granted_role 枚举校验、field entity 限定 permission=RECORD_FIELD_EDIT 之外再限定 table entity 仅 F03 键、user grant 的 subjects 过滤后为空则 400。
4. `packages/nocodb/src/db/BaseModelSqlv2.ts:10544`（checkPermission）:完全未读 enforce_for_form / enforce_for_automation。前端 usePermissions.ts 对 `opts.isFormView && enforce_for_form===false` 放行，后端一律拒 → enforce_for_form=false 的 grant 会让表单提交整体 403（fail-closed 方向，与 FE 语义不一致）。修复 issue#1 时一并定义该列语义。
5. `packages/nocodb/src/models/Permission.ts:list`（context 级缓存 `__permissionsLoaded` 不含 baseId 维度）:同一请求内先加载 A base 的 grants 后再操作 B base 时会复用 A 的列表（cross-base 污染）。现网路由单 base 单请求，无实际触发路径，记低危。

## PASS 项（实测/走查证据）

| 面 | 结论 | 证据 |
|---|---|---|
| v2 PATCH 单条（title/column_name 混键） | 403；mapAliasToColumn 归一化 title→column_name，未知键被丢弃，无形态绕过 | T2/T3 |
| v2 PATCH 数组 / POST 单条 / POST 数组（bulk） | 均 403；混合 payload（Title+Secret）整体拒绝且 Title 未落库 | T4/T5/T6/T7 |
| bulkUpsert（v1 …/upsert） | 403（干净态） | T28 |
| bulkUpdate（v1 bulk PATCH）/ bulkUpdateAll（v1 …/all） | 403（干净态） | T27/T29 |
| v1 data PATCH 行 | 403（干净态） | T26 |
| bulkInsert raw 豁免 | `raw:true` 仅 columns.service/link-placeholder/迁移等内部调用；bulk-data-alias.controller 不接收外部 raw/skipPermissionCheck query|body 参数 | 源码走查 |
| skipPermissionCheck 注入面 | 仅 import.service.ts:2494/2536/2603 内部硬编码 true；bulk-data-alias.service 仅透传 param（controller 不传）；grep 全仓无外部可设点 | 源码走查 |
| skipValidationAndHooks | 仅 columns.service 内部 meta 迁移调用 | 源码走查 |
| link 5 方法（addChild/removeChild/addLinks/removeLinks/reorderLink）+ updateLTARCols | nestedDataLink 实测 403（Lnk nobody）；其余同挂 checkPermission | T17b/c |
| move 路由 | 仅写 Order 列（system 豁免），editor 200 合理（不动字段值） | T19 |
| webhook/automation 写 | 无本地数据写（webhook-invoker 仅外呼）；service user 无 base_roles → 一旦有写会按 deny 处理（fail-closed 方向） | 源码走查 |
| 注入面 | entity/permission 非法枚举 400；SQL 元字符全程参数化无 SQL 错误/500；超长 entity_id 400 | T32/T33/T35/T38 |
| 跨 base | entity_id 引他 base 列 400（Column.get 按 base 过滤）；permissionId 跨 base update 404；update/delete 校验 existing.base_id===route baseId | T39/T49 |
| 提权面（ACL） | permissionList/Create/Update/Delete：editor 全 403（include 制无此 op），creator/owner 放行（exclude 制） | T9/T10/T44/T45 |
| granted_role=owner grant | 语义=仅 owner 通过（owner 本有直通），等价 nobody，无提权 | 走查 + T46 |
| 角色 grant 语义 | role:viewer grant 后 editor 恢复可写；owner(super) 直通 | T46a/b/T8/T18 |
| fail-open 完整性 | 无 grant 时全路径 200；删 grant 后立即恢复（缓存 evict 实时） | T0/T21b/T48a/b |
| fail-closed 误伤 | 空 subjects user grant / 垃圾 granted_role 均 deny-all（拒正常写），方向安全 | T35b/T37b |
| 信息泄漏 | 403 消息仅含字段 title（editor 已知）；permissionList 对 editor 403 无行暴露 | T2/T9 |
| MCP 面 | mcp.controller `loadPermissions` 装 req.permissions + mirrorGuardUser（base_roles）→ checkPermission 的 req.permissions 通道接通；`req?.permissions` 全仓仅此一处赋值，无外部注入面；api-token 用户与 xc-auth 同走 checkPermission（GlobalGuard authtoken 链） | 源码走查 |
| 缓存失效 | create/delete grant 后下一请求即生效（list key + row key evict 正确） | T1→T2、T48 |
| Base 删除清理 | Base.softDelete/delete 调 Permission.deleteByBaseId，孤儿行已清 | diff 走查 |

E3：无。所有测试在本机 dev server + nocodb-dev 完成，无外部限制。

## 附注（非 error）

- T24 v1 bulk upsert 在空态/无新行 payload 下 500（`Cannot read properties of undefined (reading 'Id')`，bulkUpsert 内部）——需判定是否上游既有；不属本 lane 权限面结论，留给集成 lane 核实。
- undo（审计回放）路径未实测；走查确认 undo 参数不触发 skipPermissionCheck，被限字段的 undo 写会被拦（over-block 方向，符合"恒强制"裁剪注记）。
