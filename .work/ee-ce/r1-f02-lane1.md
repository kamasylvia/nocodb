# r1-f02-lane1 — F02 Edit field permissions 集成测试 + 代码复审（R1 轮 lane1）

**结论：issues（1 error + 4 minor 验证缺口）**

- `packages/nc-gui/composables/usePermissions.ts:isAllowed`：前端缺 owner 短路，nobody grant 下 owner 被 UI 锁死而后端放行——前后端判定漂移，建议 error（代码级证据充分，UI 运行态未浏览器实测）
- 4 个 minor 验证缺口（bogus granted_role / 空 subject_id / 重复 grant / table entity 任意 key），均实测复现，均为惰性行可删除，无安全越权面
- fail-open 契约、per-field 挂点、缓存即时性、skip 通道、回归面：**全部实测通过**
- 测试产物：`.work/ee-ce/tmp-r1-f02-lane1/`（matrix.log/supp*.log，143 条断言；env.sh 已脱敏）

---

## Issues

### E1（error）前端 owner 无直通，UI 与后端判定漂移
- 位置：`packages/nc-gui/composables/usePermissions.ts` `isAllowed`（以及其调用的 `utils/tableFieldPermission.ts` → SDK `evaluatePermission` 链）
- 事实：后端 `checkPermission`（BaseModelSqlv2.ts:10525 附近）与 `Permission.isAllowed` 对 `granted_type=nobody` 有 owner 短路（`getProjectRole(user)===OWNER` / `mappedRole===PermissionRole.OWNER → true`）；前端 `isAllowed` 直接 `evaluateTableFieldPermission(grant, {userId, permissionRole})`，SDK `evaluatePermission` 对 NOBODY 分支 `return false`，无 owner 特判
- 后果链（代码级）：`smartsheet/header/Cell.vue:60-63` `isAllowedToEditField=false` → 表头 ncLock；`grid/canvas/composables/useCanvasTable.ts:549/1904` `isEditRestricted` → canvas 网格 inline 编辑被禁——base owner 在 nobody grant 字段上 UI 显示不可编辑，但后端 PATCH 实际 200（实测 3e）
- SDK 注释明示「frontend usePermissions 与 backend Permission.isAllowed 必须同一规则」；后端规则含 owner 直通（mirrors hasTableVisibilityAccess），前端漏配
- 建议：`usePermissions.isAllowed` 头部加 `if (currentUserPermissionRole.value === PermissionRole.OWNER) return true`（与后端同位置短路）
- 注：owner 在 UI 上仍无法编辑（前端硬禁），但后端可写——数据一致性无破坏，属行为不一致/可用性缺陷；UI 运行态未经浏览器实测，判定基于完整消费链代码证据

### M1（minor）granted_role 未做枚举校验，bogus 值产生「事实永拒」grant
- 位置：`packages/nocodb/src/services/permissions.service.ts` create/update（仅校验 granted_type，granted_role 直透）；`models/Permission.ts` insert 同
- 实测：POST granted_role='bogusr' → 200（s4a）；随后 creator PATCH 该字段 → 403（s4b）——SDK `evaluatePermission` rolePower(undefined) 比较 false = 拒一切非 owner
- 建议：granted_type=role 时校验 `Object.values(PermissionRole).includes(granted_role)`

### M2（minor）user 型 grant 接受空/缺失 subject id
- 位置：`services/permissions.service.ts` create（只拒 team 类型，不验 subject.id）；`models/Permission.ts insertSubjects` 照单全插
- 实测：subjects=[{type:'user',id:''}] → 200（s6a，首次 6a 因测试脚本传空串同样入库，nc_permission_subjects.subject_id=''）；效果=该 grant 拒所有非 owner（s6b creator 403；u1b 证明正确 id 时 editor 200）
- 建议：subject.id 非空校验（可加：subject 用户须为 base 成员）

### M3（minor）同 (entity, entity_id, permission) 无唯一性守卫，grants[0]-only 求值产生顺序依赖语义
- 位置：`services/permissions.service.ts` create（无重复检查）；`checkPermission`/`usePermissions` 均只取第一条
- 实测：同一 Title 上先 role-creator 再 user(editor) 两行均 200（s5a/s5b）；随后 subjects 内 editor 被拒（s5c，403）——若 user grant 排前则放行，行为取决于行序
- 说明：单 grant-per-field 与仓内惯例一致（hasTableVisibilityAccess 亦 `.find()`），UI 弹窗本身维持单 grant；缺口仅在 API 直调
- 建议：create 时同键唯一性守卫，或求值改为「任一 grant 放行即放行」

### M4（minor）entity=table 时 permission key 不限
- 位置：`services/permissions.service.ts` create——仅 FIELD entity 限定 RECORD_FIELD_EDIT；entity=table 可配任意合法 key（含 DOCUMENT_/DASHBOARD_/CHAT_ARTIFACT_ 系）
- 实测：entity=table + TABLE_RECORD_ADD → 200（2f）；DOCUMENT_ 系同理会过（惰性垃圾行，无消费者）
- 建议：table entity 限定 TABLE_* 键（F03 落地时收敛）

## 观察项（非 error）

- O1 `enforce_for_form`/`enforce_for_automation` 后端 checkPermission 未消费；公共表单提交路径（public-datas，无 user）fail-open 可写受限字段。调研报告已把「表单 forbidden 字段剥离」列为二批可选项，按 fork 范围记限制（前端 Form.vue 已隐藏 + 匿名 user grant 硬拒）
- O2 v1 bulkUpdateAll 别名路由按表 title 解析失败（`Table 'T1' not found`，表 id 形式可用）——上游既有路由怪癖，非本 commit 引入（未做上游对照，仅记录）
- O3 bulkUpdate 静默丢弃 link 键（实测不写链接、无绕权）；`updateLTARCols` 挂点为二层防御，直达路径（bulkInsert/bulkUpsert）各有自家挂点覆盖
- O4 reorderLink 无公开 REST 路由（v2 注释明示仅 internal-operations 通道），其 checkPermission 挂点代码存在但未能 API 实测

---

## 集成测试矩阵（自建数据：base pcxoyfxff0w5roy / T1 m0aqd7yxgd4m0vn / 列 Secret=ceoplirc…, Num=ctkpg42…, Title=cyq8dor…; owner=f02r1l1-o(super 提权), editor=f02r1l1-e, creator=f02r1l1-c）

| # | 项 | 结果 | 证据 |
|---|---|---|---|
| 1 | fail-open：无 grant editor PATCH/insert | PASS | 1a PATCH 200、1b insert 200 |
| 2 | CRUD create/list/PATCH/DELETE + 回读 | PASS | 2a 200、2b list 含 grant、2i granted_type 改型+回读、u1a subjects PATCH + u1e 回读 subjects=[user:id]、7a/7b DELETE |
| 2b | ACL：editor 管理权限被拒 | PASS | 2g/2h 403（permissionList/Create creator+） |
| 2c | bogus entity_id / permission / granted_type → 400 | PASS | 2c/2d/2e 全 400；FIELD+TABLE_RECORD_ADD → 400（2f2） |
| 2d | synced 列拒配 | 未实测（环境无 synced 表） | 代码级：service create 查 `table.synced` 拒配 ✓ |
| 3 | nobody：editor PATCH 受限 403 / 其他字段 200 / insert 含 403 / 不含 200 | PASS | 3a/3b/3c/3d |
| 3b | owner 直通 / creator 按 SDK 语义（nobody 拒 creator） | PASS | 3e owner 200；3f/3g creator 403（=SDK evaluatePermission NOBODY→false，creator 拒绝是正确语义，与 UI「No access for anyone」文案一致） |
| 4 | role grant（granted_role=creator）：editor 403 / creator 200 / owner 200 | PASS | 5a-5d |
| 5 | user grant：subjects 内 200 / 外 403 / owner 200 | PASS | u1b/u1c/u1d（正确 subject id 下） |
| 6 | bulk 系：bulkUpdate 混入 403 干净 200 / bulk insert 混入 403 干净 200 / bulkUpdateAll / bulkUpsert | PASS | 4a-4d；bulkUpdateAll 真 body s1a 403/s1b 200；v3 upsert q8 403/q9 200（fieldsToMergeOn 形） |
| 7 | 缓存即时性 + 用户隔离 | PASS | 建后立拦 3a（含 'NONE' 哨兵 evict 路径：T1 空列表已缓存后 2a 建 grant 3a 立即生效）、删后立放 7b/u4c/r8；类型切换立生效 2k→3a；用户不串 3a(editor 403)/3e(owner 200)/u1b(editor)/u1c(creator) |
| 8 | link 系 5 方法对受限 LTAR 列 | PASS | v3 路由实测：addChild 403(r1)/removeChild 403(r2)/owner 200(r3)/addLinks 403(r4)；removeLinks 403（supp4 q5 面上被脚本 env 干扰，r4 等价 DELETE /records 已由 q5 逻辑覆盖——补注：q5 因 R1 空未跑成，removeLinks 拦截由 v3 DELETE /records 同代码路径 addChild 验证覆盖，且 5 挂点共用同一 checkPermission 实现）；无 grant 放行 p1/r8；bulkUpdate link 键被静默忽略无绕权（O3）；reorderLink 无公开路由（O4） |
| 9 | 回归：无 grant 全 CRUD / F05 / F07 / F10 / F08 | PASS | editor 读 200（u9f）；F05 variables create+list（s7a/u9a）；F07 快照 **creator 触发**（nobody-on-Secret 在场）200 且 status=completed（u9d+轮询）→ copy 路径 skip 通道不误拦；F10 dashboard create/list（u9c+probe 200）；F08 is_private PATCH 200 |

未完全覆盖（记测试面缺口，非产品问题）：v3 单条 insert 的 body 形状未摸对（两次 400 均为 payload 校验，与权限无关；其执行路径与 v2 bulkInsert 相同 hook 已实测）；MCP loadPermissions 路径未实测（代码级：req.permissions 非空优先、与 Permission.list 输出同构）。

## 代码复审要点核对

- **fail-open 完整性** ✓：checkPermission `user` 缺失 return；`req.permissions?.length` 空则 `Permission.list`；list 空 → return；`Permission.list` 对 extract-ids 预置 `context.permissions=[]` 用 `__permissionsLoaded` marker（commit msg 已知坑①，修复有效——T1 空列表请求后 2a 建行立拦证明 marker+evict 正确）；CacheMgr 数组走 sadd 的坑②规避正确（list 键存 id 串数组 + 'NONE' 哨兵，行对象独立键）
- **per-field 挂点** ✓：updateByPk(2811)/bulkUpdate(4478)/bulkUpdateAll(4769, skipValidationAndHooks 豁免)/bulkUpsert(3638, raw 豁免)/insert single(insert.ts:69)+bulk(insert.ts:345, skipPermissionCheck 豁免)/updateLTARCols(4706)+既有 5 link 挂点。已核客户端不可达 raw/skipPermissionCheck/skipValidationAndHooks（controller 均不透传，仅 internal）
- **skipPermissionCheck 透传** ✓：import.service.ts 2494/2536/2603 → bulkInsert(skip)；实测 creator+nobody-on-Secret 快照 copy 完成（u9d + completed）
- **fieldPermissionEntityIds 过滤**：system/pk/FK/isSystemColumn 豁免与 payload 键（column_name，经 mapAliasToColumn）匹配；formula/lookup 等虚拟列不可入 payload（mapAliasToColumn 剥离+validate 拦），无可造实体
- **缓存一致性** ✓：insert/update/delete/deleteByBaseId evict 全覆盖；行级键 + list 键双层；跨 base 隔离由 metaGet2 context.base_id 条件保证（跨 base entity_id 探针 400 即证，连带否决「跨 base grant」候选缺口）
- **错误语义** ✓：NcError forbidden（403 ERR_FORBIDDEN）类型一致；消息含字段 title（用户已知信息，无泄漏）
- **Base.softDelete/delete 清理** ✓：Permission.deleteByBaseId 两处挂载（subjects+主行）
- **前端 gate** ✓：blockTableAndFieldPermissions→false；View.vue/Details.vue/ColumnMenu 全改 flag 驱动，isEeUI/showEEFeatures 未动；i18n en/zh-Hans permissionUpdated 已加；未发现 console.error/服务端 500 残留
