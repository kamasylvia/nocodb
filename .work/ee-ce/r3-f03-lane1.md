# r3-f03-lane1 — F03 Data permissions 终局收敛轮(集成全量 + diff 复审)

审查对象:7b10716231(F03 主实现)+ e1e996283c + 2f5a57b0d3 + 0a3e5fdab4 + c7a242cdf3 + 6cc43e0b81(修复至 HEAD)。环境:dev :8080(nocodb-dev),base f03r3-base=p3r04s1fl47gdru,TableA=meuwgnek49wtday / TableB=mwb7ts0i39ed5jz,owner=f03r3o(super 提权)/editor=f03r3e/creator=f03r3c。隔离纪律遵守。

## 结论

issues(3 项,均低危,无阻断性功能/安全错误):

1. `packages/nocodb/src/models/Permission.ts:update() NOBODY 分支(~:392-399)`:PATCH role→nobody 后 DB 中 `granted_role` 残留旧值(实测:role:editor → nobody 后 list 返回 `granted_role='editor'`;原 F02 实现写 null 清值,R1 2f5a57b0d3 改 `delete updateObj.granted_role` 后残留)。权限判定不受影响(evaluate 走 granted_type,实测 nobody 拦截 403 正确),但 ① 该处 R5 注释写 "reject bogus granted_role on NOBODY target" 实为静默丢弃,注释与行为不符;② nobody → role 回切不带 granted_role 时经 validateGrantShape 的 existing 回落静默复用残留旧 role,与 create 必填语义不对称。建议:NOBODY 分支恢复 `updateObj.granted_role = null` 显式写库清值并修正注释(clear 或 reject 对齐)。
2. `packages/nc-gui/components/smartsheet/grid/Table.vue:336 isAddingEmptyRowAllowed`:computed getter 内调用 `usePermissions()`,每次重算在无 effect scope 上下文重新注册 `watch(baseId)`(usePermissions.ts:73),永不 dispose → 轻量资源泄漏(量 = 该 computed 失效次数,有限;loadPermissions 有 per-base guard 不会请求风暴)。建议:setup 顶层解构 `isAllowed` 后在 computed 内引用。
3. `packages/nc-gui/components/dlg/Table/Permissions.vue:70 OPTION_FOR_ROLE`:`owner → CREATORS_AND_UP`。API 层可建 `granted_role=owner` grant(minimumRole 只验下限),UI 显示为 "Creators & up",再次保存 PATCH 成 creator —— 静默降权。触发链窄(UI 无法直接造 owner-role grant)。建议:删 owner 映射(回落未知展示)或 service 层拒 role:owner。

既有缺陷(非 F03 diff 引入,git 考古钉死,不计 F03,供 backlog):

- `BaseModelSqlv2.ts:4202 bulkUpsert 纯 update 批 500`:v1 `POST /api/v1/db/data/bulk/:orgs/:baseName/:tableName/upsert` 更新已存在单行 → `afterUpdate`(:6065)读 undefined.prevData(existingRecords 对齐失败),owner/creator/editor 三角色均复现;数据实际已更新(崩在写后审计回调)。该调用链在 4b26d7a23f^ 已存在。
- v1 data 路由按表 title(`/:baseName/TableA`)404:owner 无 grant 同复现(`Model.getByAliasOrId` title 分支,F03 未触碰);按表 id 全通。
- v1 bulk PATCH(`/bulk/...` 非 /upsert)对无 Id 行静默忽略返回 200(CE bulkUpdate 既有语义,非 upsert;不要用该路由构造 upsert 断言)。

## 集成测试结果(全部实测)

### 全矩阵 ADD/DELETE(拦截/放行分界)— 全 PASS
- 基线 fail-open(无 grant):ed/ct v2 insert 200、list 200、meta 200、ed delete 200;v1 insert/delete/bulkInsert/deleteAll(byFilter)200 — 10/10
- ADD nobody:ed v2 single/bulk 403、v1 single/bulk 403;ct 403;ot 200;TableB 无 grant insert 200(跨表隔离);v2 PATCH 与 v1 bulk PATCH 纯 update 200(不误伤)— 9/9
- ADD upsert 路由(/bulk/.../upsert):nobody 纯 insert 批 403、混合批 403(toInsert 拆分后判定生效)
- ADD role:editor:ed 200/ct 200;role:creator:ed 403/ct 200;specific_users=[editor]:ed 200/ct 403
- DELETE nobody:ed v2/v1/v1bulk/deleteAll 403;ct 403;ot 200 — 6/6
- DELETE role:editor 200;role:creator:ed 403/ct 200
- 跨 key 独立:DELETE nobody 下 ed insert 200 / ct 403(ADD user:editor)
- revoke fail-open:删 DELETE grant → 下一请求 ed delete 200

### 校验对称 — 全 PASS
- create 10/10:field+TABLE_RECORD_ADD 400 / table+RECORD_FIELD_EDIT 400 / nobody+subjects 400 / role 缺 granted_role 400 / ADD+role:viewer(minimumRole)400 / user 无 subjects 400 / granted_type 非法枚举 400 / entity=base 400 / 跨 base entity_id 400 / 重复键 400
- update 4/4:nobody+subjects 400 / role+granted_role:null 400 / 低于 minimumRole 400 / team subject 400
- 跨 base PATCH → 404(归属检查,语义优于 400)
- ACL:ed PATCH grant 403 / ed GET grants 200

### VISIBILITY — 全 PASS
- nobody:ed meta 404 / ed v2 data 404 / ed v1 data(id)404 / ed v1 bulk 404 / ct meta 404 / ot meta+data 200 / ed 表列表消失 / ot 列表可见 — 9/9
- role:viewer:ed meta/data 200;specific_users=[creator]:ct 200 / ed 404
- Everyone=删 grant 行:DELETE grant → ed 恢复 200(helpers 注释钦定语义)
- link 折叠:TableB 隐藏时 ed 读 TableA nested link 仅 pk+pv,BExtra 值不泄漏(CE nested 端点两侧默认 pk+pv,折叠差异不可经公开 API 区分;relation-data-fetcher 为上游零改动面)
- 匿名表单闭环:shared form + ADD role:editor(enforce_for_form 默认 true)→ 匿名提交 403 文案 "You don't have permission to create records in TableA";PATCH enforce_for_form=false → 匿名 200 落库
- 匿名直访未共享 base data → 401(GlobalGuard 先行)

### 免检通道
- base duplicate 在 ADD+DELETE grants 存在下成功,副本含 TableA/TableB — import skipPermissionCheck 通道 PASS
- 观察项:副本不带 grants(DUP_GRANTS=[],export/import 管线有 permissions 支持但 duplicate 实测不携带)——既有管线面,F03 未触碰,偏安全侧

### 回归抽测 — 全 PASS
- F05 variable 创建 200;F07 snapshot status=completed;F08 editor bases 列表仅共享 base;F10 dashboard 创建 200;F02 field RECORD_FIELD_EDIT nobody → ed PATCH 403 / ct 403(nobody 除 owner 全拒,正确)
- tsc --noEmit 0 错误;pnpm test jest 2 suites / 26 tests 全过

## 代码复审(F02+F03 触碰面)
- fieldPermissionEntityIds:Set 全收集 + column_name/title/id 三键 + system/pk/FK 过滤 — R6 决议一致
- checkPermission:owner 直通 → 空 list 短路 → 逐 entityId grants 过滤 → 匿名 enforce_for_form every() 豁免 → any-deny 顺序无关 → 两 denial 分支 per-permission 文案(TABLE label=model.title)— 正确
- extract-ids F03 gate:主路径 ncTableId 赋值(:234)+ legacy tableName 兜底解析;空权限短路 + isServiceUser 豁免 + 匿名回落 default visibility + 404 遮蔽;Permission.list cache-free 回填 context.permissions,匿名分支无陈旧空数组旁路 — 正确
- permissions.service:TABLE 3-key 白名单 + Model 存在 + base 归属 + synced 拒配 + 重复键 — 完整;update 的 key 不可变(extractProps 白名单),resolved-type 校验顺序正确
- data-table.service:398 失实注释已修正
- 探针残留:零(extract-ids:1171 console.log 为上游 sync commit 69a29568c7 遗留,非 fork);错误消息无内部泄漏
- 前端:getPermissionSummaryLabel 存在;Content.vue 导入齐全;Dialog save 对 undefined payload + existingId 删 grant 语义合理;POST res.data.id 命中;Node.vue gate flag 化自洽;useExpandedFormStore isEeUI 短路已除且 !meta.id 保底

## 环境清理
测试 grants 全部删除(permissions 表 0 行)、form unshare;测试号 f03r3o/e/c 与 base 留存 dev 库。
