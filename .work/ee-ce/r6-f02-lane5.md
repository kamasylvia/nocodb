# r6-f02-lane5.md — F02 R6 安全终审（lane5）

对象：4b26d7a23f（实现）→ 10e8d92729（R5 修复，本轮重点）。方法：源码审读 + nocodb-dev API 实测（owner=base owner、editor=base editor；测试 base 已清理）。

## 结论

**issues 列表（2 项，1 实质 + 1 卫生）**

1. `packages/nocodb/src/db/BaseModelSqlv2.ts:10539-10545:fieldPermissionEntityIds 三键 find() 单命中匹配可被 title↔column_name 交叉重名劫持，受限字段可被绕权写入（R5 引入回归）:改为 column_name 精确匹配优先（mapAliasToColumn 产物恒为 column_name 键）；updateLTARCols title 键路径单独处理或改用 flatMap 收集全部命中列（多拦仅误拒，无绕权）` —— 实测复现，见 §1d
2. `仓根 PATCH、-X（R5 commit 10e8d92729 误提交的测试残渣文件）:git rm 两文件，后续 commit 不再携带` —— 内容为 `400000000` 与 `{"msg":"Invalid entity undefined"}`，无凭证，但属垃圾入仓

其余安全面全部 PASS，见 §2-§5。

---

## 1. R5 修复复检（核心）

### a. create nobody+subjects → 400，DB 零行 ✓
`POST /api/v2/meta/bases/:base/permissions` body `{entity:field,entity_id:<Amount>,permission:RECORD_FIELD_EDIT,granted_type:"nobody",subjects:[{type:user,id:<editor>}]}` → `400 {"msg":"subjects are not allowed on nobody grants"}`。事后 `nc_permissions where base_id=...` 仅 1 行（即后续 b1 的干净 nobody），400 落 0 行 ✓。拒绝点在共享 validateGrantShape（Permission.ts:265-272），位于 metaInsert2 之前，无半写状态。

### b. update nobody+subjects → 400 ✓
`PATCH .../permissions/:pid` body `{granted_type:"nobody",subjects:[...]}` → 400 同消息。双层守卫（validateGrantShape:328-334 + update 内早期守卫:363-367）消息一致、判据一致（均只看 payload subjects），行为冗余但无矛盾。

### c. 干净路径 → 200 ✓
- create 干净 nobody → 200（b1）；update 干净 nobody → 200（c1）；create/update user grant + subjects → 200（c2/复检）；subject editor 写该字段 → 200；user grant 无 subjects create → 400。
- 附加不变量：user→nobody（payload 不带 subjects）→ 200 且 subjects 表被 R3 清理块清零（实测 c3 后 `nc_permission_subjects` join base = 0 行）。

### d. 三键匹配误匹配评估 → **实锤可构造，构成绕权（issue 1）**
前提实测（本仓行为）：
- 列 title 精确重复被服务端拒绝：rename 与 create 均 `422 ERR_DUPLICATE_IN_ALIAS`；
- title 与他列 **column_name** 的交叉重名**不被拒绝**：建表 body 显式 column_name≠title 时接受（实测建表 F02L5B：col1{title:PayX, column_name:Pay} 在前 + col2{title:Pay, column_name:Pay2}，HTTP 200）；重命名 title 撞他列 column_name 也放行（实测 rename colX.title→QQ == colY.column_name，200；仅大小写差异的 rename 亦放行）。

劫持机制（代码级）：数据主路径钩子检查的是 mapAliasToColumn 产物，键恒为写入列自身 column_name；`fieldPermissionEntityIds` 用 `find(c => c.column_name===cn || c.title===cn || c.id===cn)` 单命中。若存在**更早**的列其 title == 该 column_name，find 返回错误列，被限列的 id 永不进入检查列表 → fail-open。

端到端复现（构造表 F02L5C：colY{title:Q2, column_name:QQ} 在前，colX{title:QX→QQ, column_name:Q2} 在后，owner 对 colX 打 nobody）：
- control：F02L5B 对 title:Pay 列 nobody，editor `PATCH /records {"Id":1,"Pay2":"nope"}` → **403**（钩子正常）；
- 劫持：editor `PATCH /api/v2/tables/F02L5C/records {"Id":1,"QX":"hijack"}` → **200**，回读 QX="hijack" 落库；同型 200 复现于 v1 insert（POST /api/v1/db/data/noco/:base/:F02L5C）与 v3 PATCH（/api/v3/data/:base/:F02L5C/records，fields 包裹）。

归因：R5 前仅匹配 column_name，映射产物键=自身 column_name 精确命中，无此劫持；**R5 把 title/id 并入 find() 引入回归**。R5 commit message 自述「widened to column_name/title/id」正是根源。

可利用性边界：构造需要 creator 级 API（建表显式 column_name / 列重命名），editor 无法自建碰撞；攻击模型=creator 设置陷阱绕过另一位 admin 的 grant，或合法重命名意外撞名导致限制失效。属权限强制正确性 bug，非远程匿名可利用。

修复建议（最小）：映射产物路径按 `columns.find(c => c.column_name === cn)` 精确匹配；updateLTARCols 的 title 键路径（extractLinkFieldsByTitle 产物）单独传参走 title 优先匹配；或统一改 `flatMap` 收集**全部**命中列（交叉重名时多拦=误拒，方向安全）。

## 2. 修复新面
- 双层冗余一致性 ✓：create 无早期守卫、仅共享校验；update 两层判据/消息一致，subjects 均取 payload 值（existing subjects 不参与 nobody 判定，nobody 落库后由 R3 块兜底清 subject 行，实测 0 行）。
- 非列载荷键误匹配 ✓：数据路径钩子输入是 mapAliasToColumn 产物（仅 column_name 键，虚拟列/任意 meta 键已被剥离）；updateLTARCols 输入为 extractLinkFieldsByTitle 提取（仅 link 列 title 键）；`c.id===cn` 分支在真实载荷中不可达（列 id nanoid 不可能作为写入键），无 meta/嵌套键误拦通道。
- service 层（permissions.service.ts）✓：entity/permission 枚举校验、table entity 拒配（F03 预留）、synced 表拒配（调研 §7.9 落地）、entity_id 列存在性校验（不存在列 400 实测）、(entity,entity_id,permission) 去重、team subject 拒绝、update/delete 双重 base 归属校验。

## 3. 残余绕过面抽测（editor + nobody grant）
- v2 单条 PATCH 受限列 → 403 ✓（错误消息带字段 title，无 id 泄漏）
- v1 insert 受限列 → 403 ✓
- v3 PATCH 受限列 → 403 ✓
- bulk PATCH 数组受限列 → 403 ✓
- link：addChild（POST /api/v1/db/data/noco/:base/:table/1/hm/:linkColId/1）→ 403「field LinkD」✓（5 处钩子路径之一实弹验证）
- bulk PATCH 带 LTAR 键：editor/owner 均 200 且链接未写入（该版本 v2 bulk PATCH 对 LTAR 键静默忽略，owner 对照同样无写入）→ updateLTARCols 钩子实弹不可达，代码级确认 extractLinkFieldsByTitle 产物为 title 键、R5 宽化后钩子可命中（仅此为代码验证，无 API 实弹，记观察项非 error）
- 公共表单：view-create 路由在 v1/v2 meta 面未定位到，未走通实弹；代码级验证 public-datas.service.ts:827 设 `req.isPublicForm=true` → insert 钩子 isFormContext → checkPermission 匿名分支（BaseModelSqlv2.ts:10619-10640）：grant 存在且非全部 enforce_for_form=false → 403。逻辑自洽（观察项非 error）

## 4. fail-open / 提权 / 泄漏 / 探针
- 无 grant fail-open ✓：editor 写未限列 → 200（空 permission 列表与无匹配 grant 均直通，mcp.controller 契约保持）
- owner 直通 ✓：owner 写 nobody 列 → 200
- editor 管理面 ✓：permissionCreate/Update/Delete → 403；permissionList → 200（acl.ts:559 editor+ 只读，注释明示前端 lock 图标需要，设计内）
- 跨 base ✓：base2 上下文 PATCH/DELETE base1 的 permission id → 404（Permission.get 先经 context 内 list，找不到回落 metaGet2 亦为 context 域）；GET base2 permissions → 0 行，无跨 base 泄漏
- console.log 残留 ✓：六 commit 全量 diff `grep '^+' 'console.'` 零命中；NC 日志无 standalone console 输出通道（logger 统一）

## 5. 测试残留
- 测试 base F02R6L5 / F02R6L5B2 已 DELETE（200）；测试账号 f02r6l5.owner@gmail.com（super）、f02r6l5.editor@gmail.com（org-level-viewer + 各测试 base editor，base 已删）留在 nc_users_v2，前缀 f02r6l5 可识别，不影响生产（nocodb-dev 库）
- issue 2 的 PATCH/-X 文件在仓根工作区仍存在且已入 git

## E3 / 观察项（不计 error）
- updateLTARCols 与公共表单两条路径未实弹（前者 API 不消费 LTAR 键、后者 view-create 路由未定位），均代码级验证接线完整，无放行证据
