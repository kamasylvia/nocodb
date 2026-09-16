# R6 F03 Data permissions — lane 4 独立审查报告

**结论：issues（1 项）**

- HEAD = main 0633d8dfea（R6 修复批 ca8bb77622 之上 1 个 chore），工作树仅 `.work` 流程文件未跟踪，源码干净。
- 质量门：`tsc --noEmit` exit 0；jest Fork 桶 26/26（2 suites passed，371s）。
- 集成矩阵约 90+ 断言全过（详见下）；跨功能 F02/F05/F07/F08/F10 smoke 全过；UI 段全过。

## issues 列表

1. **`packages/nocodb/src/db/BaseModelSqlv2/insert.ts:369` + `packages/nocodb/src/db/BaseModelSqlv2.ts:10650`：bulk 插入性能未达 R3 修复目标（有 grant 时 ~1.95x 放大）**
   - 现象：100 行 v2 bulk，creator + `TABLE_RECORD_ADD role:creator` grant 下耗时 avg 959ms（934/1045/898），无 grant avg 493ms（476/512/491），**ratio 1.95**。任务书 R3 回归项要求"与无 grant 同量级（R3 前放大 ~2x，已修）"，实测仍 ~2x。
   - 根因：R3 把 TABLE_RECORD_ADD 检查提到了 bulk 级一次（insert.ts:347，注释明言避免 per-row round-trip），但 **F02 FIELD 级检查仍为 per-row**（insert.ts:369，每行 `fieldPermissionEntityIds` + `checkPermission`）。`checkPermission` 的 permissions 获取路径（BaseModelSqlv2.ts:10650-10653）只认 `req.permissions`（仅 mcp.controller.ts:84 预载），data 路由每次 fallback `await Permission.list(reqContext,...)`；而 `Permission.list` 是 cache-free 直查（Permission.ts:84-119，R1 决策），100 行 = 100 次 permissions 查询 + 有 grant 时再 ×N subjects 查询。实测增量（~460ms/100 行）与每行 2 次 meta 查询吻合。
   - 建议：`checkPermission` 的 fallback 改为先复用 `reqContext.permissions`（`Permission.list` 本身已写入该字段，Permission.ts:117），即 `req.permissions ?? reqContext.permissions?.length ? … : await Permission.list(...)`；或 bulk 循环外预载一次 permissions。一行级改动即可把 grant 存在时的 list 次数从 100 降到 1。
   - 定级依据：单路属实且已实测（3 样本 ×2 组、跨两次独立进程），非环境抖动。

## 实测证据（关键断言摘要，method/path → 状态码）

### 全矩阵（node 测试器，/tmp/r6lane4/matrix.mjs，41 PASS）
- fail-open：editor v2 插/改/删 无 grant 全 200。
- ADD nobody：v2 单插 403 / v2 bulk 403 / v1 单插 403 / v1 bulk 403；owner 直通 200；update 200、delete 200（正交）；删 grant → 插 200。
- ADD role 阶梯：role:editor → editor 200/viewer 403/creator 200；PATCH→creator → editor 403/creator 200；PATCH below minimum（viewer for ADD/DELETE）400；PATCH 非法枚举（superuser）400；PATCH 空 granted_role 400；POST role 缺 granted_role 400；POST 非法 granted_type/permission/entity 全 400。
- ADD user 型：user:[editor] → editor 200/creator 403；POST user 缺 subjects 400；POST nobody+subjects 400。
- R1 单 grant：同 key（entity,entity_id,permission）第二 grant POST 400（nobody、user 型各验证一次）。
- duplicate 键 400 ✓。
- DELETE nobody：v2 bulk 删 403、owner 200、editor 插 200（ADD 无 grant）、v1 bulk 删 403 + v1 deleteAll 403（独立进程复验）、删 grant 后 deleteAll 200。
- DELETE role:creator：editor 403/creator 200。
- bulkUpsert 拆分（独立进程）：含插入行批 403（"create records" denied）；纯 update 批不要求 ADD——返回 500 为上游 E3（见 E3 节，owner 零 grant 对照同炸）。

### VISIBILITY（vis.mjs，26 PASS）
- nobody：editor v2 meta/data/count/aggregate 全 404，v1 data/count 404，base 表列表隐藏 TableA；owner meta/data 200 直通；删 grant 全恢复 200（Everyone 往返）。
- role:viewer：viewer 200、editor 200；PATCH role:commenter 200（commenter 权力 3 > minimumRole viewer 2，合法——审查脚本初期误设 400 期望，已修正认知，非缺陷）。
- user:[creator]：creator 200 / editor 404（精确匹配）。

### 公开表单（form5.mjs，9 PASS）
- share form view：匿名 GET meta 200；无 grant 匿名提交 200；ADD nobody + enforce_for_form=true → 匿名 403（owner 正常 API 200 直通）；false → 匿名 200；true 往返 403；删 grant → 匿名 200。

### R6 增量（f3.mjs/f4.mjs + UI）
1. 摘要：无 grant 时 ADD/DELETE = "Editors & up"、VISIBILITY = "Everyone"（UI 截图 ui-state2.png）；有 role:owner VISIBILITY grant 时显示 "Creators & up"。
2. Table 弹窗 VISIBILITY 组 5 档含 **Creators & up**（截图 ui-perm-dialog.png）；API 造 role:owner VISIBILITY → 弹窗回显选中 Creators & up；点 Save → API 侧 granted_role 仍 `owner`（不降权）。
3. POST nobody+granted_role → 400；PATCH nobody+granted_role → 400；POST/PATCH nobody 不带 role → 200，行 granted_role 保持 null。
4. permissions.service.ts L79 `[CE-EE] F03: TABLE-entity grant validation (R4 lane5: marker hygiene)` 标记在位（代码审）。

### R3 修复回归
- NOBODY 转换：role→nobody PATCH 200 → GET granted_role = null（key 存在值为 null，独立复验）→ PATCH `{granted_type:role}` 不带 role → 400（复活守卫）→ 带 role → 200 且 role=editor（不复活旧值）。
- user→role 切换：subjects 1 → 0（清空）。
- dirty-flag：弹窗 Specific users 键盘选人（f06l4-editor）→ Save → dialog 关闭 → API 侧 `TABLE_RECORD_ADD user subjects=us7cjtaf9xt7m1oz` 落库正确。
- 空选守卫：Specific users 空选点 Save → toast "Select users"（报错）+ dialog 未关（全 save 中止），API 侧无任何 grant 变更（截图 ui-after-save2.png）。
- duplicate/restore 带 grants：源 base 表级 VISIBILITY nobody + 字段级 RECORD_FIELD_EDIT user:[editor] → `POST /api/v2/meta/duplicate/:baseId` → 副本 2 grants 全带出：VISIBILITY entity_id 映射新表 id、granted_type nobody 保留；FIELD entity_id 映射新 Title 列 id、subjects 保留 editor id；副本 enforcement 生效（editor 访问副本表 403——副本不带成员角色，ACL 先于 VISIBILITY 404，与 R5" duplicate 不带成员角色"backlog 一致）。importPermissions 代码审（import.service.ts:173-209）：id 映射走 getIdOrExternalId、subjects 只留 type==='user' 且有 id、per-grant try/catch skip 不中止、缺 entity/permission continue——容错正确。

### 跨功能回归
- F02：RECORD_FIELD_EDIT user:[editor] → editor PATCH 200 / creator 403 / owner 200 / 删 grant creator 200。
- F05：variable create（key 需 UPPER_SNAKE_CASE）/list/delete 200。
- F07：snapshot create + 列表 200（快照副本 base 出现并随清理删除）。
- F08：`{title, is_private:true}` 建 base 200 + 建表 200 + 非协作者 editor GET base 404。
- F10：`POST /api/v2/meta/bases/:baseId/dashboards` 200 + list 200。

### 代码复审（diff 7b10716231^..HEAD + 现行文件）
- checkPermission any-deny：BaseModelSqlv2.ts:10700-10710 多 grant 全评估 any-deny 在位；owner 直通 :10636；form 语境 enforce_for_form :10678-10683。
- extract-ids：ncTableId 主路径 :234-240（[CE-EE] 标记在位）+ v1 `:tableName` fallback :1111-1121（[CE-EE] 标记在位）；VISIBILITY gate :1381-1398，404 遮蔽语义。
- importPermissions：见上，正确。
- console.log/debugger 残留：F03 相关文件（Permission.ts / permissions.service.ts / permissions.controller.ts）grep 0 命中；F03 全量 diff grep 0 命中。
- 错误文案：permissionDeniedMessage（BaseModelSqlv2.ts:10738-10748）仅含表/字段 label，无内部泄漏。

### UI 段（camoufox-cli 独立 session，:3000）
- owner 登录 → f06l4-base → TableA → Details → Permissions tab：三 key 摘要与 API 一致（含 owner VISIBILITY grant 的 Creators & up 显示）。
- Configure 弹窗：ADD/DELETE 4 档、VISIBILITY 5 档，Specific users 三处均可见可选。
- 切 Specific users 键盘选人保存 → API 落库正确（见 R3 节）。
- Nuxt/vite error overlay：none；全程截图渲染正常（camoufox-cli 无 console dump 命令，以 overlay + 截图为证）。

## 测试基建观察（非产品 error）
- **同进程长会话下 v1 bulk 端点偶发表寻址 404**：matrix 测试器进程内 `DELETE /api/v1/db/data/bulk/.../all`、`.../upsert` 返回 `ERR_BASE_NOT_FOUND: Base '<tableId>' not found`（把 :tableName 当 base/alias 解析）；同 URL 独立进程重放恒为正确行为（200/403）。与已知上游 E3「v1 按 title 寻表 404」同族（getByAliasOrId/寻址健壮性），v1 bulk 断言以独立进程复验为准。
- camoufox click 对 ant-design select option 不触发选中（键盘 ArrowDown+Enter 正常）——工具层兼容问题，非产品。

## E3（上游/环境，不计 error）
- v1 bulkUpsert 纯 update 批 500（BaseModelSqlv2 afterUpdate，上游 2023 代码）——本次以 owner 零 grant 对照复现同炸，归类确认。
- v1 按表 title 寻表 404（getByAliasOrId 上游行为）——本次 v1 断言全部走表 id。
- sharedViewMeta 不消费 TABLE_VISIBILITY（上游预埋面缺失，backlog ⑧）——未复测，沿袭清单。
- **环境注记（新）**：signup 用户默认 `workspace-level-no-access`，baseCreate 403。本 lane 按隔离纪律仅将自家 owner 账号（f06l4-owner@t.local）在 nocodb-dev `workspace_user` 提为 `workspace-level-creator`（等价 workspace 邀请，非 super 提权）。后续 lane 环境搭建需同款操作或邀请流。

## 清理
- TableA/TableB 行清空（deleteAll）；f06l4 base 全部 grants 删除；f06l4-base / copy / copy_1 / Snapshot…of f06l4-base / f06l4-private 全部软删（DB 复核 deleted=true）；测试变量删除；测试账号 f06l4-* 保留（环境惯例）。
- 测试脚本与证据在 /tmp/r6lane4/（matrix1.res、vis.res、f4.res、form.res、dup2.res、regress2.res、jest.log、tsc.log、截图 ui-*.png）。
