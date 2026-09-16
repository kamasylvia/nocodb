# F09 Sync data（Table Sync / Custom Sync）调研报告（只读调研，2026-09-17）

> flag 族：`FEATURE_TABLE_SYNC`（sdk `payment/index.ts:101` = `'feature_table_sync'`，官方文案 `:512` = **"to use NocoDB Sync."**）/ `FEATURE_TABLE_SYNC_AUTO`（`:102`，文案 `:513` "to use automatic NocoDB Sync."）/ `FEATURE_CUSTOM_SYNC`（`:103`，文案 `:514` "to use Custom Sync."）。
> 官方语义（i18n + SDK 类型反推）：**Table Sync（"NocoDB Sync"）= 把另一个 base 的共享视图镜像成本 base 内的只读同步表**（`lang/en.json:1858-1859`："NocoDB Sync" / "Mirror a shared view from another NocoDB base"）；**Custom Sync（"App Sync"）= 经 integration 连接器从外部 SaaS/服务拉数入 base**（`en.json:1860-1861`："App Sync" / "Pull data from an external service into this base"）。
>
> **核心结论**：
> 1. **F09 不是一片荒漠，是「下游全通、上游断头」**。CE 已吸收 EE Table Sync 的**全部下游基础设施**：DB 三表（nc_table_syncs / nc_table_sync_mappings / nc_table_sync_column_mappings，4 个 migration 全在）、dest 侧只读守卫链（insert/update/delete/form/permission/column/table-delete 六层全实装，`BaseModelSqlv2.ts:5595` 等 8 处）、source 侧 `allow_sync` 开关（views.service 全实装 + swagger 已文档化）、ACL 十 op、SDK 类型全备、i18n 中英文案**整套创建向导 + 管理面已预埋**、31+ 前端文件已适配 `table.synced`。**唯一缺失 = 引擎本体**（model/service/controller/job 零文件）+ 创建向导 UI 实装。
> 2. **与 App Sync（F04 裁掉的 SyncConfig）完全不同**：Table Sync 的数据通路在 fork 内**真实存在**（base-to-base 镜像，无需任何外部凭证），是 F04/F06 式「永远空态」裁剪逻辑的**反例**——F09 做.Table Sync 有真数据可管，符合 pass 标准。
> 3. **Custom Sync（integration 连接器）是真正的无底洞**：连接器框架只有抽象类（`noco-integrations/core/src/sync/types.ts:166` `SyncIntegration` abstract，`getDestinationSchema` + `fetchData` 流式接口），**仓内零具体连接器**（registry 零注册；schema-*.ts 只是 6 个 SaaS 垂类的表 schema 定义）；引擎零实现（`SyncDataSyncModuleJobData` 全仓仅 Jobs.ts:385 定义、零消费者）。做它 = 自建连接器 + 引擎 + 向导三层，与 F04 裁 App Sync 同构，**建议裁**。
> 4. **F04 预埋评估（任务要求连带裁定）**：SyncConfig 的 DB 表/SDK 类型/syncUtils.ts/store 在 F09 的 Table Sync 路径**不激活**（Table Sync 用 `nc_table_syncs` 三表，与 `nc_sync_configs` 无关）；仅 Custom Sync 阶段才会消费——Custom Sync 裁则预埋继续休眠，零冲突。
> 5. 工作量：分四阶段交付，P1（Table Sync 手动同步最小闭环）≈ F07×1.5，P1+P2 ≈ F03 级；完整四阶段 > F02+F03+F07 之和——**「最大件」名副其实，但 P1 可独立交付 pass**。

---

## 1. EE gating 面（三 flag / 三 gate 全部引用点）

### 1.1 SDK flag 定义

| 位置 | 内容 |
|---|---|
| `packages/nocodb-sdk/src/lib/payment/index.ts:101` | `FEATURE_TABLE_SYNC = 'feature_table_sync'` |
| `payment/index.ts:102` | `FEATURE_TABLE_SYNC_AUTO = 'feature_table_sync_auto'`（自动同步粒度独立付费点，对照 F04 的 `FEATURE_SYNC_15_MIN` 模式） |
| `payment/index.ts:103` | `FEATURE_CUSTOM_SYNC = 'feature_custom_sync'` |
| `payment/index.ts:512-514` | 官方文案三条（见报告头） |

### 1.2 前端 gate（useEeConfig）

| 位置 | 内容 | 消费现状 |
|---|---|---|
| `packages/nc-gui/composables/useEeConfig.ts:160` | `blockTableSync = computed(() => true)` | **全仓零消费者**（除定义 + :608 导出；grep 证实） |
| `useEeConfig.ts:162` | `blockTableSyncAuto = computed(() => true)` | 同上（:609 导出），零消费者 |
| `useEeConfig.ts:164` | `blockCustomSync = computed(() => true)` | 同上（:610 导出），零消费者 |
| `useEeConfig.ts:327` | `showUpgradeToUseTableSync = no-op` | 零 CE 消费者 |
| `useEeConfig.ts:329` | `showUpgradeToUseCustomSync = no-op` | 零 CE 消费者 |
| `useEeConfig.ts:158` | `blockSync = false`（F04 已解，带 `[CE-EE] F04` 注释） | F09 照此模式解 :160/:162/:164 |
| `useEeConfig.ts:387` | `showEEFeatures = computed(() => false)` | **本功能唯一的活 gate**——两个真实入口被它锁死（§2.1/§2.2） |

**gate 与 UI 的对应关系**（从消费反推）：`FEATURE_TABLE_SYNC` 的 UI 消费方只剩 **share 视图弹窗的 allow_sync 开关 badge**（SharePage.vue:711/717/739，见 §2.3）——即「源侧开关」用 flag 直接付费锁；「目标侧」的创建向导/管理面组件是 EE 专有未发布，本应以 `blockTableSync`/`blockTableSyncAuto` 锁，但 CE 中组件不存在 → gate 成了零消费者的死锁（与 F06 `blockDocumentPermissions` 同款局面）。`FEATURE_TABLE_SYNC_AUTO` 对应创建向导里 "Sync method: Automatically/Manually"（i18n `en.json:1876-1878`），EE 用它锁 automatic 档；`FEATURE_CUSTOM_SYNC` 对应向导第一屏的 "App Sync" 档（`en.json:1860`）。

### 1.3 后端

后端 `packages/nocodb/src` **零处**引用 FEATURE_TABLE_SYNC / FEATURE_CUSTOM_SYNC / 三个 block gate——paywall 完全在前端（与 F04/F05/F06 一致）。source 侧 `allow_sync` 的后端写入通道 `views.service.ts:293` **无任何 paywall**（§3.2）。

## 2. 前端面（入口 / 组件 / i18n / store）

### 2.1 入口一：base Overview「新建同步」（目标侧，创建向导入口）

- `packages/nc-gui/components/project/Overview.vue:134`：`<ProjectActionCreateNewSync v-if="!isMobileMode && showEEFeatures" :base-id="base?.id" />`——showEEFeatures 恒 false → 永不渲染。**解法 = flag 化**（照 F07 snapshots 模式）。
- `components/project/Action/CreateNewSync.vue` 全文 **9 行**：props `{baseId?}` + `<NcSpanHidden />` 空壳——**F09 前端主体工作 1：创建向导对话框**（EE 原件未随 CE 发布，需自建；i18n 文案已全备，见 §2.4）。

### 2.2 入口二：表树同步管理（目标侧，已建同步的管理面）

- `components/dashboard/TreeView/Table/Node.vue:855-861`：`<DashboardTreeViewTableSyncMenuOptions v-if="isEeUI && table.synced" .../>`——**isEeUI 恒 false** + `table.synced` 无引擎永远 false → 双死锁，永不渲染。
- `Node.vue:497-504`：表节点 tooltip 的 title 槽挂 `<DashboardTreeViewTableSyncStatusBadge :table="table" />`，tooltip `:disabled="!table?.synced || ..."`——不受 isEeUI 锁（synced 真了会自动显）。
- `Node.vue:862-863`：`enabledOptions.tableDelete && !table.synced`——synced 表藏删除项（守卫已备）。
- `components/dashboard/TreeView/Table/SyncMenuOptions.vue` 全文 **16 行** `<NcSpanHidden />`——**F09 前端主体工作 2**：Edit sync / Sync now / Pause sync / Resume sync / Convert to regular table / Delete sync 菜单（i18n 键全备：`en.json:1888/1891/1893/1894/1890/1892`）。
- `components/dashboard/TreeView/Table/SyncStatusBadge.vue` 全文 **12 行**：非空壳！已渲染 `labels.syncedTable`（"Synced table"）标签——tree tooltip 直接可用，可能需扩展 status（syncing/paused/error 徽标，i18n `en.json:1856-1857` "Syncing"/"Paused" 已备）。

### 2.3 入口三：share 视图弹窗 allow_sync 开关（源侧）

- `packages/nc-gui/components/dlg/share-and-collaborate/SharePage.vue:707-748`：grid 视图的 "Allow sync" 开关区块，外层 `v-if="showEEFeatures && activeView?.type === ViewTypes.GRID"`（:708，showEEFeatures 恒 false → 永不渲染）；开关经 `PaymentUpgradeBadgeProvider :feature="FEATURE_TABLE_SYNC"`（:711）付费锁，badge 文案 `upgrade.upgradeToUseTableSyncSubtitle`（:719）。
- 开关逻辑已完整实装：`:467` `allowSync = computed(() => !!(activeView.value as any)?.allow_sync)`、`:469-483` `toggleAllowSync()` 调 `viewStore.updateView(id, { allow_sync: next })`——**解 gate 即用**（:708 去 showEEFeatures、:711-747 badge 改 `:feature-enabled-callback` 或移除，照 F04 §6 模式）。
- 源侧语义：`en.json:4624` `allowSyncDescription` = "Let other bases sync data from this view"。

### 2.4 i18n（整套 UX 已预埋，中英双备）

`packages/nc-gui/lang/en.json` 关键块（zh-Hans.json 对应 :1391-1423 / :2904 / :3156 等，已翻译）：

- **向导流**：`labels.tableSync`(:1858) / `tableSyncDesc`(:1859) / `integrationSync`(:1860 "App Sync") / `integrationSyncDesc`(:1861) / `createSyncTable`(:1862 "Create sync") / `sourceModeBrowse|BrowseDesc`(:1864-1865 "Pick a base and view you already have access to") / `sourceModePasteLink|Desc`(:1866-1867 "Use a shared view URL — handy for syncing from another workspace") / `enableSync`(:1868) / `fieldsToSync`(:1869) / `allFieldsAreSyncedByDefault`(:1870) / `selectSpecificFieldsToSync`(:1871) / `syncSettings`(:1872) / `syncMethod`(:1873) / `automatically|Desc`(:1874-1875) / `manually|Desc`(:1876-1877) / `recordsDeletedInSourceWillBe`(:1878) / `deletedInMirroredTable|retainedInMirroredTable`(:1879-1880) / `sharedViewLink`(:1881)。
- **管理面**：`gettingStartedWithSync`(:1883) / `settingUpNocoDBSync`(:1884) / `troubleshootNocoDBSync`(:1885) / `noSyncsYet`(:1887) / `syncNow`(:1888) / `updateSyncConfiguration`(:1889) / `convertToRegularTable`(:1890) / `freezeSync`(:1891 "Pause sync") / `resumeSync`(:1892) / `retrySync`(:1893) / `errored`(:1894) / `lastSynced`(:1895) / `lastSyncFailed`(:1896) / `syncPausedHint`(:1897) / `syncNotYetRun`(:1898) / `editSync`(:1899) / `deleteSync`(:1900)。
- **守卫/错误提示**：`toasts.tableSyncConvertMainTable`(:5280，转正警告) / `toasts.syncDetachTable`(:5279) / `toasts.removeSyncedFieldsDropsColumns`(:5303) / `toasts.removeSyncedLinkFieldDropsJunctionShadow`(:5304，LTAR junction/shadow 面) / `toasts.syncNoUpdatedAtColumn`(:5273-5276，增量同步需 UpdatedAt 字段) / `info.sourceViewRebindResync`(:5316) / `error.failedToCreateSync`(:5833) / `error.failedToResolveLink`(:5834) / `error.sourceViewNotFound`(:5835) / `error.syncSourceTableDeleted|Desc`(:5836-5837) / `error.syncMainMappingMissing|Desc`(:5838-5839)。
- 入口 badge：`upgrade.upgradeToUseTableSync`(:266) / `upgradeToUseTableSyncSubtitle`(:267) / `activity.allowSync`(:4345) / `tooltip.allowSyncDescription`(:4624)。

**解读**：i18n 覆盖了完整 EE 向导（选档 → browse/paste 源模式 → 字段筛选 → 同步方式 → 删除策略 → 创建）+ 管理生命周期 + 异常态文案，且**错误分支与 SDK 类型一一对应**（main mapping missing ↔ `TableSyncMappingRole.Main`；resolve link ↔ `tableSyncResolveLink` op；rebind resync ↔ `source_input_mode` immutable）。自建向导可直接按这套文案铺 UI，无需产品再设计。

### 2.5 其它前端适配面（table.synced 已接入的 31+ 文件）

`grep -rln '\.synced' packages/nc-gui/components|composables|store|utils` 实测 31 文件，关键消费：

- 网格只读：`smartsheet/grid/canvas/index.vue`、`.../composables/useCanvasTable.ts`、`useCopyPaste.ts`、`InfiniteTable.vue`、`header/Cell.vue`、`header/ColumnMenu.vue`、`header/Menu.vue`、`header/VirtualCell.vue`（synced 表单元格/列头只读渲染已备）。
- 展开侧：`expanded-form/MoreOptionsMenu.vue`、`presentors/Fields/ColumnList.vue`。
- 审计降噪：`expanded-form/Sidebar/Audits.vue:131`、`AuditMiniItem.vue:50` 调 `utils/syncUtils.ts` 的 `isSyncSystemColumnTitle`（隐藏 RemoteId 等 11 个系统列的修订记录）。
- 视图守卫：`dashboard/TreeView/CreateViewBtn.vue`（form 视图禁建）、`smartsheet/toolbar/ViewActionMenu.vue`、`topbar/ViewListDropdown.vue`、`TableListDropdown.vue`。
- 虚拟单元格：`virtual-cell/ManyToMany.vue`、`Links.vue` 及 3 个子组件（LTAR 在 synced 表上的只读）。
- 杂项：`general/TableIcon.vue`、`nc/Icon/Table.vue`（同步表图标）、`cmd-k/index.vue`、`command-palette` 响应 `synced` 字段、`dashboard/settings/UIAcl.vue:215`（F03 面板透传 synced 图标）。
- SDK 侧系统列隐藏：`nocodb-sdk/src/lib/UITypes.ts:482` `isHiddenCol` 用 `SYNC_SYSTEM_COLUMN_TITLES.includes(col.title)`。

**结论：目标侧「synced 表只读化」的 UI 层在 CE 已全量就位，F09 引擎把 `synced:true` 写进 nc_models 后整条 UI 链自动生效，零前端守卫新增。**

### 2.6 store / helper / API 通道

- `packages/nc-gui/store/sync.ts`（79 行，纯 stub）：全部为 **App Sync（SyncConfig）** 服务（f04 §2.5 已盘点）——Table Sync 不消费它（类型都对不上：SyncConfig vs TableSyncType）。**F09 勿动，勿翻 `isSyncFeatureEnabled`**（其三个消费组件是 integration UI 面，f04 §2.5）。
- `packages/nc-gui/utils/syncUtils.ts`（131 行）：`isSyncSystemColumnTitle` + `getSyncFrequency` + `defaultSyncConfig`/`SyncFormStep`/`IntegrationConfig`（后四者为 App Sync 向导预埋）。Table Sync 路径仅消费 `isSyncSystemColumnTitle`（§2.5 审计两处）。
- **SDK 无 tableSync 端点封装**：生成的 `nocodb-sdk/src/lib/Api.ts` 中 `tableSync`/`table-sync` **零命中**——前端调 Table Sync 一律走 `$api.internal.getOperation/postOperation`（`operation: 'tableSyncList'` 等），先例 = F04 AirtableImport.vue:143-265 的 syncSource* 调法。
- SDK 类型全备：`nocodb-sdk/src/lib/sync/table-sync.ts`（93 行，全文类型见 §5.1）。

## 3. 后端面

### 3.1 缺口清单（有 ACL 无 controller = 引擎本体零实现）

| 层 | 现状 | 证据 |
|---|---|---|
| model | **无** TableSync model 文件（models/ 仅 SyncLogs.ts、SyncSource.ts，均为 legacy Airtable sync） | `ls packages/nocodb/src/models/` |
| service | **无** table-sync service | grep `tableSync` services/ 零命中 |
| controller | **无**（REST 与 internal ops 双缺） | controllers/ 零文件；`controllers/internal/modules/UiGet|UiPost.operations.ts` 零 tableSync op |
| job processor | **无**：`JobTypes.TableSyncRun = 'table-sync-run'`（`interface/Jobs.ts:68`）已注册进 job 类型清单（:133），`TableSyncJobData`（:396-403：`syncId` + `mode: 'full-create'|'full-resync'|'incremental'` + `affectedIdsBySource`）已定义，但 `modules/jobs/jobs/` 下 **无 table-sync 目录**（现有 14 个 job 目录实测清单，最近的是 at-import/meta-sync/source-create 等） | `ls packages/nocodb/src/modules/jobs/jobs/` |
| extract-ids | **无** `:tableSyncId` 参数解析（extract-ids.middleware.ts grep 零命中）——REST 路径中间件需补 | grep 实测 |
| ACL | **十 op 全注册**：`utils/acl.ts:320-329`（permissionScopes）tableSyncList/Get/SourceSchema/Create/Update/Delete/Resync/Freeze/Resume/ResolveLink + `:1088-1097` descriptions（"view list of table syncs"…"resolve a source share link for a table sync"）。**注意 ACL 语义**：十 op 在 permissionScopes 里 = editor+ 可读、creator+ 可写（F02/F03 已验证的 include 模型语义），**注册了却无 controller 消费 = 现状死代码**，controller 补上即自动生效 | acl.ts 实测 |
| op-names（command palette） | 8 个 tableSync\* 命令名已注册：`command-registry/op-names.ts:179-186`（Create/Update/Delete/Freeze/Resume/ConfigUpdate/DetachTable/AttachTable），归属注释 `:178 // Table Sync (table-to-table)`，与 `:173 // Sync (legacy SyncSource)`、`:188 // App Sync (integration-based SyncConfig)` 三方分列清晰 | op-names.ts 实测 |
| 缓存键 | `utils/globals.ts:575-577` CacheTypes `TABLE_SYNC`/`TABLE_SYNC_MAPPING`/`TABLE_SYNC_COLUMN_MAPPING` 已备，**零消费者**（EE model 层缓存用，fork 可不用） | grep 零命中 |
| meta 别名 | `meta/meta.service.ts:201-203`：三表查询别名 tss/tsm/tscm 已注册（MetaService 层零障碍） | 实测 |

### 3.2 已实装面（CE 现成，引擎直接消费）

**源侧 allow_sync（共享视图可被同步开关）——完整实装、无 paywall**：

- 模型：`models/View.ts:118`（`allow_sync?: boolean`）、`:1937/:1952`（viewUpdate 白名单含 allow_sync）。
- 服务：`services/views.service.ts:293-323` update 路径五重守卫全在——① 仅 grid 视图（:295-299）；② personal view 仅 owner（:300-307）；③ **synced 表不可开 allow_sync**（:309-318，防同步环）；④ 开启时若无 uuid 自动创建共享链接（:319-321 + :437-445 `View.share` + SHARED_VIEW_CREATE hook）；⑤ 删共享视图时回落 `allow_sync:false`（:797-799 + :810-816 meta 事件）。
- swagger 已文档化：`schema/swagger.json:29380`（ViewType）与 `:29717`（ViewUpdateReq?）两处 `allow_sync`，description **"Whether this view can be used as a source for internal sync."**——官方契约明确。
- SDK 类型：`nocodb-sdk/src/lib/Api.ts:7487/:7577` `allow_sync?: BoolType`（ViewType/ViewUpdateReq?）。
- resolve-link 的 CE 可用通道：`controllers/public-metas.controller.ts:12-24` `GET /api/v1|v2/public/shared-view/:sharedViewUuid/meta`（paste-link 模式解析共享视图元数据的现成公开端点；密码校验在 public-datas 侧）。

**目标侧 synced 表只读守卫链——六层全实装**（引擎不写这些，引擎创建 `synced:true` 的表后这些自动生效）：

| 层 | 位置 | 守卫 |
|---|---|---|
| 行写 | `db/BaseModelSqlv2.ts:5595`（insert）/`:5617`（bulkInsert）/`:6141`（delete）/`:6160`（bulkDelete） | `!allowSystemColumn && model.synced → prohibitedSyncTableOperation`——**`allowSystemColumn` 参数即引擎白名单通道**（引擎写系统列/数据时传 true 绕过） |
| 表单视图 | `services/forms.service.ts:68-73` | synced 表禁建 form view |
| 列改 | `services/columns.service.ts:981-984`（update）/`:5095-5102`（delete） | synced+readonly 列禁改/禁删；`:877` `bypassSyncedFieldGuard` 参数 = **引擎传播源列类型变更的白名单通道**（:976-980 注释明言 "Used by the table-sync handler when propagating a source type change — the handler is the authority"）；删除侧 `forceDeleteSystem` 参数同理 |
| 表删 | `services/services/tables.service.ts:379-382` | synced 表禁删，`forceDeleteSyncs` 旁路（mm 表同款 :387） |
| 表建 | `services/tables.service.ts:884` | **`tableCreate` 原生接受 `param.synced → { synced: true }`**——引擎建镜像表就是走这个口 |
| 权限 | `services/permissions.service.ts:49/:98` | synced 表拒配 table/field permissions（F03 已消费过此守卫） |
| allow_sync | `services/views.service.ts:316` | synced 表不可再作为同步源（防链式同步环） |
| detached 工具 | `models/Model.ts:1405-1415` `Model.updateSynced(context, modelId, synced)` | 转 regular 表 / detach 的现成 static（配套把 `nc_columns.readonly` 批量翻 false 的逻辑在 detach migration 里有同款裸 SQL 可抄，`nc_202606121400:38-44`） |
| 错误文案 | sdk `error-handler/nc-error-base.ts:885-900` `prohibitedSyncTableOperation`（四 operation 分支文案）+ `helpers/ncError.ts` 转发 | 全备 |
| 命令面板 | `services/command-palette.service.ts:78/:112` 透传 `synced` | 全备 |

### 3.3 Custom Sync / App Sync（SyncConfig）孤儿件盘点（F04 §3.2 结论复核 + 增补）

- op-names：`appSyncCreate/Update/Delete/DetachTable/AttachTable/ConfigUpdate` 六枚举（op-names.ts:188-194）零消费者。
- job 接口：`interface/Jobs.ts:384-393` `SyncDataSyncModuleJobData`（syncConfigId + trigger + bulk + fullResync）**全仓仅此一处定义、零消费者**。
- 错误 helper：`helpers/ncError.ts:259-260` `syncConfigNotFound` 零消费者。
- 缓存键：CacheTypes `SYNC_CONFIGS`/`SYNC_MAPPINGS`（globals.ts:573-574）零消费者。
- 连接器框架：`packages/noco-integrations/core/src/sync/types.ts`——`SyncIntegration` abstract class（:166 起，`getDestinationSchema(): Promise<SyncSchema|CustomSyncSchema>` + `fetchData(): DataObjectStream<SyncRecord>` 流式契约、batchSize 钩子）+ `SyncSchema = Partial<Record<TARGET_TABLES, SyncTable>>`（:540-543）+ `CustomSyncSchema = Record<string, SyncTable>`（:542-545）+ `CustomSyncPayload`（:548-556）+ `SyncRecord`/`CustomSyncRecord`（:610-628，RemoteCreatedAt/RemoteUpdatedAt/RemoteDeleted/RemoteRaw/RemoteSyncedAt/RemoteNamespace 系统字段）。**框架真实完备，但 registry 无任何 SyncIntegration 注册、仓内零具体连接器**（`ls noco-integrations/core/src/sync/`：只有 schema-calendar/crm/filestorage/hris/ticketing/custom 6 个**表 schema 定义**文件 + types/common/index）。
- 前端：`components/workspace/integrations/SyncPanel.vue`（5 行空 div，唯一消费者 `integrations/forms/EditOrAdd/Common/index.vue:165`）+ store/sync.ts + syncUtils.ts 向导 helpers——全 stub。
- 垂类目标表：SDK `sync/index.ts:150-216` `TARGET_TABLES`（ticketing_ticket/user/comment/team、hris_employee/employment/location、fs_file/folder、calendar_event、crm_account/contact/user）+ TARGET_TABLES_META——为 SaaS 连接器设计的固定 schema 集，**与「连用户自己的 PostgreSQL/MySQL」场景不匹配**（后者只能走 CustomSyncSchema 自定义路径）。

## 4. DB 面（三表 + 源列，全部在 CE migrations，零建表工作）

| 对象 | migration | 内容 |
|---|---|---|
| `nc_views.allow_sync` + `nc_table_syncs` + `nc_table_sync_mappings` | `meta/migrations/v0/nc_202605180000_table_syncs.ts`（:5-7 加列；:9-33 建主表；:35-64 建映射表；:66-72 down） | **nc_table_syncs**：id(20)/base_id/fk_workspace_id/title(255)/**selected_fields(text，null=全字段)**/on_delete_action(32)/sync_trigger(32)/status(16, default 'active')/last_error(text)/last_synced_at/sync_job_id(255)/**source_input_mode(16, default 'browse')**/created_by/updated_by/timestamps；PK (base_id,id) + 索引 (fk_workspace_id,base_id)。**nc_table_sync_mappings**：id/base_id/fk_workspace_id/fk_table_sync_id/**source_workspace_id/source_base_id/source_table_id/source_view_id/source_uuid(255)/source_password_hash(text)**/dest_base_id/dest_table_id/**role(16)**/timestamps；三索引：源三元组、source_uuid、fk_table_sync_id |
| `nc_table_sync_column_mappings` | `v0/nc_202605200000_table_sync_column_mappings.ts`（:6-45） | id/base_id/fk_workspace_id/fk_table_sync_id/fk_table_sync_mapping_id/source_workspace_id/source_base_id/source_table_id/**source_column_id**/dest_base_id/dest_table_id/**dest_column_id**/timestamps；四索引：源列三元组（源列事件→受影响目标列，注释 :29-30 "COLUMN_UPDATED, COLUMN_DELETED"）、fk_table_sync_mapping_id（级联清理）、fk_table_sync_id（per-sync 清理）、dest_column_id（目标列被外部删除反查） |
| 软删 | `v0/nc_202606040000_soft_delete_syncs.ts` | `nc_sync_configs`+`nc_table_syncs` 加 `deleted` 布尔；`nc_sync_mappings`+`nc_table_sync_mappings` 加 `status`(20, default 'active')（**后被下一 migration 撤销**） |
| 悬挂清理 | `v0/nc_202606121400_detach_suspended_sync_mappings.ts`（:1-14 注释全文值得读） | "App-sync re-architecture: synced destination tables no longer pass through trash"——清 suspended 映射（detach：`nc_models.synced=false` + `nc_columns.readonly=false` + 删映射行；main 映射丢失的 sync 整体清除）后** drop 两个映射表的 status 列**。含义：**现行语义 = 映射存在 ⟺ 表存活且 synced；映射不存在 = 普通 detach 表**；转正/detach 逻辑可抄 :38-44 的裸 SQL |
| 关联列 | `v2/nc_076_sync_configs.ts:33-39`（f04 §4 已录） | `nc_models.synced` 布尔 + `nc_columns.readonly` 布尔——Table Sync 守卫链的落点列 |
| migration 注册 | `meta/migrations/XcMigrationSourcev0.ts:68-69/:179-180/:357-360` | 四个 v0 migration 已挂载，fresh install 自动执行 |

（App Sync 的 `nc_sync_configs`/`nc_sync_mappings` 表盘点见 f04-research §4，F09 不触碰，维持 f04 裁定。）

## 5. 上游参照：EE Table Sync 能力边界（从 SDK 类型 + i18n + migration 反推）

### 5.1 SDK `sync/table-sync.ts`（93 行全文类型）

- `TableSyncTrigger`：**Realtime**（"Event-driven, sub-second propagation via BaseModel hooks. Default for new internal syncs"）/ **Manual**（"user explicitly clicks Sync now"）——两档，对应 `FEATURE_TABLE_SYNC`（manual）与 `FEATURE_TABLE_SYNC_AUTO`（realtime）两 flag。
- `TableSyncStatus`：Syncing/Active/**Error（带 last_error）**/**Paused（= freeze）**。
- `TableSyncOnDeleteAction`：Delete（源删→镜像删）/ MarkDeleted（源删→镜像标记）。
- `TableSyncInputMode`：**Browse**（选自己有权限的 base/view）/ **Paste**（贴共享视图 URL）——source_input_mode 建后不可变（TableSyncType 注释 "Immutable post-create"）。
- `TableSyncMappingRole`：**Main**（每 sync 恰一行主映射）/ **LinkedShadow**（链接源表喂目标影子表）/ **Junction**（"custom junction table that backs a custom-link LTAR on the main mirror. Rows keyed by RemoteId pairs (parent+child)"）——**EE 支持 LTAR 关系同步**（主表镜像 + 关联表影子 + junction 三层结构）。
- `TableSyncType`：selected_fields（null=全字段含未来新增列；数组=白名单按 title）、sync_job_id、last_error、last_synced_at、deleted（软删=trash 可恢复）、mappings（API 响应组装非落盘列）。
- `TableSyncMappingType`：**source_uuid + source_password_hash**——paste 模式存的是共享视图 uuid 与密码哈希，即**跨 base（乃至跨 workspace、潜在跨实例 pull）同步不要求源 base 的协作者权限，只要求共享视图开启 allow_sync**；browse 模式存 source_workspace/base/table/view 四 id（走权限内直读）。

### 5.2 同步语义（i18n + 列映射索引 + Jobs 模式反推）

- **schema 同步**：源视图字段筛选（selected_fields）→ 目标镜像表建列（tableCreate synced:true + 列 readonly）；源列类型变更传播（column_mappings 源列索引 + `bypassSyncedFieldGuard`）；源列删除 → 可选连带 drop 目标列（`removeSyncedFieldsDropsColumns` 警告文案）；源视图重绑 → 全量 resync（`sourceViewRebindResync`）。
- **数据同步**：三模式——full-create（首次建镜像）/ full-resync（手动重同步或重绑）/ incremental（增量，增量需源表 UpdatedAt 标记，`syncNoUpdatedAtColumn` 提示；无则每次全量拉）。删除策略二选一（delete/mark_deleted）。
- **realtime**：源 base 数据事件经 BaseModel hooks 亚秒传播（TableSyncTrigger.Realtime 注释 + `affectedIdsBySource` job 参数——批量受影响 id 分发，典型 hook→job 解耦）。
- **冻结/恢复**：freeze = status→paused（暂停触发器，不拆映射）；resume = 回 active。
- **转正/detach**：convert to regular table = `Model.updateSynced(false)` + readonly 列解锁 + 删映射（主表转正连带整个 sync 移除，`tableSyncConvertMainTable` 文案："converting it removes the sync itself. All tables created by the sync are kept as regular, editable tables and stop syncing"）。
- **源表删除**：映射不重绑（`syncSourceTableDeletedDesc`："cannot be re-bound to a different source — delete this sync and recreate"）；main 映射丢失 = 不可修复态（`syncMainMappingMissingDesc`）。
- **系统列**：每张镜像表带 11 个 Remote\*/Sync\* 系统列（SDK `SYNC_SYSTEM_COLUMN_TITLES`，sync/index.ts:40-53，注释明言 "table-sync (and legacy SaaS/Airtable sync) adds to every synced destination table"）——增量比对/删除标记/junction RemoteId 配对都靠它们；UI 侧隐藏（isHiddenCol）+ 审计降噪已接。
- **官方 swagger**：table-sync 端点 **零条**（swagger.json / swagger-v3.json grep 零命中，Python 扫 paths 证实）——EE 的 table sync 走 internal ops 通道（`$api.internal` + ACL 十 op），前端实现自由度大，fork 无契约包袱。

## 6. F04 预埋（SyncConfig 面）在 F09 范围内的激活裁定

| F04 保留预埋 | Table Sync 路径 | Custom Sync 路径 | 裁定 |
|---|---|---|---|
| `nc_sync_configs`/`nc_sync_mappings` 表（nc_076/nc_080） | **不消费**（Table Sync 用 nc_table_syncs 三表，两套表零外键交集） | 唯一消费方 | **维持休眠**；Custom Sync 裁则永久休眠（表留着无害，migration 已跑） |
| SDK `sync/index.ts` SyncConfig/TARGET_TABLES/SyncCategory | 不消费 | 消费 | 同上 |
| `utils/syncUtils.ts` 向导 helpers（SyncFormStep/defaultSyncConfig/IntegrationConfig） | 不消费（Table Sync 向导自建，i18n 文案走 labels.\* 那套） | 消费 | Table Sync 向导**不复用**这四个 helper（它们绑定 sync_category/integration 概念）；`isSyncSystemColumnTitle`/`getSyncFrequency` 可复用 |
| `store/sync.ts` + `isSyncFeatureEnabled` | 不消费 | 消费 | **勿动**（f04 纪律维持：翻了会暴露无后端的 integration UI） |
| `appSync*` op-names / `SyncDataSyncModuleJobData` / `syncConfigNotFound` | 不消费 | 消费 | 休眠 |
| integrations `SyncIntegration` 抽象框架 | 不消费 | 引擎骨架 | 休眠 |

**结论：F09（Table Sync）与 F04 预埋零耦合，无需激活任何 SyncConfig 件；「Custom Sync = FEATURE_CUSTOM_SYNC」是唯一会触碰预埋的分支，见 §8 裁定（建议裁）。**

## 7. 工作量分解（四阶段，相对刻度：F04≈F01=小 / F02=中 / F08=中+ / F03=大）

### P1 — Table Sync 手动同步最小闭环（≈ F07×1.5，中量级）

- 后端：
  - `models/TableSync.ts`（~150 行：get/list/insert/update/softDelete + mappings 组装，照 SyncSource.ts:9-169 模式）
  - `services/table-syncs.service.ts`（~350 行：list/get/sourceSchema（源视图列清单，browse 模式走权限校验）/create（resolve 源 + 建映射 + 触发首次 full-create）/update（title/selected_fields/on_delete_action）/delete（软删）/resync（投 job）/freeze/resume）
  - `controllers/table-syncs.controller.ts`（十 op 的 REST 面挂 `/api/v2/meta/bases/:baseId/table-syncs[/:tableSyncId]` 十端点 + `@Acl` 十 op + extract-ids 补 `:tableSyncId` 解析，照 sync.controller.ts:25-93 模式）+ `noco.module.ts` 注册
  - job：`modules/jobs/jobs/table-sync/table-sync.controller.ts`（trigger 入口，@Acl('tableSyncResync')）+ `processor.ts`——**引擎核心**：full-create = 读源视图数据（BaseModelSqlv2 直查）→ tableCreate(synced:true) → bulkInsert(allowSystemColumn:true) 写 11 系统列；full-resync = RemoteId 差异比对 upsert + on_delete_action 处理。manual 档（无 realtime/incremental）先交付
  - 范围收窄：P1 selected_fields **拒收 LTAR 列**（junction/shadow 三层结构推 P4，400 报错文案现成 `removeSyncedLinkFieldDropsJunctionShadow` 可改造）
- 前端：
  - 解 gate：`useEeConfig.ts:160` blockTableSync→false（照 :158 F04 模式）+ `Overview.vue:134` showEEFeatures→`!blockTableSync` + `Node.vue:855` 去 `isEeUI &&`
  - **创建向导对话框**（~400 行新组件：选档只留 NocoDB Sync → browse 模式选 base/view（paste 模式推 P3）→ 字段筛选 → 同步方式只留 Manual → 删除策略 → create；调 `$api.internal` tableSyncSourceSchema/tableSyncCreate）——`CreateNewSync.vue` 空壳改造
  - `SyncMenuOptions.vue` 实装（Sync now/Pause/Resume/Edit/Delete，调 internal ops）+ `SyncStatusBadge.vue` 扩 status
- i18n：零新增（§2.4 全备）；测试：e2e 直调 internal ops 十端点 + ACL 断言（creator 200/editor 部分拒绝）+ 全量同步数据核对 + synced 表只读守卫链断言（insert 400/建 form 400/删表 400）。
- **交付即可 pass 的理由**：管理对象真实（同实例 base 间镜像）、守卫链/审计/UI 只读层全部自动生效、i18n 零补。

### P2 — 生命周期完备（≈ F02 级中件，可与 P1 合并过一轮会审）

- 转正（convert to regular table = detach：`Model.updateSynced(false)` + readonly 解锁 + 删映射，抄 nc_202606121400:38-44 SQL）+ 软删进 trash + `syncSourceTableDeleted`/`syncMainMappingMissing` 异常态 UI。
- selected_fields 变更传播（加字段→补建列；减字段→`removeSyncedFieldsDropsColumns` 确认后 drop）。
- 源列类型变更传播（column_mappings + `bypassSyncedFieldGuard` 路径）。
- paste 模式（source_uuid + 密码，resolve 走 public-metas.controller.ts:12-24 现成端点 + tableSyncResolveLink op）。

### P3 — incremental / realtime（`FEATURE_TABLE_SYNC_AUTO`，≈ F03 级大件）

- incremental：RemoteUpdatedAt 增量拉 + `syncNoUpdatedAtColumn` 引导；realtime：源 base hooks → `TableSyncRun` job（affectedIdsBySource 批发）——涉及 BaseModelSqlv2 hook 链路，冲突/顺序/风暴问题都要处理。
- 解 `useEeConfig.ts:162` blockTableSyncAuto + 向导 Automatically 档。
- **此阶段才开始触碰「自动同步」语义，此前 fork 交付的 sync 都是手动档，预算不足可整段裁**（manual 档自洽可用）。

### P4 — LTAR 关系同步（Main/LinkedShadow/Junction 三层，≈ F03 级大件，独立可裁）

- junction 表 RemoteId 配对写入、shadow 表维护、`removeSyncedLinkFieldDropsJunctionShadow` 级联——SDK 类型齐但链路复杂，对镜像可用性非必须（P1 拒收 LTAR 后功能仍完整）。

### Custom Sync（FEATURE_CUSTOM_SYNC）——建议整段裁（见 §8）

- 若做 = 连接器（≥1 个真实源）+ SyncConfig 引擎（SyncDataSyncModuleJobData 消费者）+ 向导（syncUtils/store/IntegrationsPanel 实装）三层，任一层 ≈ P1 全量；三层合计 > F02+F03 之和。可行源类型评估：PostgreSQL/MySQL（knex 原生 dialect，CE 依赖已有）走 CustomSyncSchema 自定义路径最现实；SaaS 垂类（TARGET_TABLES 那套）需逐家写 API 适配，性价比更低。

## 8. 范围裁定建议

**做（建议 F09 = Table Sync，分阶段交付）**：

1. **P1 必做**：Table Sync manual 档最小闭环（browse 模式、非 LTAR 字段、full-create + sync now 手动重同步、freeze/resume/delete 面板管理）。解 blockTableSync gate + 三入口（Overview 创建 / Node 菜单 / SharePage 源开关）。**P1 过会审闭环即记 pass**。
2. **P2 建议做**：转正/detach、软删、字段变更传播、paste 模式——把「管理同步」做完整（F04 的功能表名义）。
3. **P3/P4 按预算**：realtime/incremental 与 LTAR 关系同步各自独立、独立裁；预算不足时记 fork 限制（「Table Sync manual 档」），不阻塞 pass。
4. F04 预埋（SyncConfig 面）**全部维持休眠**（§6），Custom Sync 裁则无需任何清理动作。

**裁掉（记 fork 限制 / backlog）**：

- **Custom Sync / App Sync（FEATURE_CUSTOM_SYNC）整段**：连接器零存在 + 引擎零存在 + SaaS 垂类 schema 与自建源不匹配；与 F04 裁 App Sync、F06 裁 Docs 本体同构裁定——面板做出来无真实数据通路。若用户未来点名要，从 P1 引擎复用起步（SyncRecord 系统列体系两边同构），按 §7 Custom Sync 三层估重立预算。
- **跨实例 pull 同步**：source_password_hash 设计支持跨实例，但 fork 无远端实例调度面，paste 模式仅限同实例内共享视图。
- **同步快照/历史**：无 sync logs 表（Table Sync 无日志表，仅 last_error/last_synced_at 字段），EE 亦然，不裁不缺。

**功能表建议**：F09 拆两行记账——「F09a Table Sync（manual 档）」P1 交付后可 pass；「F09b Custom Sync」记 fork 限制（连接器生态缺失）。总可达口径不变（F09 完成后 9/10 或 10/10 视 P3/P4 是否计入 pass 标准）。

---

## 附：本次调研未动源码，全部结论的 file:line 均已实测复核（grep/sed/python swagger 扫描，2026-09-17）

---

## 范围裁定（2026-09-17 03:5x，主会话依研究推荐采纳；分阶段可逆）

**裁定：F09 = P1（Table Sync manual 档最小闭环）为交付范围；P2/P3/P4 记分阶段 backlog；Custom Sync 整段裁记 fork 限制。**

- 依据：Table Sync 数据通路在 fork 内真实存在（下游全通），P1 交付即达 pass 标准；Custom Sync 与 F04 App Sync 同构（抽象框架零实现零连接器）
- F04 保留的 SyncConfig 预埋维持休眠（与 Table Sync 零耦合），F09 不激活
- 可逆性：P2/P3/P4 按本报告分阶段估算随时可追加预算重启

---

## 范围裁定（2026-09-17 03:5x，主会话依研究推荐采纳；分阶段可逆）

**裁定：F09 = P1（Table Sync manual 档最小闭环）为交付范围；P2/P3/P4 记分阶段 backlog；Custom Sync 整段裁记 fork 限制。**

- 依据：Table Sync 数据通路在 fork 内真实存在（下游全通），P1 交付即达 pass 标准；Custom Sync 与 F04 App Sync 同构（抽象框架零实现零连接器）
- F04 保留的 SyncConfig 预埋维持休眠（与 Table Sync 零耦合），F09 不激活
- 可逆性：P2/P3/P4 按本报告分阶段估算随时可追加预算重启
