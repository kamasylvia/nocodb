# F03 Data permissions 调研报告（只读调研，2026-09-14）

> flag：`FEATURE_TABLE_AND_FIELD_PERMISSIONS`（与 F02 共用，已解 gate：`useEeConfig.ts:73 blockTableAndFieldPermissions=false`）。
> 范围 = 同一 nc_permissions 表上的三个 key：`TABLE_RECORD_ADD` / `TABLE_RECORD_DELETE` / `TABLE_VISIBILITY`（SDK minimumRole：viewer / editor / editor）。
>
> **核心结论**：
> 1. **F02 基础设施 100% 复用**——Permission model（list/isAllowed/CRUD/findGrants）、checkPermission（owner 直通/fail-open/multi-grant any-deny/isFormContext）、permissions CRUD API、ACL、前端 usePermissions 全部就位，F03 主要是**补挂点 + 解封 entity=table**。
> 2. **TABLE_VISIBILITY 后端已大半实装**（上游 CE 预埋）：tableHelpers 五个 helper + 表列表过滤 + 直连 meta 404 遮蔽 + link 折叠 + duplicate/api-docs 消费方全通。**唯一安全缺口：v2/v1 data 路由（/api/v2/tables/:modelId/records 等）不查 TABLE_VISIBILITY**——`data-table.service.ts:398` 注释声称中间件已查，实测 extract-ids 中间件只跑 UI-ACL（`hasModelRoleVisibilityAccess`），无 permission 版检查。
> 3. **TABLE_RECORD_ADD/DELETE 后端零挂点**（现有 11 处 checkPermission 全是 FIELD/RECORD_FIELD_EDIT）；上游在 `beforeBulkInsert` 的 skipPermissionCheck 注释里钦定了 EE 做法（"skips the TABLE_RECORD_ADD check for trusted internal copies — duplication / snapshot / import. No-op in CE"）。
> 4. **前端消费点预埋密集**（23+ 文件引用 TABLE_*），绝大多数无 isEeUI gate、走 usePermissions.isAllowed（F02 已实装）——后端 grant 一写、前端自动生效。仅两处需解 gate：`useExpandedFormStore` 的 `!isEeUI` 短路、TreeView 表权限菜单/弹窗的 isEeUI+showEEFeatures gate。

---

## 1. TABLE_RECORD_ADD / TABLE_RECORD_DELETE 拦截点

### 1.1 checkPermission 现状（BaseModelSqlv2.ts:10568，F02 实装，F03 直接复用）

签名 `checkPermission(params, options?: { isFormContext?: boolean })`：
- owner 直通（`getProjectRole === OWNER` return）；无 grant 配置 = allow（fail-open）；multi-grant any-deny 阻断；匿名（public form）走 `enforce_for_form`。
- 权限清单来源：`req.permissions`（MCP 预载）或 `Permission.list(reqContext, base_id)`（context.permissions 请求级复用）。
- **局限**：错误文案硬编码 `You don't have permission to edit the field ${label}`，label 解析只在 `PermissionEntity.FIELD` 分支——F03 需按 permission 泛化文案（TABLE → "create/delete records in this table"，i18n 已有对应英文串 `objects.permissions.addNewRecordTooltip` 等）。

### 1.2 现有挂点清单（11 处，全部 FIELD/RECORD_FIELD_EDIT，F02 遗产）

| 方法 | 位置 | 说明 |
|---|---|---|
| `insert.ts` single | insert.ts:69 | v2 单条直插路径（datas.service:1221 也经此） |
| `insert.ts` bulk | insert.ts:345 | `!skipPermissionCheck` 包裹；v2 全部 insert（dataInsert→bulkInsert isSingleRecordInsertion）+ undo |
| `nestedInsert` 内 | BaseModelSqlv2.ts:3057 | v1 data insert + **public form**（`request.isPublicForm → isFormContext`，flag 由 public-datas.service.ts:827 打） |
| `updateByPk` | 2815 | |
| `bulkUpsert` | 3665 | raw 跳过 |
| `bulkUpdate` | 4505 | raw 跳过 |
| `updateLTARCols` | 4735 | |
| `bulkUpdateAll` | 4790 | skipValidationAndHooks 跳过 |
| `addChild`/`removeChild` | 6447/6850 | link 系 |
| `addLinks`/`removeLinks`/`reorderLink` | 8732/8749/8767 | link 系 |

→ **TABLE_* 零覆盖**，需新增挂点如下。

### 1.3 TABLE_RECORD_ADD 缺口与挂点方案

| 挂点 | 位置 | 要点 |
|---|---|---|
| v2/v1 单条+批量 insert 主路径 | `insert.ts` bulk（:345 FIELD hook 旁） | v2 全部 insert 收敛于此；必须 `if (!skipPermissionCheck)` 包裹（import/copy 免检）；entityId = `this.model.id`（或 baseModel.model.id），无需 fieldPermissionEntityIds |
| insert.ts single | insert.ts:69 旁 | single 路径（v1 datas insert 也走 `insert()`→single？否——datas.service:1221 调 `baseModel.insert()` → single；v2 走 bulk） |
| nestedInsert | BaseModelSqlv2.ts:3057 同点 | 与 FIELD hook 同点并列加一条 check，`isFormContext: !!request.isPublicForm`——表单提交受 `enforce_for_form`（默认 true = 受限时匿名提交 403，前端 Form.vue 已有提示） |
| bulkUpsert | 3665 之后（**拆分后**） | upsert 拆 toInsert/toUpdate；ADD 只查 toInsert 行（拆分前查会误伤纯 update 批——见风险 §8） |
| beforeBulkInsert skip 通道 | BaseModelSqlv2.ts:5546-5557 | **上游已钦定**：`skipPermissionCheck` 参数注释 "Honored by the EE override (skips the TABLE_RECORD_ADD check…) No-op in CE"。insert.ts bulk 的 skip 参数 + bulk-data-alias.service.ts:61/80 透传 + import.service 2494/2536/2603 已全链路就位，零新增 |

免检通道验证：duplicate/snapshot/restore → import.service 传 skip=true → insert.ts bulk FIELD hook 已尊重 → F03 ADD hook 挂同点自动免检（F07 快照 restore 不受自拦，F02 §7.4 的担忧在 ADD 场景同样由该通道化解）。

### 1.4 TABLE_RECORD_DELETE 缺口与挂点方案

| 方法 | 位置 | 服务层调用方 | 现状 |
|---|---|---|---|
| `delByPk` | 2247 | datas.service:231/1275（v1 单删）、old-datas.service:153 | 无 hook，无 skip 参数 |
| `bulkDelete` | 4926 | data-table.service:338（v2 单删+批删统一入口） | 无 hook |
| `bulkDeleteAll` | 5492 → `BaseModelDelete.bulkAll`（delete.ts） | bulk-data-alias.service:185（反射分发） | 无 hook |

- **delete 侧无需 skip 通道**：内部清理不经过这三个公有方法——trash 永久清走 `permanentDeleteByIds`（5510，独立）、级联删除在 delete.ts 内部直写 qb；F07 删快照走 `Base.softDelete`（meta 级）。全 src grep 确认数据层 bulkDelete/delByPk 调用方只有上述 4 个用户路由入口，无误伤面。
- bulkDeleteAll 挂点建议放 `BaseModelDelete.bulkAll` 入口（delete.ts:48 附近）或 BaseModelSqlv2.bulkDeleteAll 包装层，一次覆盖。
- link 系 removeChild/removeLinks 是字段值编辑语义（RECORD_FIELD_EDIT 已拦），**不**再加 DELETE 拦截（对齐 EE：删行 ≠ 摘链接）。

---

## 2. TABLE_VISIBILITY 拦截点

### 2.1 已实装（helpers/tableHelpers.ts，上游 CE 预埋 + fork F02 接线 Permission model 后已活）

| helper | 行为 |
|---|---|
| `hasDefaultTableVisibility`（:102） | 无 grant = Everyone（UI 选 Everyone = 删 grant 行，注释钦定） |
| `hasViewersAndUpTableVisibility`（:124） | grant = role:viewer（shared base 只显示 default + viewer 两档） |
| `hasTableVisibilityAccess`（:151） | 主判定：**owner 直通**（base_roles/roles 双查）→ 无 grant = true → 无角色 = false → `Permission.isAllowed`。`!user`（匿名）回落 default visibility。permissions 参数可注入避免重复 list |
| `hasModelRoleVisibilityAccess`（:226） | CE per-view UI-ACL（ModelRoleVisibility），与 permission 版并行、fail-open（viewless model、未知表、无 ProjectRole 调用方均 true） |
| `hasLimitedRelatedTableAccess`（:285） | shared view/form 相关表必折叠 + TABLE_VISIBILITY 无权折叠（pk+pv+display value） |

跨 base 上下文污染已修：LinkToAnotherRecordColumn.ts:334 / relation 上下文对 `permissions: undefined` 重置（否则 visibility 查错 base 静默泄漏）。

### 2.2 消费方清单（全部已接线，F03 零工作）

| 消费方 | 位置 | 行为 |
|---|---|---|
| 表列表过滤 | tables.service.ts `getAccessibleTables`（762；过滤段 799-833） | 非 owner 且非 service user：逐表 hasTableVisibilityAccess 过滤；**isPublicBase 只留 default/viewer-role**（795-813）；隐藏表从列表消失（前端树即不见） |
| 直连表 meta | tables.service.ts `getTableWithAccessibleViews`（642；检查 660-671） | `!isServiceUser` 且无权 → **404 tableNotFound**（遮蔽非 403，防 id 探测）。消费路由：tables.controller.ts:88（`/api/v2/meta/tables/:tableId`）、v3 tables、UiGet.operations、at-import、mcp.service |
| link 相关表折叠 | relation-data-fetcher.ts（10 处）+ nestedLinkQueryHelpers.ts:257 | 无 visibility 的 related 表 SELECT 折叠到 pk/pv/display；datas.service:662 注释钦定语义 |
| 表级 is_private 标志 | columns.service.ts `getLinkColumnRefTable`（7877；7959-7989） | 非 owner 且存在 visibility grant 且 isAllowed=false → 返回 `is_private=true`（**前端展示语义**，与 F08 base.is_private 列同名不同物） |
| shared base 默认可见性 | public-metas.service.ts `filterIfLimitedAccess`（303） | 非 default visibility 的相关表列折叠 pk/pv |
| base 复制 | duplicate.processor.ts:148 | 只拷 hasTableVisibilityAccess 的表 |
| api-docs | api-docs.service.ts:67 | swagger 只列可见表 |
| grants 导出 | export.service.ts:727 | Permission.list 全量导出（含 table entity 行）——duplicate/restore 自动携带表权限 |

### 2.3 缺口：data 路由无遮蔽（F03 必修）

- `/api/v2/tables/:modelId/records`（data-table.controller.ts：GET/POST/PATCH/DELETE/count/aggregate/…）→ `getModelAndView`（380-399）只查 model 存在 + base 归属；**:398 注释 "Table visibility permission is checked in extract-ids middleware" 为失实**——extract-ids 中间件（1341-1354）只跑 `hasModelRoleVisibilityAccess`（UI-ACL），全 src 无 middleware/guard 层的 hasTableVisibilityAccess 调用。
- 同理 v1 datas.service（:638/671/746/825 一串 tableNotFound 是存在性检查）与 old-datas、bulk-data-alias 均无。
- **后果**：被隐藏表的低权用户拿到 table id（历史链接/link 列 fk_related_model_id 泄露面）仍可 GET 读数据、POST/PATCH/DELETE 写删（角色 ACL 仍拦，但 visibility 语义 = 看都不该看）。
- **修法**：extract-ids 中间件 `hasModelRoleVisibilityAccess` 块旁（1341-1354）加 permission 版检查——`req.context.ncTableId` 已存（1096）+ `context.permissions` 已预置空数组（1083），调 hasTableVisibilityAccess（context, ncTableId, req.user）→ false 则 404 tableNotFound（与 1353 注释「404 not 403」语义对齐）。注意：① 空权限清单先短路（fail-open + 零开销）；② service user 放行（对齐 getTableWithAccessibleViews 的 isServiceUser 豁免）；③ 匿名 `!user` 已由 helper 内回落 default visibility 处理；④ performance：Permission.list 是小 meta 查询 + context 请求级缓存，middleware 已在跑更贵的 ModelRoleVisibility.list，可接受。

---

## 3. 前端挂点

### 3.1 决策层（F02 已实装，零改动）

- `composables/usePermissions.ts`：懒加载 base grants（loadPermissions + per-base guard + base 切换清态）、`isAllowed(entity, entityId, permission, {isFormView})` = owner 直通 → grantsFor → `evaluateTableFieldPermission`（utils/tableFieldPermission.ts 纯函数，SDK evaluatePermission 共享决策）→ enforce_for_form 豁免。**TABLE_* 三 key 天然支持**。
- `components/permissions/Tooltip.vue`：已接线（无 entityId 时 allow-all 保留），通用。

### 3.2 消费点清单（预埋完成；grant 写入即生效）

| 挂点 | 文件:行 | key |
|---|---|---|
| canvas grid 空行/加号 | `grid/canvas/composables/useCanvasTable.ts` 399（isAddingEmptyRowPermitted）、397（isAddingEmptyRowAllowed 组合）、1904 附近 insertRow gate | ADD |
| canvas 右键菜单 | `grid/canvas/context/Cell.vue` 507/558/616/662/702/960 | ADD×4 + DELETE×4 |
| canvas 加行按钮 | `grid/canvas/index.vue` 3986 | ADD |
| Form 视图 | `smartsheet/Form.vue` 222（isAllowedToAddRecord, isFormView）→ 231 disableFormSubmit + 1483-1489 NcAlert `formCannotAcceptSubmissions` | ADD |
| 共享表单 | `useSharedFormViewStore.ts` 126（isFormView） | ADD |
| 展开表单 | `useExpandedFormStore.ts` 119-123（isAllowedAddNewRecord）+ 125-128（getIsAllowedEditField） | ADD+FIELD——**有 `if (!isEeUI) return true` 短路，F03 必解** |
| 展开表单 UI | `expanded-form/index.vue` 1016、`MoreOptionsMenu.vue` 280/330 | ADD/DELETE |
| 日历 | `calendar/index.vue` 264、`MonthView.vue` 1253、`DayView/DateTimeField.vue` 1037、`SideMenu.vue` 656、`calendar/index.vue` 438 | ADD/DELETE |
| 看板 | `KanbanOptimized.vue` 2015/2429/2473/2504/2796 | ADD×4/DELETE |
| 画廊 | `Gallery.vue` 810/1219 | DELETE/ADD |
| link 弹层 | `virtual-cell/components/UnLinkedItems.vue` 669/702、`LinkedItems.vue` 760 | ADD |
| Upsert 对话框 | `dlg/Record/Upsert.vue` 89 | ADD |
| 上传数据菜单 | `toolbar/ViewActionMenu.vue` 561-575（uploadData 三种 import） | ADD（`uploadDataTooltip`） |
| InfiniteTable | `grid/InfiniteTable.vue` 3015 | ADD |
| legacy DOM grid | `grid/Table.vue` 335 isAddingEmptyRowAllowed——**不含 TABLE_RECORD_ADD**（无 isAllowed(TABLE) 调用） | 缺口，见 §8 |

渲染路由：`grid/index.vue:240` `isCanvasTableEnabled = !ncIsPlaywright()`，:238 INFINITE_SCROLLING beta flag——canvas 为主渲染器；legacy `Table.vue`（分页 DOM）在 flag 关时可达。InfiniteTable 已覆盖，仅 Table.vue 需补一行。

### 3.3 TreeView（表树 + 配置入口）

- **表树过滤**：前端零工作——`tables` 来自 getAccessibleTables（服务端过滤），无 hasTableVisibilityAccess 前端版。无权用户直链进隐藏表 → meta 404 → 路由错误态（与 F8 直链 404 同款处理）。
- **表权限菜单项**：`dashboard/TreeView/Table/Node.vue` 749-789（`enabledOptions.tablePermission` / `restrictionReasons.tablePermission`，421-465）gate = `isEeUI && type==='table' && isUIAllowed('tablePermission') && showEEFeatures`，外包 `PaymentUpgradeBadgeProvider`（FEATURE_TABLE_AND_FIELD_PERMISSIONS）+ `LazyPaymentUpgradeBadge` 付费锁。前端 `lib/acl.ts:101` tablePermission: creator+ 已有。**F03 解 gate = 照抄 F02 在 View.vue/Details.vue 的 flag+role 模式**（去 isEeUI/showEEFeatures，留 isUIAllowed('tablePermission')）。
- **配置弹窗**：`DlgTablePermissions`（`components/dlg/Table/Permissions.vue`）= 13 行 stub（NcSpanHidden），Node.vue:922 `v-if="table.id && isEeUI"` 同样要解。**这是 F03 前端主体工作**。
- RLS 菜单（`DlgTableRowLevelSecurity`，Node.vue 801/929）是另一功能（FEATURE_RLS），不在 F03。

### 3.4 配置 UI 现状

- `permissions/Modal/Content.vue`（Details tab 主体，F02 实装）：顶部已有 F03 占位框（`nc-table-permissions-defaults`，读 `resetTablePermissionsDescription`）——F03 替换为三行表级摘要 + 配置入口。
- `dashboard/settings/Permissions.vue`（base 汇总页）仍 stub——F02 已裁，F03 沿用。
- i18n 全备（lang/en.json）：`objects.permissions.*` 1067-1091（addNewRecordTooltip/deleteRecordTooltip/uploadDataTooltip/formCannotAcceptSubmissions/resetTablePermissions*）、`title.editTablePermissions`(1339)、`title.tablePermissions`(1577)、`title.tableVisibility`(1578)。

---

## 4. CRUD API 复用（F02 面，F03 只解封）

- **解封点**：`services/permissions.service.ts:66-70` 对 entity=TABLE 直接 400（"Table permissions are not supported yet (upcoming data permissions)"）。F03 改为：TABLE entity 允许 `{TABLE_RECORD_ADD, TABLE_RECORD_DELETE, TABLE_VISIBILITY}` 三 key 白名单；FIELD entity 维持 RECORD_FIELD_EDIT 单 key。
- **entity_id 校验**（照抄 FIELD 分支 :42-54）：`Model.get` 存在 + 归属该 base + `table.synced` 拒配（对齐「synced 字段禁配」先例）。
- **零改动项**：
  - `Permission.validateGrantShape`（Model）：granted_role 枚举 + **minimumRole 强制**（TABLE_VISIBILITY=viewer、ADD/DELETE=editor，SDK PermissionMeta 133-153）自动生效；
  - 重键检查（service :82-93，(entity, entity_id, permission) 唯一）通用；
  - team subject 拒绝（:95-100/:123-133）——F03 沿用裁剪；
  - 路由（controller，v1+v2 双路径）、ACL（acl.ts:279-282 creator+ CRUD / :559 editor+ permissionList）、`@Acl` 注册、Base 软删/硬删清理（`Permission.deleteByBaseId`）、export/import grants 全部通用。
- **TABLE_VISIBILITY 特殊写语义**（helpers 注释钦定，前端弹窗须实现）：选 "Everyone" = **删除 grant 行**（非 granted_type=role:owner）；"Viewers & up" = role:viewer；nobody = 仅 owner 可见；SPECIFIC_USERS = user subjects。
- PATCH/DELETE 对已有 TABLE grant 无特殊化（update 校验已对称，F02 R2/R3/R4 修过）。

---

## 5. 与 F02/F08 交互语义

- **ADD × FIELD_EDIT**：insert 路径两 check 并行（表级 ADD + 逐字段 EDIT）→ 无 ADD 有字段编辑权 = 只能编辑不能新建（insert 403）；有 ADD 无某字段编辑权 = 可建行但 payload 含受限字段值时 F02 hook 403（前端新行只发可编辑字段，正常路径不触）。
- **DELETE × FIELD_EDIT**：正交。
- **VISIBILITY × F08（private base，已 pass e737f8f3ec）**：F08 = base 级（非协作者整个 base 404，extract-ids/getProjectsList 双分支遮蔽 + shared-base 三层拦截）；TABLE_VISIBILITY = base 内表级。叠加 = 先过 base 门再过表门，`PermissionRoleMap` 负责 base 角色 → PermissionRole 映射，无冲突。⚠️ 命名撞车：F08 的 `base.is_private` 列 vs `getLinkColumnRefTable` 派生的表级 `is_private` 标志——文档/测试断言注意区分。
- **三型 grant 表级行为**：`role`=该角色及以上（rolePower 比较）；`user`=subjects 精确匹配（team subject 已裁）；`nobody`=除 owner 全拒（owner 直通在 checkPermission/isAllowed/hasTableVisibilityAccess 三处一致）。匿名（public form）：nobody/user 全拒 fail-closed；role grant 走 enforce_for_form（默认 true = 拒）。
- **service user**：grant 存在时，AUTOMATION/WORKFLOW/SYNC 用户（无 projectRole）会被 ADD/DELETE hook 拒 → webhook 出站无影响，自动化写受 `enforce_for_automation`（默认 true）语义约束 = 名实相符；若 fork 不想拦自动化，hook 内 `isServiceUser(user, [AUTOMATION_USER, WORKFLOW_USER, SYNC_USER])` 放行并记 fork 限制（**建议：v1 放行 service user**，与 hasTableVisibilityAccess/getTableWithAccessibleViews 的 service-user 豁免一致；enforce_for_automation 列保留不判——沿 F02 裁定）。

---

## 6. 风险点

1. **data 路由遮蔽缺口**（§2.3）——最大安全面，`data-table.service.ts:398` 失实注释必须一并修正。
2. **checkPermission 文案泛化**：FIELD 硬编码 label 分支（10632-10644/10664-10670），TABLE 需 per-permission 文案 + 免查 columns（TABLE 无需 label 解析）。
3. **bulkUpsert 拆分时机**：3665 的 FIELD hook 在 toInsert/toUpdate 拆分**前**收集全批字段；ADD 若挂同位置会要求纯 update 批也具备 ADD（语义错误）→ 必须挂拆分后只查 toInsert 行（拆分逻辑在 3671 originalByPrepared 之后）。
4. **extract-ids 性能**：每个解析 table id 的请求多一次 hasTableVisibilityAccess；先 `context.permissions?.length === 0` 短路（extract-ids 预置空数组 + Permission.list 回填 context）——零 grant base 零开销。另 Permission.list N+1（F02 backlog ④）在中间件高频面放大，建议列 backlog。
5. **legacy grid Table.vue 无 ADD 消费**（§3.2）——补 isAddingEmptyRowPermitted 或记 fork 限制（canvas 为主）。
6. **useExpandedFormStore isEeUI 短路**（§3.2）——不解则展开表单内「新建」按钮在 ADD 受限时仍出现，前后端不一致。
7. **NocoCache/直改 DB 伪影**（F08 运维教训）：psql 直 UPDATE 权限行有缓存陈旧——F03 测试一律走 API 写。
8. **undo**：undo 删除 = 重插（bulkInsert undo 路径）→ 执行 undo 的用户需 ADD 权限；与 F02 FIELD 同类语义，可接受，测试覆盖一轮。
9. **shared form 提交链**：public-datas → nestedInsert（:3057）→ ADD isFormContext 检查需与 Form.vue disableFormSubmit + NcAlert 前后端闭环（前端已全备）；enforce_for_form=false 的 grant 匿名放行——弹窗需暴露该开关（Content/弹窗 UI 项）。
10. **重复防护语义**：VISIBILITY 的 Everyone=删行 + (entity,entity_id,permission) 唯一约束，前端「重置」按钮（resetTablePermissions）映射 DELETE grant——UI 与 API 对齐测试点。

---

## 7. 范围裁定建议（对照 F02/F10 先例）

**做（fork 最小可用面）**：

1. 后端 ADD hook：insert.ts bulk（尊重 skipPermissionCheck）+ insert.ts single + nestedInsert :3057（isFormContext）+ bulkUpsert 拆分后 toInsert 行。
2. 后端 DELETE hook：delByPk / bulkDelete / bulkDeleteAll（bulkAll 入口）。
3. checkPermission 泛化：per-permission 文案 + TABLE entity 短路径 + service-user 放行（记 fork 限制：enforce_for_automation 列保留不判）。
4. data 路由遮蔽：extract-ids 中间件 ncTableId 处加 hasTableVisibilityAccess 404（空权限短路 + service user 豁免）+ 修 data-table.service.ts:398 失实注释。
5. permissions.service 解封 TABLE entity（3 key 白名单 + Model 存在/base 归属/synced 拒配校验）。
6. 前端 gate 三处：Node.vue 表权限菜单（421-465/749-789 flag+role 化）、DlgTablePermissions v-if 解 isEeUI（:922）、useExpandedFormStore 去 isEeUI 短路（119-128）。
7. `DlgTablePermissions.vue` 实装：三 key 配置（role 下拉 / SPECIFIC_USERS subjects / nobody / VISIBILITY 的 Everyone=删 grant）+ enforce_for_form 开关 + 重置。参照 `dlg/Field/Permissions.vue`（F02 实装样板）。
8. `permissions/Modal/Content.vue` 占位框换三行表级摘要（getPermissionSummary 已通用）。
9. legacy `grid/Table.vue` 补 isAddingEmptyRowPermitted（一行）。

**裁掉（记 fork 限制）**：

- team subject（沿 F02 裁定，service 层已拒）；agent 主体（SDK is_agent 备好但不暴露）。
- enforce_for_automation 独立判定（列保留；service user 放行即其镜像）。
- base 汇总页 `dashboard/settings/Permissions.vue`（保持 stub）。
- TABLE_VISIBILITY 对 trash/审计/webhook 深语义；shared base 的 viewer-role 两档（hasViewersAndUpTableVisibility）CE 已免费提供，不另做 UI（弹窗里 VIEWERS_AND_UP 选项天然覆盖）。
- RLS（FEATURE_RLS 菜单/弹窗）非 F03。

**理由**：ADD/DELETE 拦截面 = 6 个后端挂点 + 1 处中间件；配置面 = 1 弹窗 + 1 tab 区块；VISIBILITY 消费面后端已 100% 就绪。role+user+nobody 三型覆盖产品语义 90%+；team/agent 主体与 automation 独立语义与 F02 同批裁剪，成本收益比差且不阻塞。

---

## 8. 实现路径清单（文件级）

后端修改（全部 `// [CE-EE] F03`）：

- [ ] `packages/nocodb/src/db/BaseModelSqlv2.ts` — checkPermission 文案/label 泛化（10568-10674）；nestedInsert ADD 挂点（3057 旁，isFormContext）；bulkUpsert ADD 挂点（拆分后，3671 后）；delByPk ADD? 否 DELETE 挂点（2247）；bulkDelete DELETE 挂点（4926）；bulkDeleteAll DELETE 挂点（5492 或 delete.ts bulkAll）
- [ ] `packages/nocodb/src/db/BaseModelSqlv2/insert.ts` — single（:69 旁）与 bulk（:345 旁，`!skipPermissionCheck`）加 TABLE_RECORD_ADD
- [ ] `packages/nocodb/src/db/BaseModelSqlv2/delete.ts` — bulkAll 入口 DELETE 挂点（若不放 BaseModelSqlv2 包装层）
- [ ] `packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts` — 1341-1354 块加 TABLE_VISIBILITY 404（空权限短路 + isServiceUser 豁免）
- [ ] `packages/nocodb/src/services/permissions.service.ts` — 66-70 解封 TABLE entity（3 key 白名单）+ entity_id 校验 + synced 拒配
- [ ] `packages/nocodb/src/services/data-table.service.ts` — 398 失实注释修正

前端修改（全部 `/* [CE-EE] F03 */`）：

- [ ] `packages/nc-gui/components/dlg/Table/Permissions.vue` — 实装（3 key 配置弹窗，主体工作）
- [ ] `packages/nc-gui/components/dashboard/TreeView/Table/Node.vue` — 421-465/749-789 gate flag+role 化；922 v-if 解 isEeUI
- [ ] `packages/nc-gui/composables/useExpandedFormStore.ts` — 119-128 去 `!isEeUI` 短路
- [ ] `packages/nc-gui/components/permissions/Modal/Content.vue` — 占位框换表级摘要 + 配置入口
- [ ] `packages/nc-gui/components/smartsheet/grid/Table.vue` — 335 isAddingEmptyRowAllowed 补 TABLE_RECORD_ADD（或记 fork 限制）

不动：Permission model、usePermissions、tableFieldPermission、Tooltip.vue、PermissionsController 路由/ACL、SDK（PermissionMeta 133-153 已全备）、其余 20+ 前端消费点（自动生效）、tableHelpers 五 helper、tables/columns/public-metas/relation-fetcher 消费方。

测试建议（Fork.spec 桶 + e2e）：
- ADD：editor 无权 insert 403 / creator 过 / owner 过 / bulkInsert 批 / bulkUpsert 纯 update 批不误伤 / import skip 通道 / public form（enforce_for_form true/false 两态）
- DELETE：v1 delByPk、v2 bulkDelete 单+批、bulkDeleteAll、trash 永久清不受拦、F07 快照删不受拦
- VISIBILITY：隐藏表列表消失 / 直连 meta 404 / **data 路由 404（本缺口回归）** / link 折叠 pk+pv / duplicate 只拷可见表 / shared base 两档 / Everyone=删 grant 往返
- 组合：ADD×FIELD_EDIT、F08 私有 base 内表级 grant、nobody/service-user
