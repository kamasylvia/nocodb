# F02 Edit field permissions 调研报告（只读调研，2026-09-13）

> flag: `FEATURE_TABLE_AND_FIELD_PERMISSIONS`（与 F03 Data permissions 共用基础设施）。
> 核心结论：**上游 CE 已预埋完整接线**——表/SDK 类型/前端挂点/i18n/skip 通道全就位，真正缺的只有
> ① Permission model 实装 ② checkPermission 实装 + 数据主路径 per-field 挂点 ③ permission CRUD 端点
> ④ 前端 usePermissions 实装 + 配置弹窗填壳 ⑤ 解 gate。

---

## 1. 数据层

### 1.1 表（CE migration 已建，无需新建迁移）

`packages/nocodb/src/meta/migrations/v2/nc_083_permissions.ts`：

**nc_permissions**（`MetaTable.PERMISSIONS`，globals.ts:91）：
| 列 | 类型 | 说明 |
|---|---|---|
| id | string(20) PK | |
| fk_workspace_id / base_id | string(20) | 上下文；索引 `nc_permissions_context` |
| entity | string(255) | `table` / `field`（=PermissionEntity） |
| entity_id | string(255) | table id / column id |
| permission | string(255) | `TABLE_RECORD_ADD`/`TABLE_RECORD_DELETE`/`RECORD_FIELD_EDIT` 等（=PermissionKey） |
| created_by | string(20) | |
| enforce_for_form | bool default **true** | 表单提交是否强制 |
| enforce_for_automation | bool default **true** | 自动化写入是否强制 |
| granted_type | string(255) | `role` / `user` / `nobody`（=PermissionGrantedType） |
| granted_role | string(255) | granted_type=role 时「该角色及以上」可用 |
| timestamps | | |

**nc_permission_subjects**（`MetaTable.PERMISSION_SUBJECTS`）：`fk_permission_id + subject_type(user/group) + subject_id` 复合 PK，带 workspace/base 上下文列与索引。granted_type=user 时的具体人/组清单。

### 1.2 Model stub

`packages/nocodb/src/models/Permission.ts`：字段声明齐全（含 `subjects?`），仅两个静态方法是 stub：
- `list(context, baseId) → []`
- `isAllowed(context, permissionObj, user{id,role,is_agent?}) → true`
无 insert/update/delete 方法（EE 需自建 CRUD）。**无缓存实现**（stub 每次返回空）。

### 1.3 SDK（`packages/nocodb-sdk/src/lib/permission/index.ts`，全套就绪，零修改）

- `PermissionKey`：F02 = `RECORD_FIELD_EDIT`；F03 = `TABLE_RECORD_ADD`/`TABLE_RECORD_DELETE`；可见性 = `TABLE_VISIBILITY`；另有 DOCUMENT_/DASHBOARD_/CHAT_ARTIFACT_ 系。
- `PermissionEntity`：`TABLE`/`FIELD`/...；`PermissionGrantedType`：`role`/`user`/`nobody`；`PermissionRole` + `PermissionRolePower`（owner6→viewer2）+ `PermissionRoleMap`（Project/Workspace 角色映射）。
- `PermissionOptionValue/Options/Meta`：UI 选项（EDITORS_AND_UP 为 default；`RECORD_FIELD_EDIT.minimumRole = EDITOR`，userSelectorDescription 含 `{{field}}` 占位）。
- **`evaluatePermission(permission, principal)`：前后端共享决策函数**（注释明确要求 frontend `usePermissions` 与 backend `Permission.isAllowed` 必须同一规则）。role grant 比 rolePower；user grant 匹配 subjects（agent 主体类型隔离）；team subject 由调用方解析后传 `matchedTeamSubject`。
- `matchesTeamSubjectByPaths`（team path 祖先链匹配）、`PermissionSubject{type,id,hierarchy_scope}`、`EvaluablePermission`。
- `Api.ts:6876`：Base response 已声明 `permissions[]` 类型（含 subjects）。

## 2. 后端 hook 面

### 2.1 checkPermission no-op

`packages/nocodb/src/db/BaseModelSqlv2.ts:10429`：
```ts
async checkPermission(_params: { entity: PermissionEntity; entityId: string|string[]; permission: PermissionKey; user: any; req: any }) {} // placeholder
```

### 2.2 CE 已挂 checkPermission 的调用点（5 处，全部 link 系、全部 FIELD/RECORD_FIELD_EDIT）

| 方法 | 行号 |
|---|---|
| `addChild` | 6351 |
| `removeChild` | 6754 |
| `addLinks` | 8636 |
| `removeLinks` | 8653 |
| `reorderLink` | 8671 |

→ **实现 `checkPermission` 本体后这 5 处立即生效**，零额外接线。

### 2.3 数据主路径（CE 未挂，EE/fork 需补 per-field 检查）

`insert`(2234)、`updateByPk`(2791)、`bulkUpsert`(3559)、`bulkInsert`(4376)、`bulkUpdate`(4400)、`updateLTARCols`(4651)、`bulkUpdateAll`(4667)、`bulkDelete`(4830)、`bulkDeleteAll`(5396)。
上游注释明示 EE 做法是 **EE 覆盖文件在这些方法内做 per-field 检查**（本仓无 src/ee，需直接改 CE 方法或 fork 内 override）。

### 2.4 skipPermissionCheck 豁免通道（CE 已铺好）

参数 `skipPermissionCheck?: boolean`（注释："Consumed by the EE override to skip per-field edit-permission checks"）：
- `BaseModelSqlv2.ts` 4392(bulkInsert)/5463(beforeBulkInsert)/9130(beforeUpdate)；
- `IBaseModelSqlV2.ts:73`；
- `db/BaseModelSqlv2/insert.ts` 258/282/336/391（解构并向下传递）；
- 已有内部调用方传 `true`：`import.service.ts` 2494/2536/2603（trusted internal copies）、`bulk-data-alias.service.ts` 61/80（透传）。
→ fork 补挂点时必须尊重该参数（复制/快照/导入路径免检）。

### 2.5 Permission.list / isAllowed 现有消费方（实现后自动激活）

| 调用方 | 位置 | 用途 | 归属 |
|---|---|---|---|
| `mcp.controller.ts:82-87` `loadPermissions` | req.permissions ?? list | MCP 工具执行前装载；注释确认语义：**checkPermission 读 req.permissions，缺失列表 = 无 grant 配置 = allow（fail-open）** | 共用 |
| `helpers/tableHelpers.ts:151-211` `hasTableVisibilityAccess` | list + isAllowed | TABLE_VISIBILITY 判定（owner 直通） | F03 |
| `tables.service.ts:802` | list | 表列表可见性过滤 | F03 |
| `columns.service.ts:7963` | list | `is_private` flag（非 owner 且无可见性 → is_private） | F03/F08 交界 |
| `public-metas.service.ts:306` | hasDefaultTableVisibility | shared base 默认可见性 | F03 |
| `export.service.ts:727,753` | list | base 导出携带 permissions（enforce_* 一并导出） | 共用 |

**EE 语义推断**（由 SDK + 注释）：无 grant 行 = 默认行为（RECORD_FIELD_EDIT 默认 EDITOR+，等价 CE 现状）；grant 存在时，低于 granted 角色/不在 subjects/nobody 的用户**写该字段被 403 拒绝**（NcError，前端对应 lock 图标 + tooltip）；owner 始终通过（hasTableVisibilityAccess 同款 owner 直通先例）。

### 2.6 请求级缓存

`src/types/nc-context-cache.d.ts:18`：`NcContext.permissions?: Permission[]`——同请求内 list 一次复用。

## 3. API 面

- **不存在** permissions.controller / permissions.service / 路由注册（controllers 目录无，noco.module.ts 无注册）。
- 惯例参照 F05（`base-variables.controller.ts`，注释明写是 fork 参照模式）：NestJS controller，`@Get/Post/Patch/Delete(['/api/v1/db/meta/bases/:baseId/...', '/api/v2/meta/bases/:baseId/...'])` 双路径 + `@Acl('xxxOp')` + `@TenantContext()` + 注册进 `modules/noco.module.ts`。
- **建议端点**（v1+v2 双注册）：
  - `GET    /bases/:baseId/permissions` → list（`@Acl('permissionList')`）
  - `POST   /bases/:baseId/permissions` → create（entity/entity_id/permission/granted_type/granted_role/subjects/enforce_*）
  - `PATCH  /bases/:baseId/permissions/:permissionId` → update granted_type/role/subjects
  - `DELETE /bases/:baseId/permissions/:permissionId` → 回默认
  - 配置权限：creator+（i18n `editFieldPermissions` 菜单挂在 isUIAllowed('fieldAlter') 语境）。
- 前端调用参照 F05 `Variables/index.vue`：`$api.instance.get/patch/post/delete` 直拼路径，无需 sdk Api 再生成（Api.ts 类型已备）。

## 4. 前端面

### 4.1 数据/决策层

- `composables/usePermissions.ts` = **CE stub**：`permissionsByEntity→{}`、`isAllowed→true`、`getPermissionSummary→EDITORS_AND_UP`。EE 实现 = 装载 base permissions + 填这两个函数（内部接 `evaluateTableFieldPermission`）。**全部 UI 挂点已消费此 composable，实装即全局生效。**
- `utils/tableFieldPermission.ts`：**完整实现（非 stub）**——纯函数包装 SDK `evaluatePermission` + 匿名表单硬拒（user grant × isAnonymousFormSubmit → false）+ team path 匹配。配套测试 `test/table-field-permission.test.ts` 已在。
- `context/index.ts:395-403`：`PermissionPrincipalOverrideInj`（预览模式 principal 注入）已备。

### 4.2 消费挂点（全部已在 CE，等 usePermissions 升级）

| 挂点 | 文件:行 | 用途 |
|---|---|---|
| grid 表头 lock 图标 + PermissionsTooltip | `smartsheet/header/Cell.vue:60-63,264` | 无编辑权字段显示 ncLock |
| canvas grid 逐列可编辑/插入行 | `grid/canvas/composables/useCanvasTable.ts:399,549,1904` | TABLE_RECORD_ADD + RECORD_FIELD_EDIT + isEditRestricted |
| 复制粘贴拦截 | `useCopyPaste.ts:207` | restrictEditCell |
| 展开表单字段级 | `useExpandedFormStore.ts:119-128` | isAllowedAddNewRecord + 字段编辑 |
| 视图数据列标志 | `useViewData.ts:411` | column.isAllowedToEdit → `Form.vue:378` 无权字段在表单**隐藏** |
| 共享表单 | `useSharedFormViewStore.ts` | 匿名提交 |
| 其余 | Form.vue/KanbanOptimized/Gallery/calendar 系/expanded-form index+MoreOptionsMenu+ColumnList/VirtualCell/InfiniteTable/canvas context Cell/UnLinkedItems/ListItem/LinkedItems/ViewActionMenu/MultiColumnMenu | 遍布 |

### 4.3 配置 UI（壳全在，全渲染 `<NcSpanHidden />`）

| 组件 | 挂载方 | 职责 |
|---|---|---|
| `components/permissions/Modal/Content.vue` | `smartsheet/Details.vue:113`（表详情 permissions tab 主体） | 表+字段权限总览/编辑 |
| `components/permissions/Modal/index.vue` | — | 弹窗壳 |
| `components/permissions/Tooltip.vue`（isAllowed 恒 true stub） | 多处 | 权限 tooltip 包装 |
| `components/dlg/Field/Permissions.vue` | `header/ColumnMenu.vue:992`（558-566 菜单项） | **单字段权限配置弹窗（F02 核心）** |
| `components/dlg/Field/MultiPermissions.vue`（注释明写 "CE stub — bulk field permissions is EE-only"） | `header/MultiColumnMenu.vue:310` | 多列批量（可裁） |
| `components/dlg/Table/Permissions.vue` | `TreeView/Table/Node.vue:922` | 表权限（F03 范畴，可裁） |
| `dashboard/settings/Permissions.vue` | `project/View.vue:512`（base 设置 permissions tab） | base 级汇总 |

ColumnMenu 菜单项 gate（721-725）：`isEeUI && isUIAllowed('fieldAlter') && !isSqlView && uidt≠ForeignKey && showEEFeatures`，且 synced 字段禁配（i18n `fieldPermissionsNotAvailableForSyncedColumns`）。

### 4.4 gate 现状（F02 要解的开关）

- `useEeConfig.ts:72` `blockTableAndFieldPermissions = true`；`:379` `isEEFeatureBlocked=true`；`:386` `showEEFeatures=false`；另 `isEeUI=false`（ncUtils，勿全局翻）。
- UI 隐藏点：`Details.vue:63`（permissionsTabCondition）、`View.vue:123-125`（升级弹窗）、`View.vue:181`（tab 路由，含 isEeUI）、`View.vue:512`（tab v-if showEEFeatures）、`ColumnMenu.vue:721`（isEeUI+showEEFeatures）、`MultiColumnMenu.vue` 同款。
- **F05/F07 解 gate 模式**（View.vue 191/195/603/640 先例）：blockXxx→false + [CE-EE] 注释，tab gate 改「feature flag + creator role」绕开 showEEFeatures/isEeUI。F02 照搬。

### 4.5 i18n（`lang/en.json` 已全备）

`general.permissions`(763)、`labels.dataPermissions`(236→View.vue 用)、`permissions.*`(1067-1084：editFieldTooltip/resetTablePermissions/resetFieldPermissions/formViewFieldEditPermissionRestrictionTooltip 等)、`editFieldPermissions`(1340)、`tablePermissions/fieldPermissions`(1577/1580)、`mOfNFieldsHaveCustomPermissions`(1598)、升级弹窗键(211-212)、`tooltip.dataInThisFieldCantBeManuallyEdited`、`fieldPermissionsNotAvailableForSyncedColumns`、`permissionsNotAvailable`(430)。中文翻译需抽查。

## 5. ACL

- `src/utils/acl.ts:28` `permissionScopes`（org/base 两 scope）：**无 permission 相关 op**。需加 base scope：`permissionList`/`permissionCreate`/`permissionUpdate`/`permissionDelete`（creator+；文件自带重复校验与 role 继承，按既有条目格式追加即可）。`@Acl` 经 extract-ids 中间件生效。
- nc-gui 侧无独立 lib/acl permission 项（isUIAllowed 由后端 acl 驱动）；api-token 的 `TokenPermissionMatrix.vue` 与本 feature 无关。

## 6. 范围裁定建议

EE 完整面 = F02(RECORD_FIELD_EDIT) + F03(TABLE_RECORD_ADD/DELETE + TABLE_VISIBILITY) + Doc/Dashboard 权限 + team/agent 主体 + enforce_for_automation 完整语义 + base 设置汇总页。

**fork F02 建议最小可用面**（对照 F10 先例「CRUD+骨架即可用，外围裁掉」）：

做：
1. Permission model 实装（list/isAllowed 用 SDK evaluatePermission + CRUD + NocoCache）
2. permissions.controller/service（base 级 CRUD，v1+v2 双路径）
3. `checkPermission` 实装（owner 直通、fail-open、读 context/req.permissions）
4. 数据主路径 per-field 挂点：`updateByPk`/`bulkUpdate`/`bulkUpdateAll`/`bulkUpsert`/`insert`(单条路径) 对 changed/inserted columns 逐列检查（尊重 skipPermissionCheck）；`updateLTARCols`(4651) 补挂
5. 前端：blockTableAndFieldPermissions→false + View.vue/Details.vue/ColumnMenu/MultiColumnMenu gate 改 [CE-EE] + usePermissions 实装（拉 `GET bases/:id/permissions` 一次进 base store）+ 填壳 `dlg/Field/Permissions.vue` 与 `permissions/Modal/Content.vue`（tab 主体；表权限区如 F03 未做则只读展示或仅字段列）
6. 表单路径：enforce_for_form=true 默认——public form 无权字段前端已隐藏（Form.vue 378），后端 public-datas 提交路径做**剥离或 403**（第一版建议剥离 forbidden 字段值，与 EE「字段对提交者只读」语义对齐）

裁掉（记入 fork 限制）：
- `MultiPermissions.vue` 批量配置（先手动逐列）、`dlg/Table/Permissions.vue`（F03）、`dashboard/settings/Permissions.vue` base 汇总页（保留 stub 或仅跳转）、Doc/Dashboard/ChatArtifact 权限键、**team/agent subject**（需 teams hierarchy + org visibility gating，EE 独立大件；第一版 granted_type 仅 role/nobody + user-subject 可后置到二版）、enforce_for_automation 独立语义（保留列值，第一版与 form 同判或恒强制）。

理由：F02 单 key（RECORD_FIELD_EDIT）；拦截面后端一处 checkPermission + 少量挂点；配置面一弹窗一 tab；role+specific-users 已覆盖「谁能编辑此字段」90% 场景；team/agent 主体成本收益比差且不阻塞 F03 复用。

## 7. 风险点

1. **fail-open 契约**：无 grant = allow（mcp.controller 注释钦定）。实现勿改 fail-closed，否则全站写入炸。
2. **缓存**：建议 `nc_permissions:baseId` NocoCache 键 + permission 写路径 evict；MCP 每工具调用 loadPermissions，裸 DB 查在高频 MCP 场景放大；`nc-context-cache.d.ts` per-request 缓存已有，实现 list 时记得写入 context。
3. **update 路径挂点量**：updateByPk/bulkUpdate/bulkUpdateAll/bulkUpsert 四条都要 per-field changed-column 检查；注意 title↔column_name 双键（oldData 用 title）与 undo/audit 重放路径（`undo` 参数、onlyUpdateAuditLogs）不能误拦。
4. **复制/快照/导入**：import.service 已传 skipPermissionCheck；**duplicateBase（F07 快照走它）是否最终落到的 insert/bulkInsert 带 skip 参数需实测**——若走单条 insert 且无 skip，复制含受限字段表会被自己的权限拦住。
5. **link 系**：5 处已挂但 `updateLTARCols`（4651，bulk update LTAR 列）没挂——补齐，否则批量路径绕权。
6. **F08 组合**：columns.service `is_private` 由 TABLE_VISIBILITY 派生，与 F02 字段级正交；但 private base 内非 owner 成员 + FIELD grant 的叠加判定（base 角色映射经 PermissionRoleMap）建议 F08 实现时加回归用例。
7. **F03 联动**：同一张表同一套 API——建议端点/ACL/model 按「permissions 通用 CRUD」设计，F02 只消费 FIELD entity 部分，F03 届时零重构。
8. **审计/extract-ids**：permission CRUD 走 @Acl（meta 面）；数据写拦截在 db 层 checkPermission（在 Audit.insert 之前抛 403，天然少审计记录——EE 同款）；checkPermission 的 `req` 参数可写 audit/extra。
9. **synced 表**：前端已禁配（ColumnMenu），后端建议 create/update 时对 `model.synced` 的字段拒配（防 API 直调）。
10. **共享视图/匿名**：前端 isAnonymousFormSubmit 已硬拒 user grant；shared form 提交走 public-datas——见范围建议第 6 条。

## 8. 实现路径清单（文件级）

后端新建：
- [ ] `packages/nocodb/src/services/permissions.service.ts` — CRUD + grant 解析（新建）
- [ ] `packages/nocodb/src/controllers/permissions.controller.ts` — v1/v2 双路径，`@Acl('permission*')`（新建）

后端修改（全部加 `// [CE-EE] F02`）：
- [ ] `packages/nocodb/src/models/Permission.ts` — 实装 list/isAllowed/insert/update/delete + 缓存
- [ ] `packages/nocodb/src/utils/acl.ts` — permissionScopes base scope 加 4 op
- [ ] `packages/nocodb/src/modules/noco.module.ts` — 注册 PermissionsController
- [ ] `packages/nocodb/src/db/BaseModelSqlv2.ts` — checkPermission 实装 + updateByPk/bulkUpdate/bulkUpdateAll/bulkUpsert/insert/updateLTARCols per-field 挂点
- [ ] `packages/nocodb/src/services/public-datas.service.ts` — form 提交 forbidden 字段剥离（可选二批）

前端修改（全部加 `/* [CE-EE] F02 */`）：
- [ ] `packages/nc-gui/composables/useEeConfig.ts` — blockTableAndFieldPermissions→false（72 行处）
- [ ] `packages/nc-gui/components/project/View.vue` — 123-125/181/512 gate 改 flag+role
- [ ] `packages/nc-gui/components/smartsheet/Details.vue` — 63 permissionsTabCondition
- [ ] `packages/nc-gui/components/smartsheet/header/ColumnMenu.vue` — 721-725 isEeUI/showEEFeatures gate
- [ ] `packages/nc-gui/components/smartsheet/header/MultiColumnMenu.vue` — 同款 gate（或随裁剪保持隐藏）
- [ ] `packages/nc-gui/composables/usePermissions.ts` — 实装（数据装载 + evaluateTableFieldPermission 接线）
- [ ] `packages/nc-gui/components/dlg/Field/Permissions.vue` — 单字段配置弹窗实装
- [ ] `packages/nc-gui/components/permissions/Modal/Content.vue` — 表详情 tab 主体实装
- [ ] `packages/nc-gui/components/permissions/Tooltip.vue` — 接 usePermissions.isAllowed

不动：`utils/tableFieldPermission.ts`、`test/table-field-permission.test.ts`、nocodb-sdk（已完备）、其余全部 UI 消费挂点（自动生效）。

后端测试建议：Fork.spec 桶加 permissions 集成用例（grant editor-only 字段 → editor 403 / creator 过 / owner 过 / link 系 5 方法 / bulkUpdate / skipPermissionCheck 导入路径）。
