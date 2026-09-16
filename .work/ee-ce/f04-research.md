# F04 Manage Syncs 调研报告（只读调研，2026-09-16）

> flag：`FEATURE_SYNC`（sdk `payment/index.ts:100` = `'feature_sync'`；官方文案 `payment/index.ts:511` = **"to use App Sync."**）。
> 范围 = base 级「管理已有 sync」：列表 / 编辑 / 删除 / 手动重同步。
>
> **核心结论**：
> 1. **仓内存在三个「sync」概念，F04 实现对象必须先裁定**：
>    - **legacy SyncSource（Airtable sync）**——CE 后端 **100% 完整可用**（model/service/controller/Airtable 引擎/internal ops/SyncLogs 全通），唯一缺的是 UI 管理面板（stub）+ gate。**这是 F04 唯一能在 fork 预算内做出真数据的路径**。
>    - **App Sync（SyncConfig + integration 连接器）**——EE `FEATURE_SYNC` 的本体。后端 **零实现**（无 model/controller/service/job，仅 DB 表 + SDK 类型 + op-names 枚举残留）；前端 store 纯 stub + `utils/syncUtils.ts` helper 预埋。做它 = 自建整个同步引擎，不合 F04 预算。
>    - **Table Sync（tableSync\*，base 内表对表同步）**——F09 范畴（`FEATURE_TABLE_SYNC`/`FEATURE_CUSTOM_SYNC`），F04 不动。
> 2. **前端 gate 双锁**：`useEeConfig.ts:156 blockSync=true` + 入口处 `showEEFeatures`（恒 false）/`isEeUI`（恒 false）叠加。解法照 F07 Snapshots 先例（flag+role 化，去 isEeUI/showEEFeatures）。
> 3. **后端零改动**：legacy sync CRUD 四端点在 CE 无 paywall——`@Acl('syncSourceList'...)` 四 op 未注册进 permissionScopes，creator/owner（exclude 模型）天然放行、editor/viewer（include 模型）天然拒绝（F05 同款语义，勿显式注册）。
> 4. F04 工作量 ≈ **F01 级**（解 gate + 实装 1 个前端面板组件 + i18n + e2e），远小于 F02/F03/F07。

---

## 1. EE gating 面（FEATURE_SYNC / blockSync 全部引用点）

| 位置 | 内容 | 现状 |
|---|---|---|
| `packages/nocodb-sdk/src/lib/payment/index.ts:100` | `FEATURE_SYNC = 'feature_sync'` | 枚举定义 |
| `payment/index.ts:104` | `FEATURE_SYNC_15_MIN`（15 分钟同步粒度，独立付费点） | 不做 |
| `payment/index.ts:511` | `'to use App Sync.'` | **官方语义：FEATURE_SYNC = App Sync** |
| `packages/nc-gui/components/project/View.vue:575` | `<LazyPaymentUpgradeBadge :feature="PlanFeatureTypes.FEATURE_SYNC">`（syncs tab 内） | 付费锁 badge，解 gate 后去/改 |
| `packages/nc-gui/components/dashboard/TreeView/Project/BaseSettingsMenu.vue:180` | 同款 badge（base settings 菜单项） | 同上 |
| `packages/nc-gui/composables/useEeConfig.ts:156` | `blockSync = computed(() => true)` | **F04 主解封点** |
| `useEeConfig.ts:323` | `showUpgradeToUseSync = no-op` | 解封回调 no-op，不挡（navigateToBaseSettings:48 与 View.vue:130 两处调用点均自然通过） |
| `useEeConfig.ts:158/160/162` | `blockTableSync / blockTableSyncAuto / blockCustomSync = true` | **F09 的 gate，全仓无消费者，F04 勿动** |
| `useEeConfig.ts:387` | `showEEFeatures = computed(() => false)` | 恒 false，syncs 入口的第二把锁 |
| `packages/nc-gui/utils/ncUtils.ts:1` | `isEeUI = false` | 编译期常量，勿翻（View.vue:173 消费） |

后端 `packages/nocodb/src` **零处**引用 FEATURE_SYNC / blockSync——paywall 完全在前端。

## 2. 前端 stub 面

### 2.1 stub UI 本体

- `packages/nc-gui/components/project/Sync/index.vue`（全文 9 行）：`defineProps<{baseId?}>` + `<NcSpanHidden />`——**F04 前端主体工作 = 实装此组件**。

### 2.2 入口一：base settings 页 tab（`project/View.vue`）

- `View.vue:569` tab-pane：`v-if="isUIAllowed('sourceCreate') && base.id && !isMobileMode && showEEFeatures"`——showEEFeatures 恒 false → tab 永不渲染。
- `View.vue:581` 内容区：`<ProjectSync v-if="!blockSync" :base-id="base.id">`——blockSync 解 false 后自动挂载。
- `View.vue:130`（computed set）：`value==='syncs' && showEEFeatures.value && showUpgradeToUseSync(...)` → showEEFeatures=false 短路，**天然不挡，无需改**。
- `View.vue:173`（watch route.query.page）：`if (isEeUI && newVal === 'syncs' && !blockSync.value)` → **isEeUI 恒 false 使 `?page=syncs` 查询路径死路，必改**。
- F07 先例模板：`View.vue:643` snapshots tab `v-if="!blockSnapshots && isUIAllowed('baseSnapshotList') && base.id && !isMobileMode"`——flag+role 化、无 isEeUI/showEEFeatures/badge。

### 2.3 入口二：base settings 侧栏菜单（`BaseSettingsMenu.vue`）

- `BaseSettingsMenu.vue:173-183` 菜单项：`v-if="isEeUI && isUIAllowed('sourceCreate', {roles: effectiveRoles}) && !isMobileMode && showEEFeatures"` → 双锁齐活，永不渲染。
- `BaseSettingsMenu.vue:48` 导航 gate：`page==='syncs' && showUpgradeToUseSync(...)` → no-op，不挡。
- F07 先例模板：`BaseSettingsMenu.vue:261-265` snapshots 项 `v-if="!blockSnapshots && isUIAllowed('baseSnapshotList', {roles: effectiveRoles}) && !isMobileMode"`（badge 保留 + `:feature-enabled-callback="() => !isEEFeatureBlocked"`，:274-276）。

### 2.4 路由链

- `pages/index/[typeOrId]/[baseId]/index/settings/[page].vue:4`：`baseSettingsSlugToTab[route.params.page]` → `ProjectView :tab="tab"`。
- `utils/settingsRouteUtils.ts:15`：`'syncs': 'syncs'`（slug 映射已备）。
- `View.vue:281-289`：watch `props.tab` immediate 直接赋 `projectPageTab`（绕过 set 的 upgrade gate，安全）。

### 2.5 store / helper / api

- `packages/nc-gui/store/sync.ts`（全文 79 行，**纯 stub**）：`loadSyncs/readSync/createSync/updateSync/triggerSync` 全返回 `[]/null`；`isSyncFeatureEnabled = ref(false)`（:19，无任何赋 true 路径）；:3 注释掉的 `ProjectSyncCreate, ProjectSyncProgressModal` import——**这两个组件在仓内不存在**（EE 专有，未随 CE 发布）。
- `isSyncFeatureEnabled` 的三个消费组件（均为 App Sync/integration 面，F04 **不要**翻 true，否则暴露无后端的 App Sync UI）：`components/workspace/integrations/IntegrationsTab.vue:43`、`AddConnectionDropdown.vue:19`、`components/dashboard/settings/base/Integrations.vue:41`。
- `packages/nc-gui/utils/syncUtils.ts`（132 行，**完整预埋**，为 App Sync 向导服务）：`SyncFormStep`（4 步）、`defaultSyncConfig`、`syncEntityToReadableMap`、`isSyncSystemColumnTitle` 等——F04 用不到（属 SyncConfig 面），保留不动。
- **SDK 无 syncs 端点封装**：生成的 `nocodb-sdk/src/lib/Api.ts` 无 `syncSource*` / `/syncs` 方法。前端调 legacy sync 一律走 `$api.internal.getOperation/postOperation`（`AirtableImport.vue:143-265` 是完整先例：syncSourceUpdate:147 / syncSourceCreate:157 / syncSourceList:219 / atImportTrigger:263）。
- SDK 类型（App Sync 面，F04 不消费）：`nocodb-sdk/src/lib/sync/index.ts`（SyncConfig/SyncCategory/TARGET_TABLES 全备）+ `sync/table-sync.ts`（TableSyncType，F09）。
- 前端 ACL：`packages/nc-gui/lib/acl.ts:121` `sourceCreate: true`（creator 段）+ `:104 airtableImport: true`——入口 role 门已备。

### 2.6 i18n

- `lang/en.json:2740` `"manageSyncs": "Manage Syncs"`、`lang/zh-Hans.json:2083` `"manageSyncs": "管理同步"`——入口文案已备；面板内部新键需补 en+zh。

## 3. 后端面

### 3.1 legacy SyncSource（CE 完整，F04 直接消费）

| 层 | 位置 | 内容 |
|---|---|---|
| model | `packages/nocodb/src/models/SyncSource.ts:9-169` | get/list/insert/update/delete/deleteByUserId 全实装（details JSON 解析、extractProps 白名单） |
| service | `services/sync.service.ts:13-97` | syncSourceList（PagedResponse）/syncCreate（默认挂 `base.sources[0]`，AppEvents.SYNC_SOURCE_CREATE）/syncDelete/syncUpdate |
| controller | `controllers/sync.controller.ts:25-93` | GET+POST `/api/v1/db/meta/projects/:baseId/syncs[/:sourceId]` 与 `/api/v2/meta/bases/:baseId/syncs[/:sourceId]`；DELETE+PATCH `/api/v1|v2/meta/syncs/:syncId`；`@Acl('syncSourceList'/'syncSourceCreate'/'syncSourceDelete'/'syncSourceUpdate')` |
| 注册 | `modules/noco.module.ts:72,250` | SyncController 已挂 |
| internal ops | `controllers/internal/modules/UiGet.operations.ts:72,258`（syncSourceList）、`UiPost.operations.ts:147,150,711,730`（syncSourceCreate/syncSourceUpdate/syncSourceDelete/atImportTrigger） | `operationScopes.ts:145-149` 五 op 全部 base scope |
| Airtable 引擎 | `modules/jobs/jobs/at-import/`（716K：controller/processor/engine/helpers） | `at-import.controller.ts:27-31` `@Acl('airtableImport')` triggerSync + job 去重（同 syncId 在跑报 "Sync already in progress"） |
| SyncLogs | `models/SyncLogs.ts`（list/insert/deleteByBaseId 完整） | **无读取端点**（写由 at-import processor 完成，读未暴露） |
| extract-ids | `middlewares/extract-ids/extract-ids.middleware.ts:467-476,864-871` | `:syncId` 参数 → SyncSource.get 解析 `req.ncBaseId/ncSourceId`（DELETE/PATCH /meta/syncs/:syncId 路径通） |
| 级联清理 | `models/Source.ts:580-587`（删 source 级联删 syncSources）、`services/org-users.service.ts:182`（删用户清理） | 已备 |

**ACL 语义（关键）**：`syncSourceList/Create/Update/Delete` 四 op **不在** `utils/acl.ts` permissionScopes（grep 证实零命中），也不在 nc-gui/lib/acl.ts。判定走 `extract-ids.middleware.ts:1327-1341`：creator/owner 是 exclude 模型（`ProjectRoles.CREATOR: {exclude: {baseDelete, migrateBase}}`，acl.ts:639-649）→ exclude 表无此键 = 放行；editor/viewer 是 include 模型 → 无此键 = 拒绝。**即 sync CRUD 现状就是 creator+ only，与 F05 BaseVariable 同款，无需注册任何 ACL**。`airtableImport` 同理（`View.vue` 弹窗入口 `isUIAllowed('airtableImport')`，前端 acl.ts:104 已显式给 creator）。

### 3.2 App Sync / SyncConfig（EE 本体，CE 零实现）

- 后端全 src grep：**无** SyncConfig model/controller/service；仅残留 `command-registry/op-names.ts:186-192`（appSync* 六枚举）、`interface/Jobs.ts:386`（syncConfigId 接口字段）、`helpers/ncError.ts:259`（syncConfigNotFound helper）、`utils/globals.ts:81`（MetaTable.SYNC_CONFIGS）与 `:573`（缓存键 'syncConfigs'）。
- op-names.ts:173 明确注释 `// Sync (legacy SyncSource)` 与 `// App Sync (integration-based SyncConfig)` 分列——上游自己也把两者分得很清。

### 3.3 Table Sync（F09，仅划界）

- `utils/acl.ts:322-326`（permissionScopes）+ `:1088-1097`（descriptions）：tableSyncList/Get/SourceSchema/Create/Update/Delete/Resync/Freeze/Resume/ResolveLink 十 op 已注册；SDK `sync/table-sync.ts` 类型全备——但同样无 controller/service。**F04 不触碰。**

## 4. DB 面（表全部在 CE migrations，零建表工作）

| 表 | migration | 列 |
|---|---|---|
| `nc_sync_source_v2` | `v2/nc_013_sync_source.ts:5-21`（fresh install 走 `v0/nc_001_init.ts`，索引 :2048-2051） | id / title / type / details(text) / deleted / **enabled** / order / project_id / fk_user_id / source_id / base_id / timestamps；索引 base_id+fk_workspace_id、source_id |
| `nc_sync_logs_v2` | `v2/nc_013_sync_source.ts:23-37` + `v2/nc_037_rename_project_and_base.ts:163-167`（fk_sync_base_id→fk_sync_source_id） | id / base_id / fk_sync_source_id / time_taken / status / status_details |
| `nc_sync_configs`（App Sync，暂不用） | `v2/nc_076_sync_configs.ts:5-31` + `v0/nc_001_init.ts:1127-1149`（v0 版含 title/sync_category/fk_parent_sync_config_id/on_delete_action 全列） | id / fk_workspace_id / base_id / fk_integration_id / fk_model_id / sync_type / sync_trigger / sync_trigger_cron / sync_trigger_secret / sync_job_id / last_sync_at / next_sync_at |
| `nc_sync_mappings`（App Sync） | `v2/nc_080_sync_mappings.ts` + v0 init | id / fk_sync_config_id / fk_model_id / target_table |

附带：nc_076 还给 `nc_models` 加 `synced` 布尔列、`nc_columns` 加 `readonly` 列（:33-39）——SDK `ModelType.synced`（Api.ts:7323）即此，F03 已消费过 synced 拒配先例。

## 5. EE 与 CE 的差异面（工作量判断关键）

- **CE 完全可用**：legacy SyncSource 的创建（AirtableImport.vue 向导，入口在新建 base/导入菜单）、数据同步执行（at-import 引擎，job 进度经 `$poller` websocket）、CRUD API、logs 写入。**后端无任何 paywall/feature flag**。
- **CE 唯一缺**：① 入口双锁（§2.2/2.3）；② 管理面板 UI（stub）——即「创建之后的 lifecycle 管理」无 UI。一个 base 经 Airtable 导入后，其 SyncSource 行只能靠 API 裸调管理。
- **CE 完全缺失**：App Sync（SyncConfig）的引擎、端点、创建向导——`store/sync.ts` 与 `syncUtils.ts` 是 EE 为其预埋的空壳。做 App Sync ≈ 重写一个连接器同步系统（integrations core 只有 schema 定义 `packages/noco-integrations/packages/core/src/sync/schema-*.ts`，无执行引擎），不在 F04 预算内，且与 F09 边界纠缠。

**裁定依据**：`FEATURE_SYNC` 官方语义虽是 App Sync，但 fork 里把它实现成「Manage Syncs 管理面板 + legacy Airtable sync 数据源」是唯一有真实数据可管、后端零新增的路径；App Sync 面板即使做出来也永远空态（无创建/执行通道），无产品价值。与 F10 先例（CRUD+骨架，重系统裁）同构。

## 6. 实现方案（最小改动清单，全部 `// [CE-EE] F04`）

后端：**零改动**。（可选加固项，默认不做：syncSource* 四 op 补进 `utils/acl.ts` permissionScopes——**不要做**，注册即要求 role 表同步维护，现语义 creator+ 已正确。）

前端：

- [ ] `packages/nc-gui/composables/useEeConfig.ts:156` — `blockSync` → `false` + 注释（照 :429 blockSnapshots 模式）
- [ ] `packages/nc-gui/components/project/View.vue:569` — tab-pane v-if flag 化：`!blockSync && isUIAllowed('sourceCreate') && base.id && !isMobileMode`（照 :643 snapshots 模式）；:575-579 的 `LazyPaymentUpgradeBadge` 移除或改 `:feature-enabled-callback`
- [ ] `View.vue:173` — 去 `isEeUI &&`：`if (newVal === 'syncs' && !blockSync.value)`（:130 set gate 与 :48 导航 gate 天然不挡，不动）
- [ ] `packages/nc-gui/components/dashboard/TreeView/Project/BaseSettingsMenu.vue:173-183` — v-if flag 化（照 :261-265 snapshots 模式：`!blockSync && isUIAllowed('sourceCreate', {roles: effectiveRoles}) && !isMobileMode`）；badge 改 `:feature-enabled-callback="() => !isEEFeatureBlocked"`
- [ ] `packages/nc-gui/components/project/Sync/index.vue` — **主体工作**：实装管理面板
  - 列表：`$api.internal.getOperation(wsId, baseId, {operation: 'syncSourceList'})`（AirtableImport.vue:218 先例）
  - 每 sync 卡片：title/details 展示与编辑（`syncSourceUpdate`）、删除（`syncSourceDelete`，带确认）、**立即重同步**（`atImportTrigger` + `$poller` 订阅进度，AirtableImport.vue:259-290 先例；在跑时 "Sync already in progress" 400 须捕获提示）
  - 空态：无 sync 时引导文案（指向 Airtable 导入入口）
  - 推荐组件内联自管数据，**不动 `store/sync.ts`**（其 App Sync 面留 stub；`isSyncFeatureEnabled` 保持 false，防暴露无后端的 integration UI——§2.5 三消费组件）
- [ ] i18n：面板新键补 `lang/en.json` + `lang/zh-Hans.json`（入口键 labels.manageSyncs 已有）

测试：

- e2e（`.work/ee-ce/f04-e2e.sh`）：creator 建/列/改/删 SyncSource（直连 `/api/v2/meta/bases/:baseId/syncs`）+ editor 403/creator 200 ACL 断言 + atImportTrigger 对伪 details 的干净报错。**重同步全链路需真实 Airtable 凭证，e2e 只测 CRUD 面与报错路径**（记 fork 限制）。
- 前端 vitest：可选（面板逻辑薄）；后端无改动则无新 Fork.spec。

## 7. 范围裁定建议

**做（fork 最小可用面）**：

1. Manage Syncs 面板 = **legacy SyncSource（Airtable sync）管理**：列表 / 编辑（title/details）/ 删除 / 手动重同步（带进度）。
2. 双入口解 gate（base settings tab + 侧栏菜单），照 F07 flag+role 模式。
3. 空态引导。

**裁掉（记 fork 限制 / backlog）**：

- **App Sync（SyncConfig + integration 连接器同步）**：引擎/端点/向导全部不做；`nc_sync_configs`/`nc_sync_mappings` 表、SDK SyncConfig 类型、`syncUtils.ts`、`store/sync.ts` App Sync 面全部保留原状待 F09 后评估。
- **Table Sync（tableSync\*）** → F09（FEATURE_TABLE_SYNC/CUSTOM_SYNC）。
- **SyncLogs 历史查看 UI**：后端无读取端点（§3.1），做面板须同时加端点+UI；记 backlog（重同步进度经 job websocket 已够用）。
- **FEATURE_SYNC_15_MIN 调度粒度**：at-import 为手动触发型，无 cron 调度器，不做。
- **SyncSource.enabled 列的启停语义**：表有 `enabled` 列（nc_013:12）但 model/service 无消费（update extractProps 含 'deleted' 不含 'enabled'，SyncSource.ts:119-128）——面板只做删/改/重同步，启停记 backlog。

**理由**：后端零改动 + 前端 5 文件（gate 4 处 + 面板 1 个）+ i18n ≈ F01 量级；管理对象有真实数据（Airtable 导入产物）；App Sync 全链路自建引擎成本 > 之前五个 pass 之和且与 F09 边界不清，裁。
