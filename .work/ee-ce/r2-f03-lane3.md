# r2-f03-lane3 — F03 Data permissions R2 收敛轮(独立复审)

审查对象:7b10716231(F03)+ 2f5a57b0d3(R1 修复)+ e1e996283c(VISIBILITY 默认 Everyone)+ 0a3e5fdab4(dialog 渲染修复)。
方法:整个 F02/F03 触碰面 diff 逐行复审 + nocodb-dev 实测集成测试(新独立 base `f03r2l3-base` / pmy8dkue2lflsn7,workspace w9qi3ljd,owner/editor/creator 三号)。

## 结论:issues(2 修复必修 + 2 minor)

1. `packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts:1107` (2f5a57b0d3) :**R1 修复放错位置,v1 data-alias 路由 TABLE_VISIBILITY bypass 未修复(critical)**。fallback 加在 `legacyExtractIds` 尾部,但该方法只被"URL 无 `:baseId/:baseName` 段"的路由走(app.module ExtractIdsMiddleware=APP_GUARD → `use()` 117-490:`params.baseId||params.baseName` 存在即走新路径);v1 data-alias 家族 `/api/v1/db/data/:orgs/:baseName/:tableName` 带 baseName 段 → 走 `use()` 新路径,该路径**从不设置 `req.context.ncTableId`**(全文赋值点仅 1100/1113,均在 legacyExtractIds 内)→ AclMiddleware 的 VISIBILITY gate(1378,前置条件 `req.context?.ncTableId`)对该家族永不触发。且 fallback 自身条件 `!req.context.ncTableId` 在 legacyExtractIds 内恒 false(能设 ncBaseId 的分支都已设 tableIdToCheck)——**fallback 是死代码**。commit message 对 540-620/959-990 的分析全部针对 legacyExtractIds,对真实执行路径(use() 新路径)失察。实测证据:建 `TABLE_VISIBILITY granted_type=nobody` grant(perma2fl4qefgvah26,DB 确认存在)后,editor 对 `/api/v1/db/data/w9qi3ljd/<baseId>/<tableId>` 的 GET/POST/PATCH/DELETE 全部 **200**(GET 返回真实数据行、POST 插入成功);同表 v2 路由同用户 404。建议:在 `use()` 新路径 base 解析成功后按 `params.tableName` 解析 model 并设 `req.context.ncTableId`(顺带修复上游 UI-ACL 遮蔽 1359 在该家族同样失效的上游缺口),或在 AclMiddleware gate 内自行解析。
2. `packages/nc-gui/composables/usePermissions.ts:126-134` (e1e996283c) :getPermissionSummary 对 entity=TABLE **不分 permission**,无 grant 一律返回 EVERYONE → `permissions/Modal/Content.vue:95` 三行摘要中 TABLE_RECORD_ADD / TABLE_RECORD_DELETE 行无 grant 时显示 "Everyone",实际默认语义为 editors-and-up(摘要误导)。建议:`permissionType===TABLE_VISIBILITY ? EVERYONE : EDITORS_AND_UP`(dialog loadCurrent 已按 key 区分,摘要未跟上)。
3. `2f5a57b0d3`(仓库卫生):`.v1a`/`.v1b`/`.v1c` 三个调试残留文件(内容为 curl 错误响应)被该 commit **加入** git,而其 message 却写 "remove stray PATCH/-X junk files from repo root"。建议 `git rm` 三文件。
4. `packages/nocodb/src/db/BaseModelSqlv2.ts` checkPermission 匿名分支(语义歧义,minor):`!user` 且 `isFormContext` 时 `grants.every(g => g.enforce_for_form === false)` 即放行,**不区分 granted_type**。实测 nobody ADD grant + enforce_for_form=false → 匿名公共表单插入成功(Id 24)。f03-research §5 裁定为 "匿名:nobody/user 全拒 fail-closed"。实现是自洽的 grant 级豁免语义且 UI 未暴露该开关(仅 API 可达),但与裁定字面不符——需裁定后择一对齐(代码或文档)。

## 逐项结果

### R1 修复验证(重点)
- v1 data 路由 VISIBILITY:**FAIL → issue 1(critical)**。nobody grant 下 editor v1 GET/POST/PATCH/DELETE = 200/200/200/200(expect 全 404);creator v1 GET 200(expect 404);owner 200 ✓;同 grant 下 editor v2 GET 404 ✓、editor v2 meta 404 ✓(gate 仅对走 legacyExtractIds 的路由生效)。
- 重复 grant → 400 ✓(`A permission grant already exists for this entity and permission`)。
- entity×permission 配对(2f5a57b0d3):entity=dashboard × TABLE_RECORD_ADD → 400 ✓。
- NOBODY 清理(2f5a57b0d3):update payload 到 NOBODY 时 `delete granted_role/subjects` ✓(代码复审;PATCH nobody+subjects → 400 ✓)。
- dialog getPermissionLabel 导入(0a3e5fdab4)/SPECIFIC_USERS undefined payload 跳过 ✓(代码复审 + buildPayload 无 null 路径,`!payload` 涵盖 undefined)。

### 全矩阵(T2,37/37 ok)
- baseline 无 grant:owner/editor/creator insert/update/delete/visibility 全 200(fail-open)✓。
- ADD nobody:editor/creator insert+bulk 403,owner 200,update/delete/visibility 不受牵连 ✓。
- ADD role:editor:editor/creator/owner 全 200 ✓;ADD role:creator:editor 403、creator/owner 200 ✓。
- DELETE nobody:v2 单删+批删 403,creator 403,owner 200;update/insert 不受牵连 ✓。
- DELETE role:creator:v1 delByPk 删 403(hook 与路由无关)✓;bulkDeleteAll(`/api/v1/db/data/bulk/:wsId/:baseId/:tableId/all`,tableId 形式)editor 403 / creator 200 ✓。
- VISIBILITY role:creator:editor v2 404、creator/owner 200 ✓;role:viewer:editor/creator 200 ✓。
- v1 insert under ADD nobody → 403(insert.ts single hook 经 nestedInsert/v1 路径)✓。
- grant 删除后下一请求放行(403→200)✓。

### 校验对称(T4,17/17)
- create:nobody+subjects / role 无 granted_role / user 无 subjects / ADD+viewer、DELETE+viewer(低于 minimumRole)/ 非法 permission / 非法 entity(dashboard)/ 非法 granted_type / 非法 subject type / 不存在 table → 全 400 ✓;TABLE_VISIBILITY+viewer → 200 ✓(minimumRole=viewer 合法)。
- update:nobody+subjects → 400 ✓;role grant 置空 role / 低 role(viewer)/ 假 role(wizard)→ 400 ✓;切 user 无 subjects → 400 ✓;role→role 正常 200 ✓;user grant 仅 PATCH enforce_for_form(subjects 保留)→ 200 ✓。

### 公共表单(T5)
- baseline 无 grant:匿名提交 200 ✓。
- ADD role:creator(enforce_for_form 默认 true):匿名 403 ✓;ff=false:200 ✓。
- ADD nobody:匿名 403 ✓;nobody+ff=false → 200(见 issue 4)。
- 对照:F02 field nobody grant → 匿名 403(`You don't have permission to edit the field Name`)证明 isFormContext 链路正常。

### 回归
- F05:variables create(key 需 UPPER_SNAKE_CASE)+delete 200 ✓。
- F07:snapshot 创建成功;**ADD nobody grant 存在下 snapshot 仍 completed ×2**(duplicate skip 通道未被 F03 hook 误伤)✓。
- F08:diff 未触碰 F08 面(AclMiddleware F08 块原样);浅抽 base meta 200。
- F10:dashboard create/list 200 ✓。
- F02:field grant 403(匿名)+permissionList 200 ✓。
- 后端 `npx tsc --noEmit` = 0;`npx jest`(Fork 桶)26/26 passed(463s)。

### 复审扫项
- fieldPermissionEntityIds:全收集(Set 去重)+ system/pk/FK 过滤 + column_name/title/id 三键 ✓(BaseModelSqlv2.ts:10581)。
- checkPermission 任一拒绝即 403、multi-grant 顺序无关(denied break)✓;单表单 grant 唯一约束使同 key multi-grant 不可达(设计如此)。
- update() resolved-type 三守卫顺序(NOBODY+subjects / ROLE 缺 role / USER 缺 subjects)先写后验证齐备;subjects 重建 + NOBODY 尾部再清 ✓。
- validateGrantShape 共享(create/update 同源)+ minimumRole 强制 ✓。
- 探针/console.log:diff 面零新增(extract-ids:1164 `console.log(e)` 为上游遗留,commit 69a29568c7);无 debugger。
- 错误消息:VISIBILITY 404 遮蔽存在性 ✓;ADD/DELETE denial 文案 per-permission(`create/delete records in <title>`),不泄漏 grant 内部结构 ✓。
- 测试资产:独立 base `pmy8dkue2lflsn7`(f03r2l3-base)+ 脚本 `.work/ee-ce/f03r2l3-*.sh`,grants 已清理,不影响其它 lane。

## E3
无。全部断言在 localhost:8080(nocodb-dev)实测达成,无外部限制。

## 备注(供裁决)
- v1 路由正确格式为 `/api/v1/db/data/:workspaceId/:baseId/:tableId`(orgs 段须为真实 workspace id,baseName/title 形式在 middleware `Base.get` 处 404)——R1 轮声称 "v1 GET returns 404 with nobody grant" 的复核若用错 URL 段(如 title),得到的 404 是 base/table 解析失败而非 gate 生效,可解释 R1 轮误判已修复。
- issue 1 修复影响面小(补 `use()` 新路径的 ncTableId),修复后需重跑 T1(v1 段)+ T2 VISIBILITY 段回归。
