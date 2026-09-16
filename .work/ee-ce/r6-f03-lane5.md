# R6 F03 Data permissions — lane 5 独立复审报告

**结论:PASS(0 error)**

- HEAD = main 0633d8dfea(R6 审查对象 = R5 修复批 ca8bb77622);tsc exit 0;jest Fork 桶 26/26。
- 断言总量:API/集成 ~130 项 + UI 8 项,除标注 E3/预期修正外全部通过。

## R6 专属增量(4 项全实测)

1. **Details Permissions tab 摘要(无 grant)** — PASS。实测文本:"Who can add records: Editors & up"、"Who can delete records: Editors & up"、"Table Visibility: Everyone"(usePermissions.ts getPermissionSummary 改为按 permissionType 判定,ca8bb77622 在位)。
2. **Table 弹窗 VISIBILITY 组 Creators & up + owner 回显不降权** — PASS。弹窗截图(ui-r6-dialog-options.png):VISIBILITY 组 = Creators & up / Viewers and up / Specific users / Everyone / Nobody(Editors & up 按设计排除);API 造 `role:owner` VISIBILITY grant → 摘要显示 "Creators & up" → 弹窗 radio 回显选中 Creators & up(截图 ui-r6-owner-vis-dialog.png,不再出现无选中态)→ Save → API GET 确认 `TABLE_VISIBILITY role owner` 不降级。
3. **nobody + granted_role 对称拒绝** — PASS。POST `{granted_type:nobody, granted_role:editor}` → 400;PATCH 同型 → 400;不带 role 的 nobody create → 200 / patch(enforce_for_form)→ 200。守卫在 Permission.ts insert(~:210)与 update(~:379)双侧。
4. **permissions.service.ts F03 TABLE 校验块 [CE-EE] 标记** — PASS(代码审,~:79)。

## 集成测试(全矩阵,API 实测 :8080,账号 f06l5-*)

- **ADD/DELETE × nobody / role(editor|creator|viewer) / user × editor/creator/owner × v2 单条/bulk、v1 单插/单删/bulk/deleteAll/upsert**:全过。v1 路径经表 id(R3 附录 E3:title 寻表 404,实测 `Table 't1' not found` 连 owner 也 404,换 id 即 200)。role:viewer 为 ADD/DELETE 的 minimumRole 合法档:editor/creator 过、viewer 因上游 ACL(`acl.ts dataInsert`,与 F03 无关)仍 403 —— grant 为限制型语义非提权,与 F02 一致,记观察。
- **multi-grant any-deny**(role:editor ADD + nobody DELETE):insert 过 / delete 拒 / owner 直通,全符合。
- **update 与 ADD/DELETE 正交**:nobody-ADD 下 PATCH 200、nobody-DELETE 下 PATCH 200。
- **bulkUpsert 拆分语义**:v1 `/upsert` mixed 批(role:creator ADD,editor)→ 403(要求 ADD)✓;纯 update 批 → 500 为上游 E3(afterUpdate,owner 零 grant 同炸,行本身已 update)——**不 403 即拆分生效**。**v2 `?upsert=true` 无 upsert 语义**:swagger-v2.json 零处提及 upsert,实测带存在 Id 的 POST 走普通 insert(PK 重新生成,253→254),v1/v2 均不消费该参数;此前轮次若以 v2 upsert 验证拆分为误测。非 fork 问题。
- **VISIBILITY**:nobody → editor/viewer 的 meta/data(v1+v2)/count/aggregate 全 404、表列表消失(includeAllTables 列表中 t1 计数 0)、owner 通;role:viewer 档 viewer/editor 200;user 精确匹配(授 editor:editor 200 / creator 404 / viewer 404);删 grant 后 Everyone 放行(往返)✓。
- **公开表单**:form view share → 匿名 meta 200;nobody-ADD 默认 enforce_for_form=true → 匿名提交 403;PATCH false → 200(往返)✓。匿名 rows GET 对 form view 恒 404(与 grant 无关,lane4 P3 的 200 未复现)——上游 form rows GET 语义,记 E3 观察;VISIBILITY nobody 下匿名 rows 404(fail-safe 遮蔽方向)。
- **校验对称(create/update)**:nobody+subjects、role 缺 granted_role、user 缺 subjects、非法 granted_type/permission/entity、ADD 低于 minimumRole(viewer)、重复键、跨 base 表 entity_id → 全 400 ✓。

## R3 修复回归(b28787a54a)

- **弹窗 dirty-flag / SPECIFIC_USERS 保存生效**:切 Specific users → 成员下拉选 f06l5-editor → Save → API `TABLE_RECORD_ADD user subjects=[use0sxczjdxkyfz5]` 落库 ✓。
- **空选 Save 中止**:Specific users 未选人点 Save → toast "**Select users**"(正常文案,66e0ea343d i18n 修复生效,非裸键)→ 弹窗保持打开、既有 owner VISIBILITY grant 未被删(API 复核仍在)✓。
- **NOBODY 转换**:PATCH role→nobody → GET granted_role=null ✓;随后 PATCH `{granted_type:role}` 不带 granted_role → 400(复活守卫)✓。
- **user→role 切换 subjects 清空**:PATCH 后 GET subjects=[] ✓。
- **bulk 100 行性能**:同 creator token 三轮中位 no-grant ≈540ms / with-grant ≈950ms(≈1.7x,首轮 925ms 系冷启动噪音);v1 持平(1035 vs 953ms)。与「R3 前 ~2x 已修」一致,非回归。
- **duplicate/restore 带 grants**:主 base 携 VISIBILITY nobody(表级)+ RECORD_FIELD_EDIT user(subjects=editor,Qty 列,字段级)→ `POST /api/v2/meta/duplicate/:baseId` → 副本 /permissions 带出 2 条 grant:VIS entity_id 映射新表 id、FIELD entity_id 映射新列 id、subjects 保留、granted_type 保留,8/8 断言全过(importPermissions 代码审:getIdOrExternalId 映射、subjects 仅留 user 型有 id、逐 grant try/catch 容错,均符合)。

## 代码复审(diff 7b10716231^..HEAD)

- console.log/debugger 残留:0;[CE-EE] 标记 27 处。
- checkPermission(BaseModelSqlv2.ts:10620):owner 短路、fail-open 空 grant、any-deny 循环(order 无关)、form context enforce_for_form 过滤、文案 permissionDeniedMessage 业务化无内部泄漏 ✓。
- extract-ids(c7a242cdf3):主路径 `req.context.ncTableId = model.id` + v1 tableName alias fallback + AclMiddleware VISIBILITY gate(404 遮蔽、isServiceUser 豁免、空 grant 零成本)✓;v1 data-route VISIBILITY 实测生效(nobody 下 v1 data 404)。
- importPermissions/exportPermissions:序列化含 idMap 映射与 subjects 附 email,见上 ✓。

## 回归 smoke(F02/F05/F07/F08/F10)

- F02:RECORD_FIELD_EDIT nobody → editor PATCH Qty 403 / owner 200 / 删 grant 200 ✓。
- F05:variables create(key 需 UPPER_SNAKE_CASE)/ list / delete 200 ✓。
- F07:snapshot create → completed(轮询)→ restore 触发 200,副本 base 产生后清理 ✓。
- F08:`POST /api/v2/meta/bases {is_private:true}` → 200 且 flag 回读 true ✓。
- F10:dashboard create/list/delete 200 ✓。

## UI 段(camoufox-cli,:3000,owner)

登录 → base → t1 → Details → Permissions tab:三 key 摘要与 API 一致(含 owner/user grant 回显)→ Edit 弹窗三组单选完整(Specific users 可见可选)→ user 型选人保存落库正确 → 空选 Save toast 正常。Nuxt error overlay:无;console error:camoufox-cli 无 console 读取命令,以 overlay 不存在 + 全程截图无错误弹层为证(方法学限制,非豁免)。截图:ui-r6-tab-summary.png、ui-r6-dialog-options.png、ui-r6-owner-vis-dialog.png、ui-r6-specific-users.png、ui-r6-empty-save-toast.png、ui-r6-su-selected.png。

## E3(上游,有诊断证据,不计 error)

1. v1 `/upsert` 纯 update 批 500(afterUpdate,上游 2023 代码;实测行已 update,owner 零 grant 同炸)。
2. v1 按表 title 寻表 404(getByAliasOrId 上游行为;连 owner 也 404,换表 id 即 200)。
3. 匿名 form-view GET rows 恒 404(与 grant 无关);sharedView meta/rows 对 VISIBILITY 的消费与 lane4 记录存在出入(backlog ⑧ 沿袭)。
4. v2 records API 无 upsert 参数(swagger 零提及,`?upsert=true` 被无视)——矩阵设计口径修正,非缺陷。

## 测试隔离与清理

仅使用 f06l5-* 前缀账号(4 个)与自建 base/表;未触碰他 lane 数据。清理:wipe 全部 grants、删除主 base 及 copy/snapshot/restored 派生 base(DB 复核 nc_bases_v2 全部 deleted=true)、快照登记与变量/dashboard 已删、测试账号保留(workspace 角色为非提权的 workspace-level-*,未提全局 super)。未运行任何 dev-backend*.sh / pkill / 重启后端。
