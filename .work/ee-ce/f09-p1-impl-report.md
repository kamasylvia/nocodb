# F09 P1 实现报告 — Table Sync manual 最小闭环

> 实现：F09 P1（Table Sync，browse 模式 + manual 触发 + full-create/full-resync + freeze/resume/delete）。
> 自测：后端 tsc exit 0；jest 41/41（26 基线 + 15 新增）；独立实例 :8081 跑 `f09-p1-selftest.sh` 全流程 **ALL PASS**；UI 三入口 camoufox（session f09impl）截图验证。
> 日期：2026-09-17

---

## 1. 实现清单（file:line）

### 后端（packages/nocodb）

| 文件 | 内容 |
|---|---|
| `src/models/TableSync.ts`（新，~310 行） | nc_table_syncs 三表 model：get/getAny/list/insert/update/delete + listMappings/getMainMapping/listColumnMappings/insertColumnMappings/deleteColumnMappings + toType()。照 SyncSource.ts 模式。 |
| `src/services/table-syncs.service.ts`（新，~560 行） | 十 op service：listSyncs/getSync/sourceSchema/createSync/updateSync/deleteSync/resync/freeze/resume/resolveLink(501)。含源 base 读权限校验（BaseUser.get 三路角色）、allow_sync 强制、镜像列过滤（`isMirrorableSourceColumn`：排 virtual/pk/system/attachment/deleted）、保留名冲突守卫（table system cols + RemoteId/RemoteDeleted）、mirror 表 title 唯一化、synced:true 建表、main mapping + 列 mapping（title 匹配）、job 投递。 |
| `src/controllers/table-syncs.controller.ts`（新） | REST 十端点，全挂 `:baseId`（extract-ids 免改），@Acl 用已注册十 op（creator+ 语义来自 exclude 模型，acl.ts 零改动）。 |
| `src/modules/jobs/jobs/table-sync/table-sync.processor.ts`（新，引擎核心） | full-create/full-resync 统一走 RemoteId 键控 upsert：分页读源（500/页，ignoreViewFilterAndSort+ignoreRls）→ 对照 dest 现有行（RemoteId map）→ bulkInsert（新）/bulkUpdate（已存在，全字段刷新）→ 消失行按 on_delete_action 处理（delete→bulkDelete / mark_deleted→RemoteDeleted=true）。**写入通道 = allowSystemColumn+skipPermissionCheck+skipAttachmentOwnershipCheck（仅引擎内部，HTTP 不可达）**。失败落 status=error+last_error，成功落 active+last_synced_at。运行统计日志（source rows/inserts/updates）。 |
| `src/modules/noco.module.ts` | +TableSyncsController / +TableSyncsService |
| `src/modules/jobs/jobs.module.ts` | +TableSyncProcessor provider |
| `src/modules/jobs/jobs-map.service.ts` | JobTypes.TableSyncRun → TableSyncProcessor.job |

关键机制决策（对照研究 §5 上游语义）：

- **镜像表创建走 `tablesService.tableCreate(synced: true)`**（`tables.service.ts:884` 原生口）→ `nc_models.synced=true` → 六层只读守卫链 + 前端 31 文件只读 UI 层零改动自动生效。
- **系统列**：每张镜像表带 `RemoteId`（源行主键值）+ `RemoteDeleted`（mark_deleted 策略落点），readonly:true，UI 经 `isHiddenCol`（SYNC_SYSTEM_COLUMN_TITLES）隐藏。P1 不建全 11 列（其余为 incremental/custom-sync 预留）。
- **列映射按 id 存**（nc_table_sync_column_mappings），运行时按 id 解析当前 title——源列改名不影响 P1 引擎（改名传播本身是 P2）。
- **sync_trigger 仅收 manual**：`realtime` 在 service 层 400 拒绝（FEATURE_TABLE_SYNC_AUTO 保持付费锁，API 不可绕过 UI gate）。
- **updateSync 拒收 selected_fields 变更**（需列传播，P2），title/on_delete_action 可改。
- **deleteSync** = `tablesService.tableDelete(forceDeleteSyncs: true)`（镜像表进 trash，平台统一语义）+ 删三表登记行。
- **软删行不镜像**：源 list 自带 soft-delete filter；`__nc_deleted`（uidt Deleted）列排除。

### 前端（packages/nc-gui）

| 文件 | 改动 |
|---|---|
| `composables/useEeConfig.ts:163` | `blockTableSync = false`（照 F04/F07 模式）；`blockTableSyncAuto`/`blockCustomSync` 保持 true |
| `composables/useTableSync.ts`（新） | 表级 sync 记录读取 + syncNow/freeze/resume/remove 封装 |
| `components/project/Overview.vue:134` | `ProjectActionCreateNewSync` 入口 `showEEFeatures` → `!blockTableSync` |
| `components/project/Action/CreateNewSync.vue`（重写，9 行 stub → ~300 行向导） | 三步向导：选 source base/table（browse）→ 选 allow_sync 视图 + 字段筛选（all/specific）→ 标题/删除策略 → createSyncTable。调 `/api/v2/meta/bases/:id/table-syncs{,/source-schema}` REST。 |
| `components/dashboard/TreeView/Table/Node.vue:855` | `isEeUI && table.synced` → `table.synced`（引擎态即 gate） |
| `components/dashboard/TreeView/Table/SyncMenuOptions.vue`（重写 stub） | 状态行 + Sync now / Pause sync / Resume sync / Delete sync（确认弹窗）+ 删除后刷新树 |
| `components/dashboard/TreeView/Table/SyncStatusBadge.vue`（扩展） | tree tooltip 增加动态状态行（Syncing/Paused/Error/Last synced/Not yet run） |
| `components/dlg/share-and-collaborate/SharePage.vue:708` | allow_sync 区块 `showEEFeatures` → `!blockTableSync`；移除 PaymentUpgradeBadgeProvider 付费锁壳，开关直通 `toggleAllowSync()` |

### i18n

零新增——en.json / zh-Hans.json 上游预埋文案全备（labels.tableSync/syncNow/freezeSync/resumeSync/deleteSync/lastSynced/syncing/paused/errored/syncNotYetRun/recordsDeletedInSourceWillBe/deletedInMirroredTable/retainedInMirroredTable/createSyncTable/sourceModeBrowse*/fieldsToSync 等 26 键逐一核实双语存在）。

## 2. 自测结果

### 2.1 静态/单测

- `cd packages/nocodb && npx tsc --noEmit` → **exit 0**
- `pnpm test` → **41/41 passed**（3 suites：26 基线不回归 + 15 新增 `src/services/table-syncs.Fork.spec.ts`）
- 新增 spec 覆盖：ACL 十 op 注册 + creator+/editor- 语义断言、镜像列过滤、service 状态机（resync/freeze/resume/updateSync 边界）、引擎 full-create/resync/mark_deleted/失败落账/paused 跳过、realtime 触发 API 拒绝。

### 2.2 引擎实跑（:8081 独立实例，nocodb-dev，:8080 未动）

方法：主会话 ：8080 禁止重启 → rspack 构建 dist → `PORT=8081 node dist/main.js` 独立实例（同 nocodb-dev 库），跑 `.work/ee-ce/f09-p1-selftest.sh`（curl 全流程）→ **ALL PASS**。引擎日志证据：

```
Table sync tsskv3q8a2dcecogl: source rows=3 existing=0 inserts=3 updates=0   ← full-create
Table sync tsst7fy52abc837l3: source rows=3 existing=0 inserts=3 updates=0   ← 第二次 full-create
Table sync tsst7fy52abc837l3: source rows=4 existing=3 inserts=1 updates=3   ← resync（源 +1 行后）
```

两次 base 间真实镜像对照（步骤 8 输出，源 3 行 {row1,row2,row3}×{Title,Qty}）：

| 源表（f09_src_tbl_*） | 镜像表（dest base 内 synced:true） |
|---|---|
| Title=row1 Qty=1 | Id=1 Title=row1 Qty=1 RemoteId="1" RemoteDeleted=false |
| row2/2 | Id=2 row2/2 RemoteId="2" |
| row3/3 | Id=3 row3/3 RemoteId="3" |

resync 后 4 行（新增 row4 经 RemoteId upsert 进镜像）；守卫链实测：对 synced 表 insert → **400**、delete table → **400**；freeze 后 resync → 400；resume → active；delete sync → GET 404（镜像表进 trash）。完整输出见 `.work/ee-ce/logs/f09-8081.log` + selftest stdout。

### 2.3 UI（camoufox session `f09impl`，:3000 Nuxt dev HMR，截图在 `.work/ee-ce/f09-p1-shots/`）

| 截图 | 验证点 |
|---|---|
| 02-base.png | base Overview **"NocoDB Sync" 卡片渲染**（gate 解锁生效；副文案 Mirror a shared view…） |
| 03-wizard.png | **创建向导打开**：Browse 档 + base 选择器 |
| 06/07-*.png | Share 弹窗公开视图后 **"Allow sync" 区块渲染（无 paywall badge）且开关 ON 持久化**（viewUpdate → allow_sync 通道，旧后端亦通） |

注：:3000 dev 固定打 `http://localhost:8080`（`lib/constants.ts:46` BASE_FALLBACK_URL），故「选表→schema→创建」后半段与 synced 表树菜单/徽标无法在当前 :3000 会话端到端（需 :8080 轮转到含 F09 的构建），见 §4。

## 3. 已知限制（P1 范围内）

1. **resync 对已存在行做全字段盲刷**（updates=N），非逐字段 diff——LastModifiedTime/UpdatedAt 每轮刷新；skip_hooks: true 故无 webhook 风暴。
2. **附件列不镜像**（uidt Attachment 排除）：bulkUpdate 通道无 attachment-ownership bypass，跨 base 附件引用会触发所有权守卫；EE 支持该场景，P2 评估引入 raw 通道。
3. **源表 CreatedTime/LastModifiedTime/CreatedBy/LastModifiedBy/Order 值不镜像**（镜像表自建系统列，时间为引擎写入时刻）；RemoteCreatedAt/RemoteUpdatedAt 系统列（增量比对用）P1 未建。
4. **保留名守卫**：源表存在名为 Id/CreatedAt/UpdatedAt/nc_*/RemoteId/RemoteDeleted（title 或 column_name 命中）的可镜像列时拒绝创建（tableCreate 系统列改名会破坏 title 建映射）；遇到即 400 提示。
5. **引擎读源 ignoreRls: true**：job 上下文无用户会话，RLS 条件不适用；读权限已在 create/sourceSchema 时校验。
6. **无列变更传播/源列改名检测**（P2）；**无 paste 模式/resolve-link（501）**（P2）；**无 realtime/incremental**（P3）；**无 LTAR/junction**（P4，LTAR 列被过滤不可选）。
7. **selected_fields 变更 API 拒收**（400，P2 传播就绪后放开）。
8. 引擎无分布式锁：同一 sync 并发 resync 由 API 层 status=syncing 互斥兜底（单实例语义）。

## 4. 需主会话补验（:8080 轮转后）

:8080 当前跑的是旧构建（pid 64572，`~/.nocodb-run` 副本），**已构建好的 dist/main.js（含 F09）在仓内 `packages/nocodb/dist/main.js`**。轮转（dev-backend.sh stop && start）后建议按序验证：

1. `BASE_URL=http://127.0.0.1:8080 zsh .work/ee-ce/f09-p1-selftest.sh`（脚本已支持 BASE_URL 覆盖；需 jq；账号 f01e2e@ce-ee.local 已是 org-level-creator）
2. :3000 上全 UI 流程：Overview「NocoDB Sync」卡 → 向导选 base/table → schema 预检 → 字段筛选 → 创建 → 树上出现 synced 表（图标/只读态）→ 表节点菜单（Sync now/Pause/Resume/Delete）→ tooltip 徽标状态行 → Share 弹窗 allow_sync
3. 编辑者角色访问管理 op 应 403（ACL creator+；jest 已断言权限表语义，HTTP 层未测）

## 5. 环境留痕

- 自测期曾短暂运行 :8081 实例（自起自停，已全部清理，:8081 空闲）；**:8080（pid 64572）与 :3000 全程未动**。
- 构建产物 `packages/nocodb/dist/main.js` 已被 F09 构建覆盖（rspack dev build，与 dev-backend.sh 同款配置）；旧进程内存态不受影响，轮转后自然加载新构建。
- dev DB nocodb-dev 中遗留：自测 base 已被脚本 cleanup 删除（trap）；`f09_ui_check` base（ppsgqkjmx5buw6p，含 ui_src 表 + 已开 allow_sync 的公开视图）**有意保留**供轮转后 UI 验证用，可随时删。
- 截图：`.work/ee-ce/f09-p1-shots/01-07*.png`；自测脚本：`.work/ee-ce/f09-p1-selftest.sh`（凭证零落盘，Infisical 运行时拉取，用后即删）。
