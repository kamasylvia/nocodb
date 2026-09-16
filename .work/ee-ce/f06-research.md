# F06 Docs Permissions 调研报告（只读调研，2026-09-15）

> flag：`FEATURE_DOCUMENT_PERMISSIONS`（sdk `payment/index.ts:130` = `'feature_document_permissions'`；官方文案 `payment/index.ts:547-548` = **"to use document permissions."**）。
> 名义范围 = 对 doc（文档页）设置 per-doc 权限：谁能看（`DOCUMENT_VISIBILITY`）/ 谁能编（`DOCUMENT_EDIT`）。
>
> **核心结论**：
> 1. **Docs 本体在 CE 里不存在——比 F04 的 App Sync 更彻底**。App Sync 至少还有 store/helper 预埋；Docs 是**后端 model/service 纯 stub + v3 service 孤儿代码（零注册）+ 前端零组件（连页面树和编辑器都没有）**。`models/Document.ts:71` 注释明说："CE has no docs feature, so these stubs are never executed"。唯一完整落地的是 **DB schema**（migrations 全在）和 **SDK 类型面**。
> 2. **F06 名义功能（Docs Permissions）在 CE 零专属代码**：无 ACL op、无 internal op、`blockDocumentPermissions` gate **全仓零消费者**（EE 消费方是 docs 编辑器组件，未随 CE 发布）；唯一可复用的是 F02/F03 建好的**通用权限框架**（nc_permissions 表 + Permission model + permissions CRUD API + 前端 usePermissions 全部 entity 无关），SDK 侧 `DOCUMENT_VISIBILITY`/`DOCUMENT_EDIT` key 与元数据全备——但 `permissions.service.ts:73-78` 目前显式拒绝 `entity=document`。
> 3. **裁定建议：F06 主体裁掉**（与 F04 裁掉 App Sync 同构：面板做出来永远空态，无产品价值）。权限框架侧只值得做一处小加固（permissions.service 放开 entity=document 的写入通道 + 文档实体验证），供未来 Docs 本体落地时零障碍接入；Docs 本体（编辑器/协同/页面树）记 backlog，需用户明确加预算再立项（见 §7 三选项）。

---

## 1. EE gating 面（FEATURE_DOCUMENT_PERMISSIONS / blockDocumentPermissions / blockDocs 全部引用点）

| 位置 | 内容 | 现状 |
|---|---|---|
| `packages/nocodb-sdk/src/lib/payment/index.ts:130` | `FEATURE_DOCUMENT_PERMISSIONS = 'feature_document_permissions'` | 枚举定义 |
| `payment/index.ts:547-548` | `'to use document permissions.'` | 官方语义：per-doc 查看/编辑权限 |
| `payment/index.ts:125-131` | 相关 flag 族：`FEATURE_DOCS`（核心 Documents，:126 注释 "Core Documents feature (create/view/edit)"）/ `FEATURE_DOCS_APIS` / `FEATURE_DOCS_INLINE_COMMENTS` / `FEATURE_DOCS_EXPORT_PDF` / `FEATURE_DOC_AI` | Docs 本体自己的 paywall，非 F06 |
| `payment/index.ts:41-43` | 限制项：`LIMIT_DOCUMENT_PAGE_PER_BASE` / `LIMIT_DOCS_PAGE_SIZE_KB` / `LIMIT_DOC_REVISION_HISTORY_DAYS` | 同上 |
| `packages/nc-gui/composables/useEeConfig.ts:255` | `blockDocumentPermissions = computed(() => true)` | **F06 名义主 gate，但全仓零消费者**（grep 证实除定义/导出 :523 外无引用——EE 消费方在 docs 编辑器组件里，未随 CE 发布） |
| `useEeConfig.ts:257` | `showUpgradeToUseDocumentPermissions = no-op` | 唯一消费点 `BaseSettingsMenu.vue:46`（导航 gate，no-op 天然不挡） |
| `useEeConfig.ts:263` | `blockDocs = computed(() => true)` | 唯一消费点 `CreateNewActionMenu.vue:42,559`（badge 回调） |
| `useEeConfig.ts:267/269/271/273` | `blockDocsInlineComments / blockDocsResolveComments / blockDocsExportPdf / blockDocShare = true` | CE 零消费者（inline comments / resolve / export pdf / share 都是编辑器内功能） |
| `useEeConfig.ts:279` | `showDocumentPagePlanLimitExceededModal = no-op` | CE 零消费者 |
| `useEeConfig.ts:387` | `showEEFeatures = computed(() => false)` | docs-permissions 双入口的第二把锁（View.vue:529 / BaseSettingsMenu.vue:134） |
| `packages/nc-gui/utils/ncUtils.ts:1` | `isEeUI = false` | BaseSettingsMenu.vue:134 与 CreateNewActionMenu.vue:556 消费；勿翻 |

后端 `packages/nocodb/src` **零处**引用 FEATURE_DOCUMENT_PERMISSIONS / blockDocumentPermissions——paywall 完全在前端。`command-registry/op-names.ts:205` 注释 `// Permissions (table / field / document)` 提及 document 但下面只有 F02/F03 的 4 个 `permission*` op，无 document 专属 op。

## 2. 前端 stub 面

### 2.1 stub UI 本体

- `packages/nc-gui/components/dashboard/settings/DocsPermissions.vue`（全文 14 行）：`defineProps<{state, baseId}>` + `defineEmits(['update:state'])` + `<NcSpanHidden />`——与 Sync/index.vue 同款空壳。**若做面板，此为前端主体工作**。

### 2.2 入口一：base settings 页 tab（`project/View.vue`）

- `View.vue:529` tab-pane：`v-if="isUIAllowed('sourceCreate') && base.id && showEEFeatures"`——showEEFeatures 恒 false → tab 永不渲染。**注意：此处无 isEeUI**，解法只需 flag+role 化（F07 :643 snapshots 模式）。
- `View.vue:535` `<LazyPaymentUpgradeBadge :feature="PlanFeatureTypes.FEATURE_DOCUMENT_PERMISSIONS">`——**已带 `:feature-enabled-callback="() => !isEEFeatureBlocked"`**（与 syncs 的裸 badge 不同，改造量更小：badge 可保留）。
- `View.vue:544` 内容区 `<DashboardSettingsDocsPermissions v-model:state="baseSettingsState" :base-id="base.id" />`——blockDocumentPermissions 不经此路径，tab 解锁后自动挂载。
- `View.vue:239` settings 页 title map 已备：`'docs-permissions': t('labels.docsPermissions')`。
- `View.vue:130` 与 `:173`（syncs 的两处 watch gate）对 docs-permissions **无对应逻辑**——无 `?page=docs-permissions` 直跳死路问题（F04 §2.2 的 View.vue:173 坑在此不存在）。

### 2.3 入口二：base settings 侧栏菜单（`BaseSettingsMenu.vue`）

- `BaseSettingsMenu.vue:134-146` 菜单项：`v-if="isEeUI && isUIAllowed('sourceCreate', {roles: effectiveRoles}) && showEEFeatures"` → 双锁齐活，永不渲染。badge :143 无 feature-enabled-callback（裸 remove-click）。
- `BaseSettingsMenu.vue:46` 导航 gate：`page === 'docs-permissions' && showUpgradeToUseDocumentPermissions(...)` → no-op，天然不挡，无需改。
- F07 先例模板：`BaseSettingsMenu.vue:261-265` snapshots 项（flag+role、无 isEeUI/showEEFeatures）。

### 2.4 路由链

- `utils/settingsRouteUtils.ts:14`：`'docs-permissions': 'docs-permissions'` slug 映射已备（与 syncs :15 同列）。
- `pages/index/[typeOrId]/[baseId]/index/settings/[page].vue` → `ProjectView :tab` 链路与 syncs 完全同构，slug 通即路由通。

### 2.5 store / api / i18n

- `packages/nc-gui/store/documents.ts`（**纯 stub**）：`activeDocument = computed(() => null)`、`documentTree = computed(() => [])`、`loadDocuments/createDocument/updateDocument/deleteDocument/reorderDocument/moveDocument` 全返回 `[]/null/true`——与 store/sync.ts 同款空壳。
- **docs UI 组件零存在**：`components/` 下无页面树、无文档编辑器。Tiptap 依赖全量在 `packages/nc-gui/package.json:40-73`（starter-kit/table/mention 等 30+ 包）+ `tiptap-markdown`（:147），但消费方只有 RichText cell / RichComment（行内评论）等非 docs 组件——**依赖已装，编辑器组件是 EE 专有未发布**。
- 无 docs 页面路由：`pages/` 下无 doc 相关文件；`store/sidebar.ts:115` `SidebarTab = 'data' | 'workflows' | 'interfaces' | 'agents' | 'settings'`——无 documents tab。
- `CreateNewActionMenu.vue:556-566` 「新建文档」菜单项：外层 `<template v-if="isEeUI">` 恒隐藏；:559 badge `:feature-enabled-callback="() => !blockDocs"`。
- `components/dlg/share-and-collaborate/View.vue:129-138` share-doc 区块：`v-if="activeDocument"`（恒 null 不渲染）+ `SharePageDoc.vue`（全文 3 行 `<NcSpanHidden />`）——分享 UI 壳已挂，等 store 有数据。
- i18n：`lang/en.json:2743` `"docsPermissions": "Docs Permissions"`、`lang/zh-Hans.json:2086` `"docsPermissions": "文档权限"`——入口文案已备。

## 3. 后端面

### 3.1 Docs 本体（CE = stub + 孤儿代码，零挂载）

| 层 | 位置 | 内容 |
|---|---|---|
| model | `models/Document.ts`（115 行，**纯 stub**） | 类型字段全声明（含 EE 的 `fk_base_section_id`/`uuid`/`password`），全部 static（get/list/insert/update/delete/softDelete/move/getDescendantIds/share/unshare/…）返回 null/[]/0；:70-72 注释明言 stub 仅为了让 `documents-v3.service.ts` 在 CE build 下 typecheck |
| service | `services/documents.service.ts`（69 行，**纯 stub**） | list/listAll/get/create/update/delete/reorder 空实现 |
| v3 service | `services/v3/documents-v3.service.ts`（268 行，**孤儿代码**） | docList/docGet/docCreate/docUpdate/docDelete/docReorder/docShare/docUnshare/docShareUpdate 逻辑真实（validatePayload 走 swagger-v3、version 乐观锁由 body.version 透传、share 有 appHooks+socket 广播），但**委托的对象是 stub**，且**整个 service 未在 `modules/noco.module.ts` 注册**（grep 证实零 import；controllers 列表 :212-280 无任何 Documents controller） |
| comments | `services/document-comments.service.ts`（69 行，**纯 stub**） | commentCreate/Update/Delete/List/toggleReaction 空实现 |
| controller | **不存在** | `controllers/v3/` 仅 7 个文件（bases/tables/columns/sorts/filters/data 等），无 documents-v3.controller；`constants/controllers.ts:3` 定义了 `PREFIX_APIV3_DOCS = '/api/v3/docs/:baseId'` 但全仓零消费 |
| swagger | `src/schema/swagger-v3.json:7098/7381/7737` | `/api/v3/docs/{baseId}`（list+create）、`/{docId}`（get+update+delete）、`/{docId}/reorder` 三条 path + `DocumentCreate/DocumentUpdate/DocumentReorder` schemas（:15449/:15472）齐全——**API 契约在，实现在 EE overlay**（share 端点无 swagger，与 Document.ts:46-48 "Phase 1 not exposed" 注释一致） |
| 中间件 | `middlewares/extract-ids/extract-ids.middleware.ts` | 无 `:docId` 参数解析（grep 证实） |
| 卫星 DB | `meta/docs-content.service.ts`（DocsContentService extends MetaService）+ `Noco.ts:125-126` | **真实可用**：`NC_DOCS_DB` env 可把 doc content/revisions 拆独立库；meta.service.ts:113 卫星表事务守卫已覆盖 DOCS/DOC_CONTENT/DOC_REVISIONS |
| Model type | `models/Model.ts:110-116`（document-only 字段 `updated_by/has_children/doc_version`）+ `utils/globals.ts:627` `DOCUMENT = 'document'` + sdk `globals.ts:125` `ModelTypes.DOCUMENT = 'document'` | documents 存 `nc_models_v2`（type='document'），Model 侧字段就位但**零消费**（trash/bases service 均无 document 分支） |
| internal ops / op-names | **零** document op | UI-ACL 通道完全未预埋 |

### 3.2 权限框架（F02/F03 遗产，entity 无关，F06 唯一可复用面）

| 层 | 位置 | 内容 |
|---|---|---|
| SDK keys | `nocodb-sdk/src/lib/permission/index.ts:21-22` | `DOCUMENT_VISIBILITY`（minimumRole viewer，label "Who can view this page"，userSelectorDescription "**and its children**"，:161-167）+ `DOCUMENT_EDIT`（minimumRole editor，"Who can edit this page"，:168-174） |
| SDK keys 组 | `permission/index.ts:235-238` | `DOCUMENT_PERMISSION_KEYS = [VISIBILITY, EDIT]` |
| SDK 继承约束 | `permission/index.ts:198-233` | `isMoreRestrictive`——注释明言用途是 "document permission inheritance"：子页权限必须 ≥ 父页限制强度（EVERYONE:0 → NOBODY:6 阶梯） |
| SDK 标志位 | `nocodb-sdk/src/lib/Document.ts:20-25` | `has_permissions` / `has_visibility_permission`（注释：匿名分享不得绕过 owner 的 DOCUMENT_VISIBILITY 限制）；`dashboard/index.ts:26-28` 同款 mirror |
| model | `models/Permission.ts`（F02 实装） | `list()`（:117 写 `context.permissions` 请求级缓存）/ `findGrants()`（:558-570，entity 无关）/ `isAllowed()`（:524-555，owner 直通 + SDK `evaluatePermission`）——**全部 entity 无关，DOCUMENT 直接可用** |
| service | `services/permissions.service.ts:73-78` | **唯一堵点**：`entity !== TABLE && entity !== FIELD → badRequest("Entity … is not supported")`——放开 entity=document 需在此加分支（key 白名单 + 实体验证） |
| controller | `controllers/permissions.controller.ts` | CRUD 四端点 `/api/v1|v2/meta/bases/:baseId/permissions[/:permissionId]` 已注册（noco.module.ts:243） |
| ACL | `utils/acl.ts:279-282`（permissionScopes）+ `:559`（permissionList: editor+） | permissionList/Create/Update/Delete 已注册，**F06 零 ACL 新增** |
| 前端 | `composables/usePermissions.ts` | `grantsFor/isAllowed/getPermissionSummary` 全部 entity 无关（:82-90 按 `${entity}:${entity_id}` 分组）——DOCUMENT grants 写入后前端解析自动生效 |

**ACL 语义**：permissions CRUD 走 F02 已验证的语义（list editor+ 可读、CUD creator+ 天然拒绝），F06 无需动。

## 4. DB 面（表全部在 CE migrations，零建表工作）

| 表 | migration | 列 |
|---|---|---|
| `nc_models_v2`（**documents 现行存储**，type='document'） | `v0/nc_202604160000_docs_in_data.ts:6-22` 加列 | + `parent_id` / `updated_by` / `has_children` / `doc_version`；索引 `(base_id, type, parent_id, order)` = `nc_models_v2_tree_idx`（:18-21，为 doc 树查询定制）；:24-79 把旧 nc_docs_v2 数据迁入 |
| `nc_docs_v2`（**已 deprecated**） | `v0/nc_202603050000_docs.ts:9-27` 建表；`utils/globals.ts:154` 注释 "@deprecated Documents now live in nc_models_v2 (type='document'). Kept for legacy data cleanup" | id / base_id / fk_workspace_id / title(512) / meta(text) / order / parent_id / deleted / has_children / version / created_by / updated_by / timestamps |
| `nc_doc_content_v2` | `meta/migrations/docs-content/nc_001_init.ts`（经 nc_202603050000:31 挂载）+ `nc_003_yjs_state.ts`（yjs_state binary，经 nc_202606021300） | fk_doc_id / base_id / fk_workspace_id / **content**（text，PG 转 jsonb）/ timestamps / yjs_state |
| `nc_doc_revisions_v2` | `docs-content/nc_002_doc_revisions.ts`（经 nc_202605281200 挂载） | id(40,uuidv7) / fk_doc_id / base_id / fk_workspace_id / version / content / title / created_by / fk_tab_id / source(16, default 'auto') / timestamps |
| `nc_comments` 扩展 | `nc_202603050000_docs.ts:34-38` | + `fk_doc_id` / `anchor_id` / 索引 |
| `nc_file_references` 扩展 | `nc_202603050000_docs.ts:42-44` + `nc_202603050001`（索引）+ `nc_202605281200`（+ `fk_revision_id`，partial index） | doc 图片/附件引用 + revision 快照行 |
| `nc_permissions` / `nc_permission_subjects` | `v2/nc_083_permissions.ts`（F02 已建） | entity 列存字符串 `'document'` 即可，**F06 零 schema 改动** |

## 5. EE 与 CE 的差异面（工作量判断关键）

- **CE 完整可用**：DB schema（全部表）；SDK 类型与权限元数据（DocumentType、PermissionMeta、isMoreRestrictive 继承规则）；F02/F03 通用权限框架（model/service/controller/ACL/前端 usePermissions）；DocsContentService 卫星库通道；swagger 契约。
- **CE 完全缺失**：① DocumentsService/Document model 实装（stub）；② documents-v3 controller + 挂载（service 代码已在但未注册）；③ share/public 端点 + `/doc/<uuid>` 匿名路由；④ 前端全部（页面树、文档编辑器、协同、share UI 数据源）；⑤ F06 专属的 doc 读路径权限过滤挂点（因 ①② 缺失而无路径可挂）。
- **EE 的 F06 完整形态**（从 SDK 元数据反推，`permission/index.ts:161-174` + `Document.ts:20-25`）：docs 编辑器内对每个页面设 `DOCUMENT_VISIBILITY`（可见性，约束子树 + 拦公共分享）与 `DOCUMENT_EDIT`（编辑权），父子页继承需满足 `isMoreRestrictive`；`has_permissions`/`has_visibility_permission` 标志位随 doc list/get 返回驱动 UI 角标。
- **对照先例**：F04 裁掉 App Sync 的理由是「后端引擎零实现，面板做出来永远空态」；F06 面临同构局面且更重——F06 还叠加「docs 本体（编辑器/协同）是 EE 独立产品线」问题。工作量排序：`F06-面板骨架 ≈ F01 < F06-mini-docs(无协同 CRUD 面板) ≈ F02+F07 之和 ×2 << F06-完整(含协同编辑器)`。

## 6. 实现方案（按投入档位分三选项，全部 `// [CE-EE] F06` 标记）

### 选项 A：权限面板骨架（最小可达面，≈F01 量级）——「空态可运行」

后端（2 处）：
- [ ] `services/permissions.service.ts:73-78` — 放开 `entity === PermissionEntity.DOCUMENT`：key 白名单用 `DOCUMENT_PERMISSION_KEYS`（sdk `permission/index.ts:235`）；实体验证 `Model.get(context, entity_id)` + `model.type === ModelTypes.DOCUMENT`（照 :80-103 TABLE 分支模式）。**但当前无任何通道能产生 type='document' 的 Model 行** → 需同批加一条最小列端点或在验证处直接查 `nc_models_v2` 并说明现状
- [ ] `noco.module.ts` — 注册 `DocumentsV3Service`（:26 构造函数只依赖已注册的 DocumentsService stub，注册即无害）

前端（3 处）：
- [ ] `composables/useEeConfig.ts:255` — `blockDocumentPermissions` → `false`（照 :429 blockSnapshots 模式；虽无消费者，解掉为语义完整）
- [ ] `components/project/View.vue:529` — tab v-if flag 化：`!blockDocumentPermissions && isUIAllowed('sourceCreate') && base.id && !isMobileMode`（照 :643 snapshots 模式；:535 badge 已带 feature-enabled-callback，保留即可）
- [ ] `components/dashboard/TreeView/Project/BaseSettingsMenu.vue:134-146` — v-if flag 化（去 `isEeUI &&`、`showEEFeatures` → `!blockDocumentPermissions`；:46 导航 gate no-op 不动）
- [ ] `components/dashboard/settings/DocsPermissions.vue` — 实装面板：复用 `usePermissions`（loadPermissions/isAllowed 直接可用）+ permissions CRUD 四端点（`controllers/permissions.controller.ts` 已备）；**文档列表数据源为空 → 渲染空态引导**（"Docs 功能未启用" fork 限制说明）

测试：e2e 直调 permissions API 断言 entity=document 的 400→（放开后）200/404 路径；面板空态截图。

**评价**：能验证权限通道全通，但无 docs 数据可管，产品价值 ≈ 0；仅作为「为未来铺路」的语义解封。

### 选项 B：mini-docs 本体 + 权限面板（F02+F07×2 量级，需用户确认加预算）——「有真数据」

1. 后端实装 stub：`models/Document.ts` 全 static（nc_models_v2 type='document' + nc_doc_content_v2 读写，version 乐观锁）+ `services/documents.service.ts` CRUD/reorder + 新建 `controllers/v3/documents-v3.controller.ts`（swagger-v3.json:7098/7381/7737 三条 path 照抄）+ `noco.module.ts` 注册——v3 service 逻辑已写好，纯补底层。
2. 前端最小面：base home 树挂 docs 分区（列表/新建/重命名/删除/拖拽 reorder）+ **单页 Tiptap 编辑器**（依赖已全装，无协同，保存走 docUpdate version CAS）。
3. 权限面 = 选项 A 全部 + 编辑器内 per-doc 权限入口（DOCUMENT_VISIBILITY/EDIT 两键，UI 复用 `dlg/Table/Permissions.vue` 模式）+ 读路径过滤（docGet/docList 挂 `Permission.findGrants`，照 `helpers/tableHelpers.ts:148-210` hasTableVisibilityAccess 模式）。
4. share/协同/inline comments/export pdf 全裁（记 backlog）。

### 选项 C（推荐）：F06 主体裁掉，只做语义记录

- 不动代码（或仅落选项 A 的 useEeConfig 注释行）；`.work/TODO.md` 记 F06 = blocked on「Docs 本体缺失」，裁掉理由与 F04 裁 App Sync 同构。
- 功能表 F06 状态改 `裁剪`（对照 F04 的裁剪先例）。

## 7. 范围裁定建议

**裁定依据**（对照 §5 差异面与既有 pass 功能的判定标准——「fork 预算内必须有真实数据可管」）：

1. F01/F05/F07/F10 的共同前提是「后端 stub 但引擎/表/链路在 CE 可用，补实装即有真数据」；F04 的 legacy sync 也满足此条所以面板做了。**F06 不满足**：docs 本体的引擎（editor/协同）与 API 挂载全缺，权限面板的管理对象（document）无法产生。
2. `FEATURE_DOCUMENT_PERMISSIONS` 的官方语义（payment/index.ts:547 "to use document permissions."）是 docs 编辑器的从属功能——**皮之不存**。裁 F06 主体不是丢功能，是把「自建整个 Docs 产品线」这个 > 全部已 pass 功能之和的成本显式化。
3. SDK 侧 `DOCUMENT_PERMISSION_KEYS`/`PermissionMeta`/`isMoreRestrictive` 已全备且 entity 无关的权限框架已验证（F02 七轮 + F03 数轮会审）——**未来做 docs 本体时权限面零重造**，现在裁掉不产生技术债。

**做（若用户确认裁剪）**：选项 C；或最低限度选项 A 的 useEeConfig:255 注释级解封（无行为变化，纯语义）。

**裁掉（记 fork 限制 / backlog）**：

- **Docs 本体全家**：页面树、Tiptap 编辑器、yjs 协同（`nc_doc_content_v2.yjs_state`）、doc revisions 历史、inline comments/resolve、export pdf、doc AI、`/doc/<uuid>` 公共分享（`FEATURE_DOCS`/`FEATURE_DOCS_APIS`/`FEATURE_DOCS_INLINE_COMMENTS`/`FEATURE_DOCS_EXPORT_PDF`/`FEATURE_DOC_AI` 各 flag 对应面）。
- **`has_permissions`/`has_visibility_permission` 标志位产出**：属 doc list/get 响应（Document.ts:20-25），无 docs API 即无产出点。
- **`fk_base_section_id`（base 级侧栏分区）**：Document.ts:14-16 标注 EE-only，配套 UI `DashboardMiniSidebarSectionCreateMenuItem` 在 CE 是空壳 stub。
- **公共分享绕行守卫**（Document.ts:22-24 的 visibility vs share 规则）：随 share 端点一并裁。

**若用户明确要做**：走选项 B，先做 docs 本体最小面（CRUD + 单页编辑器，无协同），权限面板第二批次；两批次各自过会审闭环，合计预算按 F02+F07 之和 ×2 预估。

---

## 范围裁定（2026-09-17 03:xx，主会话依研究推荐 + F04 先例执行；用户可随时推翻重启 A/B）

**裁定：选项 C——F06 整体裁剪，功能表记 fork 限制（非 pass）。**

- 依据：Docs 本体（页面树/编辑器/model/service/controller/前端组件）在 CE 零存在；权限面板无管理对象 = 永远空态（同 F04 裁 App Sync 的同构裁定）；选项 B 预算 ≈ F02+F07 之和×2 需用户显式确认，未获输入不默认扩张
- 可逆性：本裁定完全可逆——上游 CE 落地 Docs 本体、或用户给出预算指令时，按本报告选项 A/B 重启即可（DB schema 与 SDK 类型面完整保留，F02/F03 权限框架直接复用）
- 功能表：F06 记「fork 限制——待 Docs 本体」，不计入 pass；总可达 = F09 完成后 9/10
