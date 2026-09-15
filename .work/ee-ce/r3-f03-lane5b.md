# F03 Data permissions R3 lane5 — 终局收敛轮(全量集成测试 + 全 diff 复审)

## 结论

**PASS**(0 实际 error)。

附 2 条 minor 观察(非阻断,低危 hygiene/perf)+ 2 条范围外既有缺陷记录(有诊断,非 F03 引入,不计 error)。

- 审查对象:a4e4e2f68f..HEAD 七 commit(7b10716231 F03 实现 → e1e996283c → 2f5a57b0d3 → 0a3e5fdab4 → c7a242cdf3 → 6cc43e0b81;diff stat 14 文件 +663/−39)
- 验证门:后端 jest 26/26 pass;`npx tsc --noEmit` exit 0;dev server(:8080,dist 构建时间 07:56 = HEAD 后)实测

---

## 1. 集成测试(nocodb-dev 实测,前缀 f02r3e-*,base pbj17afp81zq93n,TableA=miycfi1tzx0mxom / TableB=m3ftl5lhmg8tc5d / TableC=mkhr01oeru2ktqr)

### 1.1 基线 fail-open(无任何 grant)

| # | 场景 | 期望 | 实测 |
|---|---|---|---|
| T1 | editor v2 单条 insert | 200 | 200 ✅ |
| T2 | editor v2 bulk insert | 200 | 200 ✅ |
| T4 | viewer insert | 403(角色 ACL,dataCreate 需 editor) | 403 ✅ |
| T5 | owner insert | 200 | 200 ✅ |
| T8 | 无 grant 时 editor insert(删光 grant 后复测) | 200 | 200 ✅ |

### 1.2 TABLE_RECORD_ADD 矩阵(TableA;grants 依次 nobody / role:creator / user:[editor])

| # | 场景 | 期望 | 实测 |
|---|---|---|---|
| A1 | editor v2 insert(ADD nobody) | 403 | 403 ✅ 文案 `You don't have permission to create records in TableA` |
| A2 | owner v2 insert(ADD nobody) | 200 | 200 ✅ |
| A3 | editor v2 bulk insert | 403 | 403 ✅ |
| A4 | viewer insert(角色 ACL 先拦) | 403 | 403 ✅(ACL 文案,正确——viewer 本就不可写) |
| A5 | v2 POST 带 `?mode=upsert` 单对象 | 403(v2 路由无 upsert 特性,按普通 insert) | 403 ✅ |
| A7 | editor v1 insert(路径用 table id) | 403 | 403 ✅(nestedInsert 挂点生效) |
| R1/R2 | PATCH role:creator → editor insert | 403 | 403 ✅ |
| R3/R4b | PATCH user:[editor] → editor insert | 200 | 200 ✅ |
| A9 | editor v1 bulkUpsert 混合批(1 更新+1 新增) | 403 | 403 ✅(拆分后只查 toInsert,混合批触发) |

### 1.3 ADD × import/copy skip 通道

| # | 场景 | 期望 | 实测 |
|---|---|---|---|
| SK1 | creator 账号直插 TableA(ADD nobody) | 403 | 403 ✅ |
| SK2 | creator 触发 table duplicate(excludeData:false) | 复制成功且含全部数据行(skipPermissionCheck 通道) | job 成功,副本 `TableA-skipcopy` 含 10 行全部数据 ✅ |

### 1.4 TABLE_RECORD_ADD × 公开表单(nestedInsert isFormContext)

| # | 场景 | 期望 | 实测 |
|---|---|---|---|
| F1 | 匿名提交共享 form(ADD nobody,enforce_for_form=true) | 403 | 403 ✅ 同款 TABLE 文案 |
| F2 | PATCH enforce_for_form=false → 匿名提交 | 200 | 200 ✅(行落库 Id=10) |
| F3 | PATCH 回 true → 匿名提交 | 403 | 403 ✅ |

### 1.5 TABLE_RECORD_DELETE 矩阵(TableA;DELETE nobody)

| # | 场景 | 期望 | 实测 |
|---|---|---|---|
| D1 | editor v2 bulk delete(`DELETE /records` 数组) | 403 | 403 ✅ `delete records in TableA` |
| D3 | editor v1 delByPk(`DELETE /api/v1/db/data/noco/:base/:table/:row`) | 403 | 403 ✅ |
| D4 | editor v2 deleteAll(`DELETE /records?where=`) | 403 | 403 ✅(bulkDeleteAll 挂点) |
| D5 | editor v1 bulkDeleteAll(`DELETE /api/v1/db/data/bulk/...`) | 403 | 403 ✅ |
| D6b | owner v2 bulk delete 1 行 | 200 | 200 ✅ |
| D7 | viewer delete | 403(角色 ACL) | 403 ✅ |
| D8c | editor PATCH 更新(DELETE≠edit 正交性) | 200 | 200 ✅ |

### 1.6 TABLE_VISIBILITY 矩阵(TableB)

| # | 场景 | 期望 | 实测 |
|---|---|---|---|
| V1a | owner 表列表(nobody) | 含 TableB | ✅ |
| V1b | editor 表列表 | 不含 TableB | ✅ `TableA,TableC` |
| V1c | viewer 表列表 | 不含 TableB | ✅ |
| V2a/V2b | meta 直连:owner 200 / editor 404 | — | 200 / 404 ✅(遮蔽非 403) |
| V3a-e | editor data 路由:records 404、count 404、insert 404、v1 data(by id) 404、aggregate 404 | 全 404 | 全 404 ✅(R1/R2 修复后 extract-ids 闸门生效) |
| V4a | owner v2 data TableB | 200 | 200 ✅ |
| S2-S4 | PATCH user:[editor] → editor 列表含 TableB + data 200 | — | ✅ |
| S5-S6 | viewer 同态:列表不含 + data 404 | — | ✅ |
| S7-S9 | DELETE grant(=Everyone 语义)→ viewer 列表恢复含 TableB;TABLE_VISIBILITY grant 行数=0 | — | ✅(Everyone=删行语义闭环) |
| PATCH nobody 后 granted_role | 残留 role 清空 | — | ✅(R5 hygiene:`"granted_role":null`) |

### 1.7 service user(API token)豁免

| # | 场景 | 实测 |
|---|---|---|
| SU1 | base api-token 读隐藏 TableB(VISIBILITY user grant,token 非 owner) | 200 ✅(isServiceUser 豁免,与 getTableWithAccessibleViews 对齐) |
| SU3 | base api-token insert TableA(ADD nobody) | 200 ✅(token 主体按 owner 级角色解析,fork 裁定 service-user 放行,名实相符) |

### 1.8 匿名/共享面

- 公开共享 form 匿名提交链(F1-F3)已覆盖匿名 TABLE 判定(helper `!user` 回落 default visibility 路径)。
- shared-base 匿名列表走上游 `getAccessibleTables` isPublicBase 分支(F03 未触碰),meta 匿名探测返回 `{"base_id","base_title"}`,无表枚举面。
- 直连 v2 data 匿名 → 401(GlobalGuard 先拦),非 F03 面。

### 1.9 校验对称性(permissions CRUD)

| # | 输入 | 期望 | 实测 |
|---|---|---|---|
| V1dup | 重复 (entity,entity_id,permission) | 400 | 400 ✅ `A permission grant already exists...` |
| V3 | nobody + subjects(create) | 400 | 400 ✅ |
| V3upd | PATCH nobody + subjects | 400 | 400 ✅ |
| V4 | user grant 无 subjects(create) | 400 | 400 ✅ |
| V5 | FIELD key(RECORD_FIELD_EDIT)挂 TABLE entity | 400 | 400 ✅ |
| V6 | entity_id 跨 base 表 id | 400 | 400 ✅ `Table ... not found` |
| V8 | entity_id 不存在表 | 400 | 400 ✅ |
| W1 | ADD role:viewer(minimumRole=editor) | 400 | 400 ✅ `below the minimum role` |
| W2 | VISIBILITY role:viewer(minimumRole=viewer) | 200 | 200 ✅ |
| W3 | VISIBILITY role:commenter(commenter ≥ viewer) | 200 | 200 ✅(commenter 权力高于 viewer,合法) |
| V7 | granted_role 非法枚举 | 400(validateGrantShape) | 400 ✅(enum 校验 create/update 双侧生效) |

### 1.10 回归(F01/F02/F05-F10)

| 项 | 测试 | 结果 |
|---|---|---|
| F02 | FIELD RECORD_FIELD_EDIT nobody:editor insert 含受限字段 → 403 `edit the field Title`;去字段 payload → 403 转 ADD 文案(`create records in TableA`)——FIELD/ADD 双 hook 顺序与文案互斥正确 | ✅ |
| F05 | base variables:POST 200,GET 回读 `F03VAR=v1` | ✅ |
| F07 | snapshot create(异步副本)status=completed;restore → 新 base `pvr45dy4vsvx3sj` 含 TableA/B/C/skipcopy 全部 4 表 + 数据行(ADD nobody 存在下 restore 不自拦,skip 通道生效) | ✅ |
| F10 | dashboard create 200 | ✅ |
| F08 | 私有 base 门未回归:非协作者越权访问为既有 ACL 面,无新增放行 | ✅(抽查) |
| F01 | unique-only 为纯前端展示特性,无 API 面;F03 diff 未触碰 | N/A |

### 1.11 jest + tsc

- `npx jest --testRegex '(Integration|Source|Fork)\.spec\.ts$'`:**2 suites / 26 tests 全 pass**(440s)。
- `npx tsc --noEmit`:**exit 0,无输出**。

---

## 2. 代码复审(a4e4e2f68f..HEAD 全 diff,14 文件)

后端:
- `BaseModelSqlv2.ts` 6 个挂点(delByPk/nestedInsert/bulkUpsert 拆分后/bulkDelete/bulkDeleteAll/文案泛化)逐一定位核对:均按 research §1 挂点落位;bulkUpsert 检查 `if (toInsert.length)` 位于拆分后(≈:3867),纯 update 批不误伤(A5/A8 旁证);owner 直通、reqContext 用 `params.req.context`(规避 BaseModelSqlv2 实例缓存陈旧)正确。
- `insert.ts`:single(≈:77)与 bulk(≈:362)ADD 检查均在 FIELD 检查之后、bulk 侧位于 `!skipPermissionCheck` 包裹内(import/copy 免检)——SK2 实证。
- `extract-ids.middleware.ts`:主路径 `req.context.ncTableId = model.id`(≈:237)+ legacy 路径 tableName 回落(≈:1109)双通道;AclMiddleware 闸门(≈:1381)在角色 ACL/UI-ACL 之后、空 grant 短路、isServiceUser 豁免、404 遮蔽语义与注释一致。R1 bypass(v1 家族 ncTableId 不设)与 R2 修复已实证(V3a-e 全 404)。
- `permissions.service.ts`:TABLE 解封 = 3 key 白名单 + Model 存在/base 归属/synced 拒配;FIELD/entity 其它组合仍 400(V5/V6/V8/W1-W3)。
- `data-table.service.ts:398` 失实注释已修正。
- `Permission.ts`:NOBODY 目标 `delete granted_role`(不再写 null)——PATCH nobody 后 granted_role=null 实证。

前端:
- `dlg/Table/Permissions.vue`:三 key 状态机、Everyone=DELETE grant、VISIBILITY 默认 EVERYONE / ADD-DELETE 默认 EDITORS_AND_UP、dirty-only 保存、resetAll;payload role 映射(VISIBILITY viewer/creator;ADD-DELETE 仅 creator,均满足 minimumRole);i18n key 全存在(en/zh-Hans)。
- `Modal/Content.vue`:占位框换三行摘要(`getPermissionSummaryLabel` TABLE→EVERYONE 默认修复,与弹窗一致)+ 配置入口;SDK 枚举导入齐备。
- `Node.vue`:gate 由 `isEeUI && showEEFeatures` 改为 `!blockTableAndFieldPermissions`,弹窗 v-if 解 isEeUI——与 F02 flag+role 模式一致。
- `useExpandedFormStore.ts`:`!isEeUI` 短路移除,research §3.2 缺口闭合。
- `usePermissions.ts`:`getPermissionSummary` TABLE 无 grant → EVERYONE(前后端默认一致)。
- `grid/Table.vue`:legacy 网格补 TABLE_RECORD_ADD 消费(fail-open `?? true`)。
- lang en/zh-Hans:whoCanAddRecords/whoCanDeleteRecords 成对补齐。

无 console.error 残留、无 DSML 泄漏、无凭证入 diff。

---

## 3. Minor 观察(非阻断,低危)

1. `packages/nc-gui/components/smartsheet/grid/Table.vue:336` — `isAddingEmptyRowAllowed` computed 内调用 `usePermissions()`,每次重算都会在 setup 作用域外执行 `watch(baseId, ...)`(usePermissions.ts:73)且无 dispose → watcher 累积。功能影响低(回调幂等、base 切换少),属 perf/hygiene。建议:Table.vue setup 顶部取一次 `const { isAllowed } = usePermissions()` 再进 computed。
2. `packages/nocodb/src/models/Permission.ts update()` — granted_type user→role 切换时不清 subjects(实测残留 `user|usc95ywi70tjl9eu` 行);SDK evaluatePermission 对 ROLE grant 忽略 subjects(已核对 sdk evaluator),功能无害,仅脏数据。建议:与 NOBODY 分支同款,切换出 USER 时清理 subjects。

## 4. 范围外既有缺陷记录(有诊断,非 F03 diff 引入,不计 error)

1. **v1 按 title 寻表 404(系统性)**:`GET/POST /api/v1/db/data/noco/:baseName/:tableName` 对 title/table_name 一律 `ERR_TABLE_NOT_FOUND`,仅 table id 可用。链路:`datas.service.getViewAndModelFromRequestByAliasOrId → Model.getByAliasOrId`(metaGet2 + `notDeletedXcCondition`,均上游 sync 引入,F03 diff 未触碰 Model.ts/datas.service 该函数);DB 侧手工复算同条件 SQL 可命中(行存在、deleted NULL 条件匹配、knex `where(col,null)`→IS NULL 已验证),但服务端返回 null——疑 `query.condition()` 嵌套条件组合问题,需独立排查。影响:F03 的 v1 路径测试只能走 table id(本次即如此);R2 回落(`req.params.tableName`)在 by-id 时同样生效,闸门覆盖不缺。**建议记 backlog**。
2. **v1 bulkUpsert 纯 update 批 500(既有)**:`/api/v1/db/data/bulk/.../upsert` 仅含已存在行时,`bulkUpsert` PK 分支从未填充 `existingRecords`(仅 merge 分支 ≈:3781 填充)→ `afterUpdate(existingRecords[0]=undefined)` 500(BaseModelSqlv2.ts:4206/6065)。**零 grant 时同样 500(实测)**,与 F03 无关;F03 的混合批 403(A9)行为正确。**建议记 backlog**。

## 5. 测试残留

f02r3e-* 账号 4 个(owner/editor/viewer/creator)、base `f03l5-base`(pbj17afp81zq93n;现存 grant:TableA ADD user:[editor]、TableA DELETE nobody `perm91nrpuahitnll9`、TableB VISIBILITY user:[editor])、共享 form uuid 9e502791...、base API token(标题 f03l5-token)均在 nocodb-dev,未清理(各 lane 用独立 base,互不影响)。

---

**Lane5 终审意见**:七 commit 实现与 R1/R2 修复闭合了 research §2.3 data 路由遮蔽缺口及 §8 全部实现项;矩阵实测无功能 error;本轮 0 error。
