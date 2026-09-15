# r3-f03-lane3 — F03 Data permissions R3 终局收敛轮(集成测试 + 全 diff 复审)

> lane3 独立结论(与其他路隔离)。审查对象:7b10716231 + 2f5a57b0d3 + e1e996283c + 0a3e5fdab4 + c7a242cdf3 + 6cc43e0b81(git 4b26d7a23f^..HEAD 的 F02/F03 触碰面,27 文件 +2263)。

## 结论

issues(1 项 error,前端;其余 PASS):

- `packages/nc-gui/components/dlg/Table/Permissions.vue:370-377:已有 SPECIFIC_USERS grant 时仅增删 subjects(a-select v-model 改 states.users)不置 dirty,save() 在 :219 对 !dirty 项 continue,PATCH 不发出但仍弹「permission updated」成功提示,subjects 修改静默丢失:在 a-select 上加 @change="states[permission].dirty = true"(或 save 时与原 subjects 比较判定脏)`
- 同文件低危(同修复批次可顺带):`Packages/nc-gui/components/dlg/Table/Permissions.vue:262-265:新建 grant 选 SPECIFIC_USERS 未选任何用户点保存时 buildPayload 返回 undefined 被静默跳过并报成功(Field 版同场景弹 error 提示 selectUsers,行为不一致):users 为空时 message.error 并中止该项或整体保存`

不计 error 的注记(见「注记」节):service-user 无 ADD/DELETE hook 豁免(fail-closed 方向,待裁定)、bulkUpsert 单行纯 update 批 500(上游既有,owner 同样 500)、v1 alias GET by title 404(上游行为,F03 未触碰)、Permission.list 无缓存 N+1(F02 backlog ④ 沿袭)。

## 集成测试(dev server :8080,nocodb-dev,API 实测)

环境:owner(psql 提 super)/ creator / editor 三账号新 base + 4 表(t_add/t_del/t_vis/t_main+LTAR),grants 全部走 permissions API 写(psql 直改权限行会碰 NocoCache,未用)。脚本 /tmp/f03lane3/matrix*.sh,断言日志 matrix*.log。

### 1. 全矩阵(3 grant 型 × 3 角色 × insert/delete/update/bulk/visibility)— PASS

TABLE_RECORD_ADD(role:creator):
- editor v2 insert 403 / v1 alias insert 403 / bulk insert 403;creator 200;owner 200;editor update 不受拦 200 — 全过
TABLE_RECORD_ADD(role:editor 边界):editor 200、creator 200 — 过
TABLE_RECORD_ADD(user:[creator]):editor 403、creator(subject)200、owner 200 — 过
TABLE_RECORD_ADD(nobody):editor/creator 403、owner 200 — 过
TABLE_RECORD_DELETE(role:creator / nobody):v2 单删、v1 rowId 删、v2 bulk delete(数组)、v1 bulkDeleteAll(/all)四路径拦截/放行分界与上同构 — 全过
TABLE_VISIBILITY(role:creator):editor meta 404、data v2 404、data v2 count 404、v1 alias(表 id)GET/POST/bulk-all 404、表列表消失(creator/owner 列表保留且 meta 200) — 过
TABLE_VISIBILITY(nobody):editor/creator meta+data 404,owner 200 — 过
 VISIBILITY 与 DELETE/ADD grant 正交:仅他表 VISIBILITY grant 时本表 delete 不受影响 — 过

### 2. fail-open — PASS

无 grant 全路径 editor/creator/owner 200(v2 insert/v1 insert/v1 GET/PATCH/DELETE/bulkDeleteAll);删 grant 后下一请求放行(ADD/DELETE/VISIBILITY 三 key 各验一轮)— 过

### 3. 校验对称 — PASS(create 13 项 + update 8 项全 400)

create:非法 entity/permission/granted_type/granted_role、role 缺 granted_role、role 显式 null、viewer 低于 minimumRole(ADD 400;VISIBILITY 的 viewer 合法 200)、nobody+subjects、user 缺 subjects、team subject、TABLE+RECORD_FIELD_EDIT、FIELD+TABLE_RECORD_ADD、表不存在、缺 entity_id、重复 (entity,entity_id,permission) — 全 400
update(PATCH):非法 granted_role、viewer 低于 min、role+null role、nobody+subjects、user+team、user 缺 subjects → 400;nobody 合法切换、user+subjects 合法切换、enforce_for_form=false 持久化 → 200 — 全过
ACL:editor create/patch/delete grant 全 403(初测误报系脚本 token 硬编码,修正后确认)、list 200;creator/owner CRUD 200 — 过

### 4. VISIBILITY 专项 — PASS

meta 404(非 403,防 id 探测)/ data 路由全部动词 404 / 表列表消失 / v2 ?viewId= 404(主路径 ncTableId 覆盖)/ link 折叠:无权用户 nested link 列表仅返回 pk+pv(端点语义本就 pk+pv,无额外字段泄漏;深折叠消费面为上游预埋,单列表不可观测差异)/ 匿名表单见 §5 — 过

### 5. 公开表单匿名提交 — PASS(核心)

shared form + nobody ADD:匿名提交 403「You don't have permission to create records in t_del」;enforce_for_form=false 后匿名 200;删 grant 后匿名 200(fail-open);role:creator grant 下匿名 403、editor 403(enforce 默认 true)— 过
注:creator 携 token 走 public 端点提交也 403 — public 路由无 base 上下文,按匿名语义判,与 datas.service.ts:1213 R1 注释裁定(仅匿名公开表单可 claim form context)一致,非 error。

### 6. bulkUpsert 拆分语义 — PASS

v1 /upsert 端点:2 行纯 update 批(挂 nobody ADD)editor 201 放行(拆分后 toInsert 行才查 ADD);混合批(含 insert 行)403「create records in t_add」(文案正确);owner insert 201 — 过

### 7. 回归 — PASS

F05 变量:create(key 大写蛇形)200/list 200;F07 snapshot list 200;F10 dashboard list 200;F08 base 读(editor)200;F02:editor PATCH 受限字段 403「edit the field Qty」、owner 200;ADD×FIELD_EDIT 组合:editor 有 ADD(role:editor)+ payload 含受限字段 → 403 FIELD 文案、干净 payload → 200 — 全过
`npx tsc --noEmit` EXIT=0;`npx jest Fork.spec` 26/26 passed

## 代码复审(4b26d7a23f^..HEAD 全 diff)

- fieldPermissionEntityIds(BaseModelSqlv2.ts):三键匹配(column_name/title/id)、Set 去重、system/pk/FK/isSystemColumn 全滤、R6 全收集防交叉重名劫持 — 正确
- checkPermission:owner 直通 → 空 grant fail-open → multi-grant any-deny(顺序无关,denied 短路)、匿名仅 form 语境可被 enforce_for_form=false 豁免、TABLE/FIELD 分支文案泛化(permissionDeniedMessage)、req.context 而非 this.context 存 load 标记(R1 修复) — 正确
- Permission.update 三守卫顺序:validateGrantShape → NOBODY+subjects 拒(写前)→ role 必有非空 role(R4 null 语义)→ user 必有 subjects → nobody 落库后 subjects 双删清理(R3,幂等) — 正确,实测 S8b 8 例对称
- validateGrantShape 共享:create requireSubjectsForUser / update 留 subjects 回退,enum+minimumRole 双侧一致 — 正确
- extract-ids:c7a242cdf3 主路径 ncTableId 赋值(tableId 分支 :239)+ legacy tableName 分支(:1109)+ gate(:1385,空权限短路 + isServiceUser 豁免 + 404 tableNotFound) — 正确;v2 ?viewId= 实测被覆盖
- data-table.service.ts:398 失实注释已修;datas.service:1213 cookie 传递 + 非 form 语境注释;public-datas.service isPublicForm 标记 — 正确
- 权限行清理:Base.delete/softDelete 均 Permission.deleteByBaseId(Base.ts ×2)— 正确
- 探针/console.log/debugger 零残留(grep diff 全扫);错误消息无内部信息泄漏(404 tableNotFound / 403 仅 permission 文案)
- Node.vue gate flag 化 / useEeConfig 解 gate / useExpandedFormStore 去 isEeUI 短路 / grid Table.vue ADD 消费(?? true 兜底)/ Content.vue 三行摘要 + 弹窗入口 / e1e996283c VISIBILITY 默认 Everyone(loadCurrent + getPermissionSummary 双侧)/ 0a3e5fdab4 渲染修复 — 复核一致

## 注记(非 error)

1. ADD/DELETE hook 无 service-user 豁免(VISIBILITY gate 有 isServiceUser 豁免,f03-research §5 建议 fork 放行)——现行为 fail-closed,自动化/同步用户在有 grant 的表写数据会被 403;待裁定,记 fork 限制即可。
2. 上游既有缺陷(非 F03 引入):bulkUpsert 单行纯 update 批 500 — BaseModelSqlv2.ts:4205 afterUpdate(existingRecords[0],…) 在 1 行 update 批时 existingRecords 为空(:3781 仅特定路径填充),owner/creator/editor 全复现,F03 diff 前后该段逐字一致(git show 4b26d7a23f 对照);多行批正常。
3. v1 alias GET by 表 title 404(POST/按 id 正常):F03 diff 未触碰 dataHelpers/Model/data-alias.controller,属上游/环境既有;测试改按表 id 断言。
4. Permission.list deliberate 无缓存 + subjects N+1(F02 backlog ④):中间件高频面沿用,每请求一次 indexed meta 读,实测无感知延迟。
5. viewId-only 路由族(datas.controller '/data/:viewId/',:240 分支不设 ncTableId)本构建对全部用户 404 Cannot GET(路由不可达),无实际缺口面。
6. 测试脚本层面曾出现 4 类假失败(PermissionKey 枚举大写、PATCH body 形状、数据路由限流间歇、脚本 token/残留 grant 污染),均修正后复验通过;实现侧未因脚本修正而改变任何结论。

## 证据

- 断言日志:/tmp/f03lane3/matrix*.log(PASS/FAIL 逐行;矩阵最终 pass 47+19+16+16+6,失败项全部归因脚本并修正复验)
- 关键实测引用: nobody ADD 匿名表单 403 文案、混合 upsert 批 403 文案、VISIBILITY meta/data 404、editor patch grant 403、tsc EXIT=0、jest 26/26
- 上游缺陷对照:`git show 4b26d7a23f:packages/nocodb/src/db/BaseModelSqlv2.ts` :4155(:4163)与现 :4204(:4212)同构
