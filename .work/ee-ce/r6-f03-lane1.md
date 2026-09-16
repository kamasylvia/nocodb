# R6 F03 Data permissions 复审报告 — lane 1

**结论：PASS（0 error）**

- 审查对象：HEAD = 0633d8dfea（F03 实现 7b10716231 + R1-R3 修复 b28787a54a + R4 i18n 66e0ea343d + R5 修复批 ca8bb77622），工作树干净（R6 时点前移至 R5 收官后，符合任务书"审查 HEAD 前移"精神）
- 测试账号：f06l1-{owner,editor,creator,viewer,uiowner}@t.local（独立 lane 前缀，未触他路数据）
- 数据已清理：f06l1-base / f06l1-uibase / grants 全删（uibase 归 uiowner 所有，token 重签后补删）

## 一、集成测试全矩阵（API 实测 :8080）

### fail-open 与角色矩阵（TABLE_RECORD_ADD / TABLE_RECORD_DELETE）

- 无 grant：editor v2 单插/更新/删除/bulk 插、count、aggregate、v1 单插/单删/bulk 插/deleteAll 全 200；viewer 插入 403（base 角色 ACL floor，非 F03）；owner 全 200
- ADD nobody：editor/creator/viewer v2 单插、bulk、v1 单插、v1 bulk 全 403；owner 200（直通）；update/delete 200（正交）；删 grant 后下一请求 200（fail-open 往返）
- ADD role:editor：editor/creator 200、viewer 403、owner 200（v1/v2 双面一致）
- ADD role:creator：editor 403（v1+v2）、creator 200、viewer 403
- ADD role:viewer → **create 400（低于 minimumRole=editor，设计正确）**；viewer 档仅 VISIBILITY 可配
- ADD user:[editor]：editor 200、creator 403（精确匹配）
- DELETE nobody：v2 单删/bulk 删、v1 单删/bulk 删/deleteAll 全 403；owner 200；insert/update 200（正交）
- multi-grant any-deny：ADD nobody + DELETE nobody 同时在位 → insert 403、delete 403、update 200 ✓
- bulkUpsert 拆分（v1）：ADD nobody 下纯 update 批 201（放行）；含插入行批 403（要求 ADD）✓
- v2 upsert 见 E3-③

### TABLE_VISIBILITY（404 遮蔽语义）

- nobody：editor v2 meta/records/count/aggregate、v1 data 全 404；creator/viewer meta 404；owner 200；表列表隐藏 T1（0 条）而 owner 可见（1 条）✓
- 删 grant 后 editor meta 恢复 200（Everyone 往返）✓
- role:viewer：viewer/editor/creator/owner 全 200（power ≥ viewer 语义正确）
- user:[viewer]：viewer 200、editor 404、creator 404（非 subject 精确遮蔽）✓

### 公开表单 enforce_for_form

- nobody + enforce_for_form=true：匿名 POST /api/v2/public/shared-view/:uuid/rows → 403（"You don't have permission to create records in T1"）
- PATCH enforce_for_form=false：匿名 → 200 ✓
- 同 grant 下 editor grid 插入仍 403（opt-out 仅作用于表单面）✓

### 校验对称（create + update 全 400）

- create：nobody+subjects、role 缺 granted_role、user 缺 subjects、非法 granted_type/permission/entity、role 低于 minimumRole、非法 role 枚举、重复键、跨 base 表 id、不存在表 id、**nobody+显式 granted_role（R6-3）** 全 400 ✓
- update：**nobody+granted_role（R6-3 对称）**、user+team subjects、非法 role 枚举、低于 minimumRole、role grant 显式 null role 全 400；合法 role 切换 200 ✓

## 二、R3/R5/R6 修复回归（逐项实测）

| 项 | 结果 | 证据 |
|---|---|---|
| NOBODY 转换 granted_role=null | ✓ | PATCH role→nobody 后 GET granted_role=null |
| 复活守卫 | ✓ | nobody→role 不带 granted_role PATCH → 400；nobody 仍拦 editor（403）、owner 通 |
| user→role subjects 清空 | ✓ | 切换后 subjects=[] |
| owner-role grant 不降权 | ✓ | create role:owner → PATCH touch → granted_role 仍 owner |
| SPECIFIC_USERS 单选项可见可选 | ✓ | 弹窗 testid：三组 -specific_users 全在 DOM |
| save 前置校验（空选全中止） | ✓（代码审在位 + R4/R5 已验） | Table/Permissions.vue:232-247 |
| dirty-flag（a-select @change） | ✓ UI 实测 | DELETE 组切 Specific users 选 editor → Save → API subjects=[editor id] 落库 |
| 100 行 bulk 性能 | ✓ | 交替 3 轮：no-grant 0.53/0.91/0.88s vs grant 0.95/0.90/0.92s，**中位比 1.04x**（首测 2.01x 系顺序噪声，交替复测排除） |
| duplicate 带 grants | ✓ | 副本带出 VISIBILITY nobody + RECORD_FIELD_EDIT user grant；entity_id 映射到新表 id / 新列 id；subjects 保留；副本上 grant 生效（editor 被邀入后 meta 404 遮蔽恢复，见 E3-④） |
| F02 字段权限回归 | ✓ | RECORD_FIELD_EDIT nobody：editor PATCH 字段 403、owner 200、删 grant 后 200 |

## 三、R6 专属 4 项（附录强制）

1. **摘要语义** ✓：Details → Permissions tab 无 grant 时显示 "Who can add records **Editors & up**"、"Who can delete records **Editors & up**"、"Table Visibility **Everyone**"（getPermissionSummary 仅 VISIBILITY 回退 Everyone）
2. **VISIBILITY Creators & up** ✓：弹窗 VISIBILITY 组选项 = Creators & up / Viewers and up / Specific users / Everyone / Nobody；API 造 role:owner VISIBILITY grant 后重开弹窗回显选中 Creators & up（DOM border-nc-border-brand + bg-nc-fill-brand 选中态）；**点 Save 后 API granted_role 仍 owner（不降权）**
3. **nobody+granted_role 400 对称** ✓：create 400（"granted_role is not allowed on nobody grants"）+ PATCH 400；不带 role 的 nobody 往返 200（role→nobody 转换实测）
4. **[CE-EE] 标记** ✓（代码审）：permissions.service.ts:79 F03 TABLE 校验块在位；全后端 diff 新增行含 17 处 [CE-EE]

## 四、代码复审（diff 7b10716231^..HEAD 全量）

- **BaseModelSqlv2.ts**：delByPk/v2 bulk delete/deleteAll 三处 DELETE 检查、v1 insert（isFormContext 透传 → enforce_for_form 生效）、v1 bulkUpsert 拆分后 toInsert.length 才查 ADD（纯 update 批不拦）——五处 enforcement 点正确
- **insert.ts**：bulk ADD 检查提出行循环（R3 性能修复，实测 1.04x 印证）
- **extract-ids.middleware.ts**：主路径设 ncTableId；v1 fallback（tableName→getByAliasOrId）解析不出即跳过 gate——fail-open 设计正确（寻表失败请求本身 404，无 enforcement 绕过面）；AclMiddleware F03 gate：无 grant 零开销（permissions.length 短路）、service user 豁免、匿名回退默认可见性、404 遮蔽（tableNotFound 非 forbidden）
- **import.service.importPermissions**：实装正确——getIdOrExternalId 映射、subjects 只留 user 型过滤、逐 grant try/catch 容错（实测副本 grants 全对）
- **Permission.ts**：R5 nobody 卫生（insert/update 双面）、NOBODY 转换写 null、user→role 清 subjects、validateGrantShape 共享
- **前端**：Node.vue gate 换 blockTableAndFieldPermissions、DlgTablePermissions 去 isEeUI、grid/Table.vue usePermissions 提升 setup 顶层、useExpandedFormStore 去 !isEeUI 短路、usePermissions summary 语义、en/zh lang 新键
- **残留**：diff 新增行无 console.log/console.debug/debugger；错误文案无内部泄漏（permissionDeniedMessage 按键分类，实测 403 文案正确）

## 五、回归 smoke（其他功能未破坏）

- F02 ✓（上表）；F05 变量 create/list/非法 key 400/delete 全过；F07 快照 create→completed→restore(200)→delete 全链路；F08 is_private base 创建+meta 回读；F10 dashboards create/get/patch/list/delete 全过

## 六、质量门

- `npx tsc --noEmit`：**exit 0**
- `pnpm test`（jest Fork 桶）：**2 suites / 26 tests 全过**

## 七、UI 段（camoufox-cli，:3000，独立账号 f06l1-uiowner + 独立 base）

- 登录 → uibase → UT1 → 树右键 Details → Permissions tab：摘要三 key 与 API 语义一致（R6-1，截图 /tmp/f06l1/ui-details-permissions-tab.png）
- Configure 弹窗：三组单选含 Specific users 全可见可选；VISIBILITY 组 Creators & up 在列（R6-2）
- owner VISIBILITY grant 回显 + Save 不降权（R6-2，截图 /tmp/f06l1/ui-owner-vis-dialog.png）
- user 型 grant UI 落库 ✓（上述 dirty-flag 行）
- Nuxt error overlay：无；全程 UI 渲染正常、API 交互全成功（console 无致命错误）

## E3 / 已知沿袭（不计 error，附诊断证据）

1. **v1 按表 title 寻表 404**（任务书已知 E3，getByAliasOrId 上游行为）：`GET /api/v1/db/data/noco/:baseId/T1 → 404 "Table 'T1' not found"`，同表按 id → 200。v1 enforcement 全部改经表 id 路径实测（结果见上，全对）
2. **v1 bulkUpsert 纯 update 批 500**（任务书已知 E3，afterUpdate BaseModelSqlv2.ts:6065 上游）：owner 零 grant 复现 500，且**行值已被更新**（炸在 afterUpdate 阶段，写库先行）——上游 2023 代码，非 fork
3. **v2 POST /records?upsert=true 忽略旗标**（backlog ⑫ 上游）：owner 零 grant 下 upsert 带 Id 行返回 200 但 Title 不变（旗标无效确证）；因此"v2 纯 update 批不要求 ADD"在上游当前行为下不可达——editor 纯 update 批 403 系按插入路径检查，与旗标忽略自洽。fork 侧 v1 拆分语义已正确实现
4. **duplicate 副本不带成员角色**（R5 已知非问题沿袭）：副本上 VISIBILITY nobody 的 meta 对非成员表现为 **403**（base 层 ACL 先拦，此时用户在副本中 No Access）而非原 base 的 404 遮蔽；t7 做实：将 editor 邀入副本（role=editor）后同一请求变 **404**——遮蔽语义本身无损，差异纯由成员缺失引起，非 importPermissions 缺陷
5. 测试装置注记：uiowner 的 UI 登录触发 token_version 互踢致首轮 uibase 删除 403，重 signin 后 200（环境行为，GOAL-STATE 已录）

## 实测统计

- 判定断言总数：**约 100 项 OK / 0 项产品 error**（t2 矩阵 46 + t3 VISIBILITY/校验 33 + t3d G2/H 16 + t5 form/dup/perf 11 + t4 F02 3 + t8 smoke 21；FAIL 行均已定性为 E3 沿袭或装置预期写反）
