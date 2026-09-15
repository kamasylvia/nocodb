# r8-f02-lane2 — F02 R8 终局收敛轮(集成测试 + 全 diff 代码复审)

**结论:PASS**(0 error。集成测试 ~80 断言 0 真失败;整个 diff 代码复审无 error 级发现)

审查对象:4b26d7a23f + e85a421d92 + 3b9dcbdbc6 + a8fc2c2966 + b95fbf7f74 + 10e8d92729 + 0711660b8c + ca6c81f5a6(HEAD=ca6c81f5a6,工作区干净)。
环境:dev server :8080(未重启)、nocodb-dev(显式硬编码,未触碰 Infisical DB_NAME)、测试 base pyrc4htxbe86cbf(测毕已删)。

---

## 1. R7 修复相关性验证(代码级)

`packages/nc-gui/components/dlg/Field/Permissions.vue:281-290`:`watch(() => props.visible, (v) => { if (v) { void loadCurrentGrant(); void loadMembers() } }, { immediate: true })`。
- immediate 使组件 setup 时即以初值执行回调:挂载即 visible=true 的路径(Content.vue `openField` 先设 activeField 触发 v-if 挂载、父级直接 v-model:visible=true)都会执行 `loadCurrentGrant()` → 回显既有 grant → save 走 PATCH,不再重复 POST。
- visible=false 常规挂载路径:watch 照常触发,行为不变。两种打开路径全覆盖。
- ColumnMenu.vue:989-996 传参齐全(field-id/field-title/field-uidt,diff 上下文曾截断致疑,实读确认无缺)。
- **修复相关性成立**。UI 端到端由 lane4 验证(本 lane 按 prompt 分工做代码级确认)。

## 2. 集成测试结果

### 2.1 全矩阵(拦截/放行分界)

grant 挂 Secret 列(c9aq8bfomg81x61,RECORD_FIELD_EDIT):

| 形态 | editor | creator | owner |
|---|---|---|---|
| 无 grant(fail-open) | 200 全路径 | 200 | 200 |
| nobody | PATCH/insert/v1/bulkInsert/bulkUpdate/bulkUpdateAll/bulkUpsert/addChild 全 403;不触该列 200 | 403 | 200(直通) |
| role=creator | 403 | 200 | 200 |
| role=editor | 200 | — | — |
| user(subject=editor) | 200 | 403 | 200 |
| link 列 LTAR grant(nobody) | addChild 403 | — | addChild 201 |

覆盖路径:v2 PATCH、v2 insert、v1 insert(POST /api/v1/db/data/noco/:base/:table)、v1 PATCH、bulkInsert(/bulk)、bulkUpdate(PATCH /bulk)、bulkUpdateAll(PATCH /bulk/all)、bulkUpsert(/bulk/upsert,body 为数组——单对象 500 是上游 payload 形态约束,非 F02 回归)、addChild/POST links。任意「不触受限列」的写全放行(按列裁剪正确)。

### 2.2 multi-grant 任一拒绝即 403(顺序无关)

三键唯一性由 create 拒 duplicates,故第二 grant 经 psql 直插 nc_permissions(user-grant + nobody 并存):editor PATCH → 403;删测试行后恢复 200。checkPermission 逐 grant 评估、任一 denied 即 break→403,与行序无关(BaseModelSqlv2.ts:10610-10625)。

### 2.3 fail-open 契约

- 无 grant:editor/creator 全写路径 200(矩阵 Phase 1)。
- grant delete 后下一请求:字段级 grant、LTAR 列 grant 删除后 editor addChild/PATCH 立即恢复(201/200)。
- permissions 空列表直接 return(BaseModelSqlv2.ts:10572);req.permissions 预载(MCP)优先。

### 2.4 校验对称(create/update × 400 全对)

create(entity 非法 / 未知 column / permission key 非法 / 缺 granted_type / nobody+subjects / user 无 subjects / role 缺 granted_role / granted_role 非法枚举 / viewer 低于 minimumRole=EDITOR / team subject / table entity F03 拒 / v1 路径同步)= 全 400;update(role grant 上 viewer / bogus / 显式 null / 空串 → 400;nobody+subjects → 400;user 空 subjects → 400;nobody→role 缺 role → 400)= 全 400。nobody 落库清 granted_role + subjects(DB 实测 0 行,Post-R3 不变量)。显式 null/'' 走 `'granted_role' in data` presence 语义(as-is 校验,extractProps 保留非 undefined 值——SDK commonUtils.ts:20 交叉验证),R4 语义成立。

### 2.5 ACL 面

editor:create/PATCH/DELETE grant → 403;GET permissions → 200(permissionList editor+,acl.ts:556);creator:create/DELETE grant → 200。F03 保留面:table entity create 明确 400(upcoming)。

### 2.6 公共表单(enforce_for_form)

共享 form view(uuid a38c9325…,body 需 `{"data":{…}}` 包裹——初测误发平铺对象致误判 200,已修正):
- nobody grant + enforce=true:匿名提交带 Secret → 403;不带 → 200。
- PATCH enforce_for_form=false:匿名带 Secret → 200 且 Secret 实际落库(实测行内值 anonCs);认证 editor PATCH → 403(豁免仅限匿名 form 语境,isFormContext 限定正确)。
- 恢复 enforce=true:匿名 → 403。切换闭环。
- datas.service.ts:1216 dataInsertByViewId 传 param.cookie(认证 view-submit),isPublicForm 仅 public-datas.service.ts:825 标注——两路分离正确。

### 2.7 回归

- F05:GET variables owner 200;POST UPPER_SNAKE key 200(小写 400 为 F05 既有校验);editor GET 403 = F05 既有 ACL(baseVariableList 非 editor),非 F02 引入。
- F07:GET snapshots 200。F08:base meta GET(editor)200。F10:dashboards GET 200 / POST 200。
- `npx tsc --noEmit` = 0;`npx jest` = 26/26(2 suites)。
- base 删除后 nc_permissions / nc_permission_subjects = 0 orphan(Base.delete/deleteByBaseId 级联,Base.ts:462/719 实测)。

## 3. 代码复审(整个 diff,24 文件)

逐项核对:

1. **fieldPermissionEntityIds**(BaseModelSqlv2.ts:10528-10549):Set 去重、三键匹配(column_name/title/id,R5)、四重过滤(system/pk/uidt ForeignKey/isSystemColumn)、**全收集**而非 find-first(R6:decoy 列 title===他列 column_name 时 over-block,安全方向)。bulkUpsert/bulkUpdate/updateLTARCols 跨行聚合进单个 Set。
2. **checkPermission**(10555-10678):owner 直通(在 PermissionRoleMap 映射后);reqContext 取 `req.context ?? this.context`(R1:实例缓存 per-model,stale context 修正);permissions 取 `req.permissions ?: Permission.list(reqContext)`;空列表 fail-open return;任一 grant deny → 403;enforce_for_form=false 仅在 isFormContext 跳过;匿名非 form 一律 403;错误消息仅暴露列 title(配置面可见,无泄漏)。
3. **update() resolved-type 三守卫**(Permission.ts update):①validateGrantShape(resolved granted_type/role/data.subjects)→ ②nobody+subjects 拒 → ③role 需非空 granted_role(final-stored-value,`?? ''` 归一)/user 需 subjects(data.subjects ?? existing.subjects);写入后 nobody 清 granted_role、末尾再删 subjects(R3 payload 顺序无关)。subjects 重建 = delete-all + insert,无残留(实测)。无任何写前未校验路径。
4. **validateGrantShape 共享**:create/update 同函数;enum/minimumRole(PermissionMeta)/subject 形状/nobody+subjects 全覆盖;options.requireSubjectsForUser 仅 create。
5. **豁免通道完整性**(实测+读码):bulkInsert 显式 skipPermissionCheck(insert.ts:345,import.service 3 处 true 均落此);bulkUpsert/bulkUpdate `!raw`;bulkUpdateAll `!skipValidationAndHooks`(column rewrite 内部路径);v2 单条 insert 无 skip——信任上游 import/copy 走 bulkInsert/raw;bulk-data-alias bulkDataUpdate 不透传 skipPermissionCheck(签名无此参,不存在静默丢弃)。
6. **前端一致性**:usePermissions.isAllowed 只评 grants[0] —— 与 create 的三键唯一性约束自洽(不可能 >1);owner 直通、fail-open、enforce_for_form 与后端同一规则(共享 SDK evaluatePermission:nobody→false、rolePower undefined→false、user subject 严格相等,安全方向);useViewData lazy getter 修冻结;loadPermissions force bypass 修 stale;错误时 loadedFor=null 允许重试。
7. **探针/残留**:diff 及工作区 0 console.log/debugger/TODO/FIXME。
8. **性能**:Permission.list cache-free(R1 注释论证 NocoCache 键空间正确性问题;索引化 meta 小查询;MCP req.permissions 预载;写路径非热点)——接受,备注级。checkPermission 匿名/denied 两分支 label 查询逻辑重复——纯重复,非缺陷。

## 4. E3 / 外部限制

无。全程直连,后端未重启。

## 5. 证据落盘

- 测试脚本与 token:/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane2-r8/{matrix.sh, fixups.sh, fixups2.sh, fixups3.sh, fixups4.sh, publicform.sh}
- 关键响应原文已随各脚本运行输出记录于本报告(状态码+body 摘录)
- 测试数据:base pyrc4htxbe86cbf / T1 msst76r2pgfsr0y / Secret c9aq8bfomg81x61 / LTAR caks6fluls7vk0y —— 已删除,0 orphan
