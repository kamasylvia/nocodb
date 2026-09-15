# R8 F02 复审报告 — lane5(终局收敛轮:功能全量集成测试 + 整 diff 代码复审)

**结论:PASS**(0 error)

- 审查对象:4b26d7a23f + e85a421d92/3b9dcbdbc6/a8fc2c2966/b95fbf7f74/10e8d92729 + 0711660b8c + ca6c81f5a6(六 commit + 1 fix),diff 面 21 文件 +1625/-53。
- 环境:dev server :8080(nocodb-dev),新建 base `p588ezh84xteliv`(f02r8l5-1789355913),表 t1/t2/t3,4 账号(owner super 提权 + editor×2 + creator)。

---

## 1. 集成测试(全量)

### 1.1 全矩阵拦截/放行(41 断言,41/41)

grant 维度(nobody / role(editor) / role(creator) / user(EDB) / 无 grant)× 用户维度(editor B / editor C / creator / owner)× 路由维度(PATCH v2 单条 / insert v2 / bulkInsert / bulkUpdate v1 bulk / bulkUpdateAll `.../all?where=` / bulkUpsert `.../upsert` / v1 insert `/api/v1/db/data/noco/` / v1 update)全部断言:

| grant | editor | editor C | creator | owner |
|---|---|---|---|---|
| 无 grant(fail-open) | 200/201 全路由 | 200 | 200 | 200 |
| nobody(Secret) | 403 全 8 路由 | 403 | 403 | 200 |
| role(editor) | 200 | 200 | 200 | 200 |
| role(creator) | 403(patch+bulkUpsert 抽验) | — | 200 | 200 |
| user(EDB) | 200 | 403 | 403 | 200 |

- Scope 隔离:nobody grant 下仅 PATCH Name → 200(未波及字段不受限)✓
- 写含受限字段任一路由整体 403、不写则 200;bulkInsert 混合行(受限/非受限)→ 403 ✓
- grant DELETE 后下一请求放行(fail-open 恢复)✓
- grant 热切换 nobody→role→user→delete 全程即时生效(无缓存滞后)✓

### 1.2 R6 修复(code 0711660b8c)代码级 + 实况确认

- 三键收集:title / column_name / id 三种 key PATCH 受限列均 403(3/3)✓
- **decoy 碰撞实况**:新建 decoy 列(title=`secret`, column_name=`secret_decoy`,id c3kie0guz0bgv19),对受限列(title=`Secret`, column_name=`secret`)作 nobody grant → editor PATCH key `secret`(同时命中 decoy.title 与受限列.column_name)→ **403**(全收集 over-block 安全向);owner 同 key → 200 ✓。`fieldPermissionEntityIds`(BaseModelSqlv2.ts:10529)Set 全收集 + system/pk/FK/isSystemColumn 过滤实现正确。

### 1.3 R5/R3/R4 校验对称(22/22)

create × 13:nobody+subjects / role 缺 granted_role / user 缺 subjects / granted_role 非法枚举 / granted_role=viewer、commenter(低于 minimumRole=EDITOR)/ entity_id 不存在列 / entity=table / field+TABLE_RECORD_ADD / user+team subject / 非法 entity 值 / 非法 permission 值 / 缺 entity_id / 重复 grant → 全 400 ✓
update × 8:nobody+subjects / role+granted_role=null / role+granted_role='' / role 非法枚举 / 切 user 无 subjects / 切 user 带 team subject / 切 role 低于 minimumRole / 非法 granted_type → 全 400 ✓(R4 resolved-type 三守卫与 nobody subjects 清理均在 Permission.update:310-437 落实,顺序:validateGrantShape → resolved targetType 不变量 → 存值校验 → 写后 nobody subjects 二次清理)

### 1.4 ACL(6/6)

- editor:POST/PATCH/DELETE permission → 403(creator+ 写);GET → 200(R2:editor 只读可见)✓
- creator:GET → 200 ✓;acl.ts permissionList 在 base scope(creator+)且 EDITOR.include 显式放行 permissionList: true,viewer/commenter 不继承 ✓

### 1.5 公共表单 enforce_for_form(全链路)

- 表单视图共享(vw18rkhg6cbuqmi7 / uuid 4241d5ed),匿名 POST `/api/v2/public/shared-view/:uuid/rows`,载荷需 `{"data":{...}}` 信封(controller `body: req.body?.data`)
- nobody grant + enforce_for_form=true(默认)→ 匿名带 Secret → **403** "You don't have permission to edit the field Secret"(错误消息仅字段 title,无内部泄漏);匿名不带 Secret → 200 ✓
- PATCH grant enforce_for_form=false → 匿名带 Secret → **200 且值落库**(行 27 Secret=form-ok)✓
- 匿名 actor 走 service user(usranonymous,无角色)→ checkPermission 非 owner → evaluatePermission 拒绝;`isFormContext` 只在 public-datas.service.ts:827 标记,v1 view submit(datas.service.ts:1216-1221)刻意不带 —— 判定正确

### 1.6 link 路径抽测

- LTAR 列(Links, cmvw0gzj0potypc)作 nobody grant → editor addChild `POST /api/v2/tables/:t2/links/:col/records/1` → **403**;owner → **201** ✓(CE 原生 5 挂点 + R1 补的 updateLTARCols 路径一致)

### 1.7 回归抽测(F05/F07/F08/F10)

- F05:GET /bases/:id/variables 200 [];POST(key/value)200,变量创建成功(bv2xlhz0yjhjzu6e)✓
- F07:GET /bases/:id/snapshots 200 ✓
- F10:GET /bases/:id/dashboards 200 ✓
- F08:GET base → is_private=false 字段正常返回 ✓
- 静态:后端 `tsc --noEmit` 0 error;后端 jest(Test Suites 2 / **Tests 26 passed 26**)✓

---

## 2. 代码复审(整个 diff)

### 2.1 后端

- **fieldPermissionEntityIds**(BaseModelSqlv2.ts:10529):Set 去重;`column_name || title || id` 三键全匹配收集(R6);过滤 system/pk/uidt=ForeignKey/isSystemColumn。空 payload 返 []。实现与实测(1.2)一致。
- **checkPermission**(:10568):owner 直通 → req.permissions(MCP 预载)或 Permission.list(fail-open 契约:空列表直接放行)→ 逐 entityId 取 grants,`!user` 分支只在表单上下文尊重 enforce_for_form=false,否则 403 → 多 grant 逐条评估**任一拒绝即 403**(denied break,顺序无关)→ 错误消息仅字段 title。per-request 加载标在 req.context(R1 修复,注释说明 BaseModelSqlv2 实例缓存陷阱)。多 grant 场景 API 层被 duplicate 拒绝(permissions.service create),仅 psql/import 可造,代码仍按 most-restrictive 实现,正确。
- **8 处数据挂点**:updateByPk(:2815)/ nestedInsert(:3057,带 isFormContext)/ bulkUpsert(:3661,raw 跳)/ bulkUpdate(:4501,raw 跳)/ updateLTARCols(:4731,新 guard)/ bulkUpdateAll(:4790,skipValidationAndHooks 跳)/ insert.ts single(:69)/ insert.ts bulk(:345,`skipPermissionCheck` 豁免)。skipPermissionCheck 消费方:import.service(2494/2536/2603,快照/复制路径)、bulk-data-alias 透传 —— 与上游注释契约一致。raw/skipValidationAndHooks 跳过均为可信内部路径(导入/选项重命名),判妥。
- **Permission model**:list 无缓存(R1 决策注释:正确性优先,per-request context.permissions 复用),insert/update/validateGrantShape 共享校验,update 后 nobody subjects 二次清理(顺序无关),delete/deleteByBaseId 级联 subjects;Base.delete/softDelete 两处均挂 deleteByBaseId(Base.ts:462/719)。
- **permissions.service/controller**:FIELD entity 限定 RECORD_FIELD_EDIT;TABLE entity 显式 400(F03 预留);synced 列拒配(防 API 直调,风险点 #9 关闭);duplicate (entity,entity_id,permission) 拒绝;update/delete 校验 base 归属;controller v1+v2 双路径 + @Acl 四 op + noco.module 注册(243/335)。
- datas.service:1216 传 param.cookie(v1 view submit 不再 fail-open);public-datas:827 isPublicForm 标记仅匿名路径。

### 2.2 前端

- **useEeConfig**:仅 blockTableAndFieldPermissions→false,未全局翻 isEeUI ✓
- **gate 换 flag**:View.vue(3 处)/ Details.vue / ColumnMenu.vue / MultiColumnMenu(未触碰,EE-only 裁剪符合调研裁定);全部 `[CE-EE]` 标注
- **usePermissions.ts**:懒加载 once-per-base + force 刷新(R2);base 切换清空防串;isAllowed owner 直通与后端同规则;grants[0] 取值安全(API 强制单 grant);决策共用 utils/tableFieldPermission(SDK evaluatePermission),前后端同源
- **Permissions.vue 弹窗**:R7 修复(ca6c81f5a6)确认 —— watch `props.visible` 带 `{ immediate: true }`(:190-202),Content.vue 挂载即 visible=true 场景先 loadCurrentGrant 再可 save,无 stale default + 重复 POST;onBeforeUnmount 复位 visible(R2);EDITORS_AND_UP=删除回默认语义一致
- **Content.vue**:permissions tab 实装(字段列表 + summary + 编辑入口);**Tooltip.vue** 接真实 isAllowed(无 entityId 保持 allow-all,stub 调用方兼容);**useViewData.ts** lazy getter(R1:静态快照冻结问题修复,access 时求值保响应式);Form.vue 两处 isAllowedToEdit!==false 隐藏受限字段
- **探针/残留**:diff 新增行 grep `console.(log|debug|info)|debugger|TODO|FIXME|probe` → **0 命中**;错误消息无内部 id/栈泄漏

---

## 3. E3 与观察项(均不计 error)

- **E3(环境,有诊断)**:共享 dev server 在多 lane 并发压测窗口出现请求体服务端截断(body-parser "Expected ',' or ']' ... position 5/7/9" 随机偏移 → 裸 "400")。诊断:nc 抓包 curl 发出的 wire bytes 完全正确(Content-Length 20,body 原样),同请求单发稳定 200;窗口期批量请求被服务端截断。属 5 lane 共享单实例的环境限制,复测(串行+间隔)全数通过,非 F02 代码问题。
- **观察(上游遗留,非 F02 diff 面)**:`bulkUpsert` 单行 PK 命中 update 路径时 `afterUpdate(existingRecords[0], ...)` 中 existingRecords 仅在 merge-fields 分支填充(BaseModelSqlv2.ts:3686,PK 分支不填)→ 500 "Cannot read properties of undefined (reading 'Id')",写入本身已落库。该代码来自上游 sync commit 58ed76ab44("chore: sync may"),F02 diff 未触碰此区域,owner(无 grant)同樣复现,与本功能无关,建议另行立案。

---

## 4. 判定

- 集成:全矩阵 41/41、校验对称 22/22、ACL 6/6、公共表单全链路、link 403/201、R6 三键+decoy、R7 immediate 代码确认、回归 F05/F07/F08/F10、tsc 0、jest 26/26 —— **0 error**
- 代码复审:八挂点 + skip 契约 + fail-open + 校验对称 + 前端 gate/响应式/弹窗回显 —— **0 error**
- 探针残留 0;测试遗留 grant 行已清(nc_permissions base 内 0 行)

**PASS — 建议 F02 计入本轮 0 error(R8)。**
