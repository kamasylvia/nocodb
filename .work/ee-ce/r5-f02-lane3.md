# r5-f02-lane3 — F02 Edit field permissions R5 复审(收敛第 4 轮)

审查对象:4b26d7a23f(实现)/ e85a421d92(R1)/ 3b9dcbdbc6(R2)/ a8fc2c2966(R3)/ b95fbf7f74(R4)。
方法:代码复审(五 commit 累计 diff + 现行源码)+ nocodb-dev 实测集成测试(owner/creator/editor 三角色 + 匿名 form)。

## 结论

**issues(1 项,单路发现,未复现实际绕权,定级待裁决):**

- `packages/nocodb/src/db/BaseModelSqlv2.ts:4735`(updateLTARCols 内 checkPermission 挂点):挂点用 `fieldPermissionEntityIds(d, columns)` 解析 datas 键,该函数按 `c.column_name === cn` 匹配;但 updateLTARCols 收到的 datas 由 `extractLinkFieldsByTitle`(dbHelpers.ts:408)重键为**列 title**、且 `LTARColsUpdater`(ltar-cols-updater.ts:43/84)按 `col.title in d` 消费 → 键失配,`entityIds` 恒为空数组,`checkPermission` 收空数组直接放行,**该挂点永不拦截**。实测旁证:Lnk 列配 nobody grant 后,editor `PATCH /api/v2/tables/:tid/records` payload 携带 `Lnk/lnk/<colId>` 键均 200;但同 payload 以 owner 执行 link 也未写入(`Lnk:[]` 不变)→ 当前 CE 该通道(v1/v2 bulk PATCH/updateByPk 携带 link 键)实际不产生 link 写,**未复现实际绕权**;真实 link 写通道(addChild/removeChild/addLinks/removeLinks/reorderLink,5 处独立挂点)实测全部正确拦截。建议:fieldPermissionEntityIds 匹配放宽为 `c.column_name === cn || c.title === cn || c.id === cn`(与 extractLinkFieldsByTitle 三键语义对齐;对现有 column_name 键调用方无害),使 updateLTARCols 挂点真正生效。

**E3 / 上游问题(非 F02 面,不计 error):**

- `packages/nocodb/src/db/BaseModelSqlv2.ts:4171` bulkUpsert clean update-leg 500(`afterUpdate` 读 `updatedDataList[0].Id` undefined):owner 同样复现;该行最近触碰为上游同步 58ed76ab44,F02 五 commit 仅在 bulkUpsert 加 checkPermission 挂点(先于崩溃点执行,403 语义不受影响)。建议另行立项修上游。
- `public-metas.service.ts:271` shared-view meta GET 500(`Undefined binding(s) ... table_name`,Model.getWithInfo):public-metas.service.ts 不在 F02 diff;空 form view 触发,上游问题。

## R4 修复验证(全过)

| 用例 | 期望 | 实测 |
|---|---|---|
| PATCH granted_role:null(role grant) | 400 | 400 ✓ |
| PATCH granted_role:""(role grant) | 400 | 400 ✓ |
| nobody→role 不带 granted_role | 400 | 400 ✓("granted_role is required for role grants") |
| PATCH 后存储态 | 不被污染 | granted_role 保持 "editor" ✓ |
| PATCH team subjects(不带 granted_type,user grant) | 400 | 400 ✓ |
| PATCH team subjects(显式 granted_type:user) | 400 | 400 ✓ |
| PATCH 后 subjects | 保持 user | subjects=["user"] ✓ |

`grantedRoleForValidation`(Permission.ts:314,`'granted_role' in data`)与 `grantedRoleToStore`(:362,`'granted_role' in updateObj`)一致性:extractProps(sdk commonUtils.ts:19)剔除 undefined、保留 null/'';null/'' 走 `'granted_role' in updateObj` → `?? ''` → role 类型 400;undefined 键不进 updateObj 且 validation 先 400。两路语义闭合,无旁路。

## 写入路径扫描(editor;grants:Secret=nobody / Title=role:editor / Email=user:owner / Lnk=nobody)

| 路径 | 受限字段 | 干净路径 |
|---|---|---|
| v2 insert(POST /records) | 403 | 200 |
| v2 PATCH /records(bulkUpdate)单条 | 403(Secret/Email) | 200(Title) |
| v1 insert(POST /db/data/noco/:b/:t) | 403 | 200 |
| v1 update(PATCH :rowId → updateByPk) | 403 | 200 |
| v1 bulkInsert | 403 | 200 |
| v1 bulkUpdate | 403 | 200 |
| v1 bulkUpdateAll(…/all) | 403 | 200 |
| v1 bulkUpsert(update leg / insert leg) | 403 / 403 | 500(上游,见 E3) |
| link addChild(v2 POST /links/:col/records/:row) | 403 | owner 201 |
| link removeChild(DELETE) | 403 | — |
| link reorder(internal nestedDataReorder) | 403 | owner 422(payload before 不在链接集,业务校验非权限) |
| row move(POST /records/:id/move) | 201(行级排序不受字段 grant 影响,正确) | — |

## skip 通道(不误拦)

- F07 快照(creator 触发,走 duplicateBase):`POST /bases/:id/snapshots` → processing → **completed**。
- creator duplicate base:200,副本 7 行数据完整(**Secret='s1' 保留**)→ import/copy 的 skipPermissionCheck 生效且无数据丢失。
- creator duplicate table:job 提交 200。
- undo 不可绕权:editor `?undo=true`(v1 insert / v1 bulk / v2 insert)全系 403;owner undo=true 200。

## form 提交路径(匿名 public shared form,enforce_for_form)

| 用例 | 实测 |
|---|---|
| 仅 Free 列(true clean) | 200 ✓ |
| +Title(role=editor grant,匿名) | 403 ✓ |
| +Secret(enforce_for_form=true) | 403 ✓ |
| +Secret(PATCH enforce_for_form=false 后) | 200 且值实际落库 ✓(再恢复 true 后复 403) |
| +Email(user grant,匿名) | 403 ✓ |

## 回归

- 无 grant CRUD:editor DELETE record 200、owner PATCH 200。
- permission ACL:editor list 200(R2 editor+ 读)、editor create 403(creator+ 写)。
- F05:variables create(key/value)+ list 200。F07:snapshots list 200 + create completed。F10:dashboards list 200。F08:F02 权限行与 private-base 判定无冲突(本轮无 private base 叠加用例;F08 已 pass 交接)。
- `npx tsc --noEmit`(packages/nocodb):**0 错误**。
- 后端 jest:`pnpm test` **26/26**(2 suites)。
- 前端 vitest:`test/table-field-permission.test.ts` **14/14**。

## console.log 零残留复查

- F02 五 commit 全部 23 个 diff 文件 grep `console.log`:仅 2 个文件命中,均为上游遗留——`ColumnMenu.vue:377`(上游 c6b08a7f4f,2024)、`public-datas.service.ts:219/477/674/1003`(Pranav C 2023 原始代码)。**F02 新增 console.log = 0**。
- dev server 日志(`.work/ee-ce/logs/backend.log`):裸 console.* 计数 0(错误经 Nest GlobalExceptionFilter 结构化输出)。

## 代码复审扫描项(无新增 error)

- Permission.update 键存在语义、nobody→role 不变量、subjects 重建后 wipe 顺序(R3)复核一致。
- permissions.service update targetType 已按 resolved type 判 team subjects(R4),create/update/create-dup 校验齐。
- Form.vue 两处渲染位(1829/1890)均叠加 `element?.permissions?.isAllowedToEdit !== false`,数据源为 useViewData formColumnData 的 lazy getter(reactive)→ 上下文正确。
- checkPermission:owner 短路、fail-open(空列表放行)、multi-grant 任一 deny 即 403、req.context 取 per-request context(R1 修正)复核一致。

## 环境/清理

- 测试 base pk0wpg07stpgg7n 及 duplicate/snapshot 副本已删除;`Base.delete` 后 nc_permissions / nc_permission_subjects 该 base 行 **0 残留**(清理钩子回归通过)。测试用户 f02r5l3-*(3 用户 + 5 base_users 行)已从 nocodb-dev 清除。
