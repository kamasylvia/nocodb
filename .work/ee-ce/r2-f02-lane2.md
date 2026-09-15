# r2-f02-lane2 — F02 Edit field permissions R2 收敛轮(lane2)

> 审查对象:4b26d7a23f(实现)+ e85a421d92(R1 修复),HEAD=工作树干净。
> 方法:静态复审两 commit diff + 当前源码;nocodb-dev 上 API 实测(脚本 `.work/ee-ce/r2-f02-lane2-run*.sh`,输出 `r2-f02-lane2-out*.txt`)。
> 隔离:未读其他 lane 报告与 r*/patrol-* 归档。

## 结论

**NOT PASS — 2 issues**

- `packages/nocodb/src/db/BaseModelSqlv2.ts:3058,10575,10613` + `packages/nocodb/src/services/permissions.service.ts:83` :debug console.log(`[F02-Q]/[F02-R]/[F02-P]/[F02-Z]`)残留在 HEAD,R1 commit message 声称 "Debug probes removed" 与事实矛盾;`[F02-Q]` 在每次 nestedInsert(v1 数据插入、表单提交)打印内部列 id,TASK 验收清单要求无 console 残留 :删除 4 处(连带 `eslint-disable no-console` 注释)。
- `packages/nocodb/src/models/Permission.ts:317-329`(update):nobody 转换只置 `granted_role=null`,**不清 nc_permission_subjects 残留行**;R1 commit message 声称 "nobody transition clears granted_role/subjects"。实测(DB 验证):user-grant(subject=[editorB]) → PATCH `{granted_type:'nobody'}` → `granted_role` NULL ✅ 但 subjects 残留 1 行 ❌。语义后果已实测:nobody → 再 PATCH `{granted_type:'user'}`(不带 subjects)返回 200,残留 subjects 使原 subject **静默恢复**编辑权(脏态复活授权)。建议:`granted_type===NOODY` 分支同时 `metaDelete(PERMISSION_SUBJECTS, {fk_permission_id})`(或切回 user 时强制显式 subjects、忽略存量)。(笔误自纠:实现时用枚举 `PermissionGrantedType.NOBODY`。)

## 角色矩阵(API 实测,nocodb-dev)

写动作 = PATCH `/api/v2/tables/:tid/records`(v2)与 POST `/api/v1/db/data/v1/:baseId/:tableId`(v1,走 nestedInsert)。

| grant \ 用户 | owner | creator | editor | commenter | viewer |
|---|---|---|---|---|---|
| role=editor | 200 | 200 | 200 | 403 | 403 |
| role=creator | 200 | 200 | 403 | 403 | 403 |
| role=viewer(commenter)create | — | — | — | **400**(minimumRole=EDITOR 拒)同左 |

- service 拒绝 viewer/commenter grant → 剩余可授权角色仅 editor/creator,符合 `RECORD_FIELD_EDIT.minimumRole=EDITOR` ✅
- v2 insert 受限字段:editor+creator-grant → 403;editor+editor-grant → 200(授权角色可写)✅
- v1 insert(nestedInsert)受限字段:editor+creator-grant → 403;owner → 200 ✅
- commenter/viewer 的 403 消息来自 base 层数据写 ACL("...with the roles: Viewer"),与字段层语义叠加,不冲突

## R1 修复逐项验证

| 项 | 结果 | 证据 |
|---|---|---|
| multi-grant any-deny(直插 DB 双 role 行)| ✅ | [creator,editor] → editor 403 / creator 200;倒序 [editor,creator] → editor 403(order 无关)|
| role+user 组合裁决 | ✅ | role=editor+user=[editorB]:非 subject editor 403(收紧达成)、subject editorB 200、owner 200 |
| duplicate (entity,entity_id,permission) create | ✅ | 二次 create → 400 "A permission grant already exists..." |
| user grant 空 subjects create / update | ✅ | 均 400(POST subjects:[]/缺省;PATCH subjects:[])|
| table-entity create | ✅ | 400 "Table permissions are not supported yet" |
| nobody 转换清 granted_role | ✅ | DB `coalesce(granted_role)` = NULL |
| nobody 转换清 subjects | ❌ | DB subjects=1 行残留(见 issue 2);切回 user 无 subjects 仍 200(stale 复活)|
| nobody 拒绝原 subject / 放行 owner | ✅ | editorB PATCH 403;owner PATCH 200 |

## nestedInsert / v1 / 公共表单

- 匿名 shared form(form view POST `/share` 生成 uuid → POST `/api/v2/public/shared-view/:uuid/rows`):带受限字段 → **403**(enforce_for_form 默认 true)✅;不带 → 200 ✅
- `enforce_for_form=false`:匿名带受限字段 → 200 且值落库(DB 验证 `anon3|optout`)✅ ——opt-out 语义成立
- grant 删除后匿名带受限字段 → 200(fail-open 契约)✅
- v1/v2 双路径在 grant create→delete 循环中**下一请求立即生效**,无缓存陈旧观察 ✅

## 语义终审(代码)

- checkPermission 匿名分支(`BaseModelSqlv2.ts:10619-10640`):`!user && grants 存在` 时,isFormContext 且全部 grant `enforce_for_form===false` → 放行,否则 403。语义自洽:匿名仅存在于表单上下文,opt-out 即放开;非 form 匿名(理论不可达)denied 保守正确 ✅
- multi-grant 循环对「role 命中 + user 未命中」判 deny(任一 grant 拒绝即 denied)——收紧语义,实测验证 ✅
- 校验错误消息质量:dup/table-entity/invalid-column 均为明确 400 文案,可定位 ✅
- fail-open 契约保持:无 grant 行 = 放行(实测);owner 直通(checkPermission 前置 + `Permission.isAllowed` 双层)✅

## Notes(非 error,不改判)

- `BaseModelSqlv2.ts:10581-10584` R1 注释断言 "BaseModelSqlv2 instances are cached per model",与同文件 `getRlsConditions` 注释(10679-10682,"constructs a fresh BaseModelSqlv2 on every call")矛盾。行为安全(`req.context ?? this.context` 两向均正确),但注释会误导后续维护,建议随 issue 1 一并更正。
- `Permission.list` 对每条 grant 单独查 subjects(N+1);R1 注释已声明弃缓存放正确性的取舍,基数量级可接受。
- `datas.service.ts:1216` `dataInsertByViewId` 对经该路由的一切请求(含认证用户)置 `isPublicForm=true`,认证提交者也被套用 enforce_for_form 判定;该旧路由在 API 层未直接暴露(探测 404),现网影响未观察到。

## 外部限制

无 E3(全程直连 dev server + nocodb-dev,未重启进程)。

## 测试残留

- 测试数据:base `f02r2l2-base`(popo6369gr9gwmb)+ 用户 f02r2l2-*(nocodb-dev);全部 permission 行已清理(count=0)。
- 脚本与输出:`.work/ee-ce/r2-f02-lane2-run{,2,3,4}.sh` / `r2-f02-lane2-out{,2,3,4}.txt`。
- 脚本侧噪音说明:run1/bash3.2 assoc-array 失效、run3 v1 路由表名用 id、part4 列名大小写引号——均为测试脚本问题,已在后续轮次修正,不影响上列结论(403/400 判定均为修正后实测)。
