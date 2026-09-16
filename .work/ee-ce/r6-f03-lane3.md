# r6-f03-lane3.md — F03 Data Permissions R6 复审(lane 3)

**PASS(0 error)**

- 审查对象:main @ 0633d8dfea(R5 修复批 ca8bb77622 在位;F03 实现链 7b10716231..b28787a54a..66e0ea343d..ca8bb77622)
- 后端 :8080 / 前端 :3000 全程健康,未发生中途重启
- 测试数据:f06l3-* 前缀 5 账号 + 1 base + 2 表,测毕全部清理(base 4 个 DELETE 200/404-已不存在;grants 0 残留)

## R6 增量 4 项回归(全过)

1. **摘要文案(无 grant 默认)**:UI Details→Permissions tab 实测——`Who can delete records: Editors & up`、`Table Visibility: Everyone`(ADD 组当时有 user grant 显示 Specific users,与 API GET 一致)。`usePermissions.getPermissionSummary` 仅 VISIBILITY 回退 Everyone,ADD/DELETE 显示 editors-and-up 底价。**在位**。
2. **VISIBILITY 组 Creators & up 选项**:弹窗实测选项全集 `Creators & up | Viewers and up | Specific users | Everyone | Nobody`;API 造 `role:owner` VISIBILITY grant → 弹窗回显选中 creators_and_up → 点同档 Save → API GET `granted_role:"owner"` 未降权。**在位**。
3. **nobody + 显式 granted_role → 400(create+update 对称)**:API 实测 create `{"granted_type":"nobody","granted_role":"editor"}` → 400;update PATCH 同 payload → 400;不带 role 的 nobody create/roundtrip → 200。代码位 `Permission.ts` insert :213-220 / update :379-386(`[CE-EE]` 标记)。**在位**。
4. **permissions.service.ts F03 TABLE 校验块 [CE-EE] 标记**:`packages/nocodb/src/services/permissions.service.ts:79`。**在位**。

## 集成矩阵(API 实测 :8080)

- **enforcement(matrix1.log 49 断言全绿)**:
  - fail-open:无 grant 时 editor/creator insert+delete(v1+v2)全 200;删 grant 后下一请求放行 ✓;owner 全程直通(grant 在场仍 200)✓;viewer 无 grant 写 = 403(CE ACL floor,非 grant 行为——fail-open 语义只对 ACL 允许角色成立)
  - ADD × role:editor:editor 200 / creator 200(power 比较)/ viewer 403 / v1+v2 同判 ✓
  - ADD × nobody:editor/creator 403、owner 200(v1/v2)✓
  - ADD × user(白名单语义,SDK evaluatePermission subject 命中=allow):subject editor 200、非 subject creator 403 ✓(首轮脚本预期写反,复验修正——产品行为正确)
  - DELETE × role/nobody:同构全过;ADD 与 DELETE 正交(仅 ADD grant 时 delete fail-open 200;仅 DELETE grant 时 insert 不受影响)✓
  - bulk:v2 bulk insert(数组)creator 过 creator-grant、editor 403;v2 bulk delete 按 DELETE grant 判;v1 bulkDeleteAll(`DELETE /api/v1/db/data/bulk/noco/:base/:table/all`)editor 403→删 grant 200 ✓
- **VISIBILITY(matrix2.log)**:nobody → viewer/editor 的 meta(404)、v2 data(404)、v1 data(404)、count(404)、aggregate(404)、base 表列表隐藏 全中;owner 直通 200;role:viewer → viewer 200;user 精确匹配 subject 200 / 非 subject 404;删 grant → Everyone 往返 200 ✓
- **公开表单 enforce_for_form**:form view share 后,匿名 POST `/api/v2/public/shared-view/:uuid/rows`:nobody ADD + enforce=true → 403;PATCH enforce=false → 200 ✓
- **校验对称**:create 侧 nobody+subjects 400 / nobody+granted_role 400 / role 缺 granted_role 400 / user 缺 subjects 400 / 非法 granted_type 400 / TABLE+FIELD 键 400 / 低于 minimumRole 400 / 重复键 400 / 不存在表 400 / editor 建 grant 403(ACL);update 侧 5 项对称 400 + role 缺键回落 existing 200 ✓

## R3 修复回归

- **SPECIFIC_USERS 空选 Save 拦截**:UI 实测切 Specific users(不选人)点 Save → toast "Select users"(i18n 键 `objects.permissions.inlineUserSelector.selectUsers`,非裸键)+ save 中止(弹窗未关、无 API 写)。**命中**(首次误报系脚本点了非目标元素,用 data-testid 复测确认)。
- **dirty-flag 保存生效**:UI 选人(f06l3-creator)保存 → API GET `{"granted_type":"user","subjects":[{id:usl36…creator}]}`。**命中**。
- **SPECIFIC_USERS 单选项可见可选**:弹窗三组 Specific users 均渲染、a-select 展开可搜可选。**在位**(v-if 死代码已去)。
- **owner-role grant 回显不降权**:见 R6-2,API→UI→API 往返 owner 保持。**命中**。
- **NOBODY 转换清列 + 复活守卫**:PATCH role→nobody 后 GET `granted_role:null`;随 PATCH `{granted_type:"role"}` 不带 role → 400;user→role 切换后 subjects 行清空(GET subjects=[])。**命中**。
- **duplicate 带 grants**:base duplicate 后副本 `/permissions` 带出 TABLE VISIBILITY nobody(entity_id 映射到新表 id ✓)与 FIELD RECORD_FIELD_EDIT user grant(subjects 保留 ✓、entity_id ≠ 源列 id ✓)。**命中**。
- **bulk 100 行性能**:实测无 grant best 491ms vs role:creator+ADD best 1146ms(~2.3x,3 次取最小,重测稳定)。归因见 E3/backlog 节——**残留为 backlog ⑪(FIELD per-row Permission.list),非 R3 修复失效**:R3 修复的 TABLE_RECORD_ADD 检查确认在 bulk 循环外仅执行一次(insert.ts :339-352),无逐行 TABLE 检查。

## 代码复审(git diff 7b10716231^..HEAD,16 源文件)

- R1-R5 修复全部在位:extract-ids 主路径 `req.context.ncTableId = model.id`(:236)+ v1 tableName fallback(:1109-1123)+ AclInterceptor VISIBILITY 门(:1378-1396,匿名回退/空 grant 短路/404 遮蔽);checkPermission any-deny 循环 + form-context enforce_for_form 豁免;delByPk/bulkDelete/bulkDeleteAll/nestedInsert/bulkUpsert(拆分后 toInsert 非空才查 ADD)hook 齐;`permissionDeniedMessage` per-key 文案(TABLE 键不泄漏 "field" 字样)。
- importPermissions(import.service.ts:173-209):getIdOrExternalId 映射、subjects 过滤(type==='user' && id)、逐 grant try/catch 容错(logger.debug 跳过)——正确;export.service.ts:724-748 export 侧按 model/field 过滤序列化。
- 无 console.log/debugger 残留(diff 新增行扫描零命中);无内部信息泄漏错误文案。
- i18n:Table 弹窗空选 toast 用 `objects.permissions.inlineUserSelector.selectUsers`(en.json :1155),F02 Field 弹窗同款已修。
- `[CE-EE]` 标记:5 个核心文件 15 处,R6-4 补标在位。

## 回归 smoke(F02/F05/F07/F08/F10)

F02 FIELD grant(403/creator 200/删 grant 200)✓;F05 variables list/create/delete ✓(key 需 UPPER_SNAKE_CASE,首测 400 系脚本 payload 非产品问题);F07 snapshot create+list ✓;F08 private base create+delete ✓;F10 dashboard create+delete ✓。

## 质量门

- `cd packages/nocodb && npx tsc --noEmit` → exit 0
- `pnpm test` → Test Suites 2/2,Tests **26/26**,exit 0

## UI 段(camoufox-cli,独立 session f06l3,:3000)

owner 登录 → base → Details → Permissions tab:三 key 摘要与 API GET 逐项一致(R6-1 命中)→ Configure 弹窗三组单选(含 Specific users 展开选人)→ 空选 Save 拦截(R3)→ 选人保存 API 落库(R3)→ API 造 owner VISIBILITY 回显 creators_and_up、保存不降权(R6-2)→ Nuxt error overlay 无、console.error(hook 会话内)0 条。**双零达成**。

## issues

(0 error)

- **minor 1** `packages/nocodb/src/models/Permission.ts:update()`:role→user PATCH 转换不清残留 `granted_role` 列(实测 user grant 带 `granted_role:"creator"` 残留;R3 只对 NOBODY 转换写 null、user→role 只清 subjects)。评估器按 granted_type 分支无行为影响;变体复活链 role:owner→user→role(不带 role)会经 existing 回落复活 owner,但 creator 本可直接 POST role:owner grant(minimumRole 不拦 owner),无提权后果。建议:user 目标转换时同 NOBODY 写 `granted_role=null`。非阻塞。

## E3 / 已知项(有诊断证据,不计 error)

- **bulk100 grant 开销 ~2.3x(491ms→1146ms)**= GOAL-STATE backlog ⑪:FIELD RECORD_FIELD_EDIT 检查逐行执行(insert.ts per-row checkPermission),每行一次 Permission.list(跨 qnap Tailscale RTT 主导,空 grant 时短路成本低);R3 修复的 TABLE 检查在行外已生效。附实测数据佐证 backlog 仍成立,建议后续仿 bulkUpdate 聚合提出行外。
- v1 按表 title 寻表 404(实测复现,getByAliasOrId 上游行为,改用 tableId 全通)——沿袭清单。
- sharedView meta 不消费 TABLE_VISIBILITY(上游 CE 预埋面缺失)——沿袭 backlog ⑧。
- v2 bulk delete 裸数字数组 → 422(BaseModelSqlv2.ts:4973 注释写 "400",实测 422;拒绝路径为 fork F03 加固、方向正确,仅码值与注释不符,文档级)。
- 环境:signup 账号默认 org/workspace no-access 需提权才能建 base;invite/登录会 bump token_version 使旧 token 401(UI/API 同账号互踢,R5 已知)。

## 测试装置说明(非产品问题,供复核)

- 首轮矩阵 24 FAIL 全系装置问题:枚举大小写(SDK 值为 `TABLE_RECORD_ADD` 大写)、invite 后 token 失效、bulk delete body 需对象数组、viewer CE ACL floor 预期错位、残留 grant 未清。修正后 49+33 断言实质全绿。
