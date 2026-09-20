# F09 P4 实现设计（LTAR 关系同步三层 — 设计先于实现，2026-09-20）

> 状态：**设计定稿**（实现进行中会随批次更新本文）。
> 基线 = F09 P3 pass（45032e45b0）。全部改动带 `// [CE-EE] F09 P4` 标记。

## 0. 范围与简化档声明

- 目标：源表 link 字段（mm 型）不再被 P1 拒收，而是建 **主镜像 link 列 + LinkedShadow 影子表 + Junction 交汇表** 三层，并在 full-create / full-resync（含 catch-up 全量档）全链同步；realtime 对 link 结构变更投**全量 resync**（用户已批的简化档）。
- **简化档 1（link 类型）**：仅支持 `RelationTypes.MANY_TO_MANY`（v2 Links 全走 mm junction）。bt/hm/oo（V1 FK 型）不在 syncable 集合，selected_fields 显式点名时走既有 "Fields cannot be synced (unsupported or unknown)" 400 路径（与 P1 行为一致）。
- **简化档 2（realtime）**：junction 变更（link 加/删）不投增量——引擎在 `BaseModelSqlv2.updateLastModified` 处加 tap（该函数恰好只在 link 结构变更路径被 relation-manager / add-remove-links / nested insert / delete 触发），事件分发给 matched sync 后一律投 `full-resync`（全量档重算 main+shadow+junction，幂等）。scalar 变更仍走 P3 的 after* 增量。
- **简化档 3（link 目标约束）**：related model 必须与源主表同 base、同为普通 table、非自引用；不满足则该 link 列不进 syncable 集合（同 bt/hm 一样走 unknown/unsupported 拒绝）。related model 自身的 link 列不递归镜像（级联止于一跳，沿用 P3 裁定）。
- **简化档 4（link order 不同步）**：v2 junction 的两个 Order 系统列值不镜像（配对本身同步，排序为 fork 限制）。

## 1. 三层结构 schema（dest base 内）

以源主表 T（mirror 表 M）上的 mm link 列 L（related model RT）为例：

| 层 | dest 侧对象 | 建法 | nc_table_sync_mappings 行 |
|---|---|---|---|
| Main | M（P1 既有，synced:true，RemoteId/RemoteDeleted 系统列） | tableCreate(synced:true) | role=main（既有） |
| LinkedShadow | 影子表 S（RT 的标量列镜像 + RemoteId/RemoteDeleted，synced:true，全列 readonly） | tableCreate(synced:true)，复用与主镜像同一套建表/系统列补丁/GVC 隐藏 helper | role=`linked_shadow`，source_workspace/base/table_id=RT 坐标，source_view_id=null，dest_table_id=S |
| Junction | CE 原生 mm junction J（两列复合 pk 的 FK 结构，mm:true；建后 `Model.updateSynced(true)` 翻成 synced 语义） | `columnsService.columnAdd`（uidt 取源列同款 Links/LinkToAnotherRecord，type='mm'，parentId=M，childId=S，title=源列 title，readonly:true）——CE 原生路径自动建 J + 双向 link 列 | role=`junction`，`source_*` 全 null（对齐 SDK 注释），dest_table_id=J |

- link 列对应关系记入 `nc_table_sync_column_mappings`：source_column_id=源 L id → dest_column_id=dest link 列 id，挂 **main mapping** id 下。shadow 的标量列映射挂 **shadow mapping** id 下（fk_table_sync_mapping_id 区分；`TableSync.listColumnMappings` 的 select 扩列：+fk_table_sync_mapping_id、+source_table_id，向后兼容）。
- junction/shadow 同为 synced:true ⇒ 守卫链（HTTP 写 400）与引擎 allowSystemColumn 白名单通道语义自动成立（任务红线 5）。
- dest junction 的配对写入走 knex 直写（`assocBaseModel.execAndParse(dbDriver(vTn)…)`，与 relation-manager 同通道），绕过列白名单但物理表受 synced 守卫保护；引擎写不触发任何 hook（raw knex），无环。
- 同一 RT 被多个 link 列引用 → 共享一个 S，各自独立 J（CE 每列原生独立 junction）。

## 2. 映射行 role 语义（TableSyncMappingRole）

- `main`（既有）：恰一行；realtime tap（insert/update/delete/bulk*）match 后投 **incremental + affectedIds**。
- `linked_shadow`（新消费）：source_table_id=RT ⇒ RT 的 after* tap match 后投 **full-resync**（无 ids，全量档）；RT 的 link 事件（'link' tap）同样投 full-resync。
- `junction`（新消费）：`source_*` null；不参与 tap 匹配（junction 写是 raw knex，本就无 hook）；仅用于 deleteSync/detachSync 资源枚举与 incremental 删除后的 junction 孤儿行清理定位。
- 载荷面：`listSyncs/getSync` 返回 mappings 全量（junction 行 source_* 本就为 null，无凭据泄露面；P2 的 uuid/hash 剥离继续覆盖）。

## 3. selected_fields 含 link 字段的处理流

- **分类**：`isMirrorableSourceColumn`（标量）保持不动；新增 `isSyncLinkColumn(uidt)`（Links/LinkToAnotherRecord）+ `loadSyncableLinks(sourceContext, sourceModel)`（async：逐列 `getColOptions` 过滤——mm 型 + fk_mm_model_id 存在 + RT 同 base/table/非自引用）。
- **available 集合**（createSync 与 updateSync 共用）= 标量 mirrorable ∪ syncable links（按 title）。bt/hm/oo/自引用/跨 base link 不在集合 ⇒ 显式选中即 400（文案沿用 P1）。selectedFields:null ⇒ 全部（含全部 syncable links）。
- **createSync 加腿**：主镜像建表（仅标量列）→ sync + main mapping + 标量列映射 → 逐 link 列：`ensureShadowForRelated`（首个引用时建 S + shadow mapping + shadow 列映射）→ `addMirrorLinkColumn`（columnAdd 建 dest link 列 + CE 原生 junction）→ `Model.updateSynced(J, true)` → junction mapping 行 + link 列映射行。失败清理路径（P2 原子性 catch）扩展：镜像 + 全部影子 + 全部 junction 逐一 tableDelete(forceDeleteSyncs)（best-effort）。
- **updateSync 加/删**：
  - 加腿 = `ensureShadowForRelated` + `addMirrorLinkColumn` + updateSynced(J) + mapping 行（同 create）。
  - 删腿 = `removeSyncedLinkFieldDropsJunctionShadow` 级联：columnDelete(dest link 列， forceDeleteSystem+skipTrash) → tableDelete(J, forceDeleteSyncs) → 删 junction mapping 行 + link 列映射行 → **shadow 引用计数**：剩余 link 列映射解析 related id 集合，RT 不再被引用 ⇒ tableDelete(S) + 删 shadow mapping + shadow 列映射。
- **sourceSchema**：columns 响应附加 link 列（`{id,title,uidt,link:true}`），向导零改动自然可选（UI 按 title 渲染）。

## 4. 引擎（processor）三模式交互

- **full-create / full-resync / catch-up 全量档**（isIncremental=false）：
  1. 主表 pass（P3 既有：RemoteId 键控 upsert + 消失 sweep）不动；`fieldMap` **排除 link 列映射**（link 列是 virtual，不能进 bulkInsert/bulkUpdate 标量载荷）。
  2. 逐 shadowMapping：对 (RT → S) 跑同构 shadow pass（分页拉源 + upsert + sweep，引擎通道），返回 S 的 remoteId→destPk map。
  3. 重扫 M 与各 S 得到最新 remoteId→pk 映射（upsert 后新行 pk 需回读）。
  4. 逐 link 列映射 recompute junction 配对：
     - 源侧：`srcOpt.getMMModel/getMMChildColumn(源主侧)/getMMParentColumn(RT 侧)` 读源 junction 全行 → (parentRemoteId, childRemoteId) 配对集；
     - dest 侧：`destOpt` 同款解析 dest junction 两 FK 列；
     - desired = 源配对中两侧都能映射到 dest pk 的子集（源 junction 悬挂行——meta 源无 FK 级联——自然剔除）；existing = dest junction 全行按 (mainPk, shadowPk) 键控；
     - diff → 缺失批插（chunk 200）、多余逐对删（knex 直写）。
- **incremental（affectedIds 非空，realtime scalar 事件）**：仅主表 pass；新增 **junction 孤儿清理**——pendingDeletes 落地的 dest main pk 集合，对每个 junction mapping 删 `mainSideFk IN (pks)` 的孤儿行（delete 策略；mark_deleted 行保留，配对仍有效）。shadow/junction 重算不做（等 link 事件或 catch-up 全量档）。
- 防环：引擎写全走 skip_hooks:true / synced 守卫 / raw knex（junction），dest 侧永不触发 tap；source tap 仅匹配 mapping source_table_id（main/linked_shadow），junction mapping 无 source id 不匹配。

## 5. realtime tap（简化档落地）

- `BaseModelSqlv2.updateLastModified`（全仓 link 变更唯一汇聚点：relation-manager add/remove、add-remove-links 批量、nested insert/update LTAR、delete 触及链接行）在 `ROW_LMT_TOUCHED` emit 处补 `[CE-EE] F09 P4` tap：`model.synced` 守卫 + try/catch 吞错 + 事件类型 `'link'`（rowIds 携带但不用于增量）。
- `table-sync-realtime.ts`：
  - `TableSyncChangeEvent` 增加 `'link'`；
  - `loadRealtimeTargets` 的 role 过滤 `role IN ('main','linked_shadow')`（带出 role）；junction 行不匹配；
  - 分发决策：`event='link'` 或 `role='linked_shadow'` ⇒ `claimAndEnqueue(target, null, 'full-resync')`；其余维持 incremental+ids。claim/CAS/补齐标记链路（P3）完全复用。
- 已知依赖：无 LastModifiedTime 系统列的表 updateLastModified 早退 ⇒ link 变更不 tap（等手动 resync / catch-up；与 P3 水位依赖同源，记限制）。

## 6. deleteSync / detachSync 级联

- **deleteSync**：mappings 全枚举（main/linked_shadow/junction）逐 dest_table_id `tableDelete(forceDeleteSyncs)`（best-effort try/catch，进 trash 平台语义）→ `TableSync.delete`（三表行级联删）。
- **detachSync**：EE 语义「sync 创建的所有表保留为普通可编辑表」——逐 mapping 对 dest 表 `Model.updateSynced(false)` + 全列 readonly 解除 + COLUMN:list 缓存失效；然后删映射 + sync。M 的 link 列、S、J 全部转普通表且链接关系继续可用（colOptions 保留）。

## 7. 改动文件清单（预计）

| 文件 | 改动 |
|---|---|
| `packages/nocodb/src/services/table-syncs.service.ts` | link 分类/available 集合、createSync 三层、updateSync 加删级联、deleteSync/detachSync 级联、sourceSchema link 列、shadow/junction 建/拆 helpers |
| `packages/nocodb/src/modules/jobs/jobs/table-sync/table-sync.processor.ts` | fieldMap 排除 link、shadow pass、junction recompute、incremental junction 清理 |
| `packages/nocodb/src/helpers/table-sync-realtime.ts` | role 感知分发 + 'link' 事件 + mode 参数 |
| `packages/nocodb/src/db/BaseModelSqlv2.ts` | updateLastModified 单点 tap |
| `packages/nocodb/src/models/TableSync.ts` | listColumnMappings select 扩列（mapping id / source_table_id） |
| `packages/nocodb/src/services/table-syncs.Fork.spec.ts` | P4 用例（shadow pass / junction recompute / link 映射不入标量载荷 / incremental junction 清理） |

前端预计**零改动**（向导按 sourceSchema.columns 渲染自然可选 link 字段；i18n 键 `removeSyncedLinkFieldDropsJunctionShadow` 上游已备，本轮级联为后端行为，UI 确认弹窗留待字段编辑 UI 轮次）。

## 8. 质量门与验证计划

- `npx tsc --noEmit` 0；`npx jest --testPathPattern 'Fork'` 全过（P1–P3 44 用例不回归 + P4 新增）。
- dev server 活体：源 base 建 T1/T2 + mm link → 目标 base 建 sync（含 link 字段）→ 断言 M/S/J 三层 + synced 语义 + 配对数据；resync 后增删 link 配对传播；updateSync 去 link 字段级联删 J/S；deleteSync 清理；守卫链（J/S 直写 400）。
- 回归：无 link 字段的 sync 全链（P3 增量/realtime/补齐语义）不受影响。

## 9. 实现记录（2026-09-20 收官）

**实现链**：单实现批（未爆 error 修复轮）。改动 7 文件 +1717/−139：

| 文件 | 内容 |
|---|---|
| `packages/nocodb/src/services/table-syncs.service.ts` | `isSyncLinkColumnUidt` 分类导出、`loadSyncableLinks`（mm + 同 base + 非自引用过滤）、`insertTableSyncMapping`、`setupMirrorSystemColumns`（P1 内联块抽出，main/shadow 共用）、`ensureShadowForRelated`、`addMirrorLinkColumn`（columnAdd 建 mm link + junction → `Model.updateSynced(junction,true)`）、`dropMirrorLinkColumn`（junction 级联）、`dropShadowForRelated`（引用计数）、createSync 三层构建 + 失败全量清理、updateSync 加/删级联（keptLinkRtIds 引用计数）、deleteSync role 排序级联（junction→shadow→main）、detachSync 三表全部转正、sourceSchema 双分支 link 列（`link:true`） |
| `packages/nocodb/src/modules/jobs/jobs/table-sync/table-sync.processor.ts` | fieldMap 排除 link 映射、linkFieldPairs 提取、`recomputeLinkLayers`（full pass：main remoteToPk 重扫 + shadow pass + junction recompute）、`syncShadowTable`（upsert+sweep 同构 + 返回 post-pass map）、`recomputeJunctionPairs`（源 junction 分页读 → desired/Existing diff → chunk 插 + 逐对删，knex 直写）、`cleanupJunctionOrphans`（incremental 删除后 junction 孤儿清理）、`scanDestRemoteMap` |
| `packages/nocodb/src/helpers/table-sync-realtime.ts` | `'link'` 事件类型、role IN (main, linked_shadow) + role 透出、`claimAndEnqueue` mode 参数（main scalar=incremental+ids；link 事件/shadow=full-resync） |
| `packages/nocodb/src/db/BaseModelSqlv2.ts` | `updateLastModified` 单点 tap（全仓 link 变更汇聚点；synced 守卫 + 吞错） |
| `packages/nocodb/src/models/TableSync.ts` | listColumnMappings select 扩列（+fk_table_sync_mapping_id/source_table_id，向后兼容） |
| `packages/nocodb/src/services/table-syncs.Fork.spec.ts` | 3 个 P4 用例（shadow upsert + junction diff 删/跳过悬挂对 + link 不入标量载荷 / shadow 补齐后 junction 插对 / incremental 删除 junction 孤儿清理），47/47 |
| `.work/ee-ce/dev-backend-internal.sh` | INFISICAL_PROJECT_ID_KDL 缺失时自 `~/.agents/config.toml [infisical]` 补载（2026-09-18 凭证迁移跟随修复） |

**质量门**：`npx tsc --noEmit` exit 0；`npx jest --testPathPattern 'Fork'` **47/47**（P1–P3 44 不回归 + P4 新增 3）；前端零 SFC 改动（向导按 sourceSchema.columns 渲染，link 列自然可选；Vite URL 门无对象）。

**活体验证**（:8080 P4 构建，nocodb-dev，`.work/ee-ce/f09-p4-selftest.sh` **12 步 ALL PASS** + 3 个专项 probe 全过）：

- 三层结构：sync 响应含 main + linked_shadow + junction 三 mapping；junction `source_*=null`；三表 `synced=true`（junction 经 `includeM2M=true` 可见——mm 表默认隐藏是 CE 行为）。
- 配对数据：junction 行两 FK 列 + LTAR 解析正确（`{shadow_fk, main_fk, shadow:{Id,Name}, main:{Id,Title}}`）；mirror link 列在 dest 侧真实可用。
- resync 传播：源加配对 → junction 3；源删配对 → junction 2。
- 守卫链：junction 直写 422（ERR_SYNC_TABLE_OPERATION_PROHIBITED，与 P2 editor 删镜像行同源语义；非 400）。
- removeSyncedLinkFieldDropsJunctionShadow：updateSync 去 link 字段 → junction 表 + shadow 表 + junction/shadow mapping + link 列映射全清，mirror 上 link 列删除。
- deleteSync 级联：三表全走（junction→shadow→main 排序 + best-effort）。
- detach：三表全转普通可编辑（synced=false、readonly 解除），配对保留，镜像可写（EE「sync 创建的表全保留」语义）。
- realtime 简化档：realtime sync 下源侧加配对 → `updateLastModified` tap → full-resync → **~5s 内 junction 配对出现**（无手动 resync）。
- P3 回归：realtime sync 标量插入 → incremental → mirror ~5s 出行（P3 链路无回归）。

**自测脚本 bug 注记（非引擎）**：首轮 junction=0 系自测脚本拿 `POST /columns` 返回的 **Model id** 当 link 列 id（P2 已知 columnAdd 返回刷新后 Model 行为），源配对从未建成功；修正按 title 从 `.columns` 捞列 id 后全链通过。

**遗留风险 / backlog（不阻塞）**：

1. **realtime 全量档风暴**：每次 link 变更投一个 full-resync（已批简化档）；批量 link 操作靠 CAS 去重 + 补齐单跑收敛。
2. **无 LastModifiedTime 系统列的源表**：`updateLastModified` 早退 → link 变更不 tap（与 P3 水位依赖同源），等手动 resync / catch-up。
3. v3 attachment 服务调 `updateLastModified` 会触发 'link' 全量 resync（无正确性影响，频率低）。
4. **shadow 列漂移传播未接**（主镜像有 P2 type-drift，shadow 列类型漂移暂不传播）；**RT 新增列不自动进 shadow**（selected_fields 语义不变）。
5. bt/hm/oo（V1 FK 型）、自引用、跨 base link：不进 syncable 集合，显式选中走 P1「unsupported or unknown」400（fork 裁剪）。
6. link order 两个 junction Order 列值不镜像（配对同步、排序不同步）。
7. junction 表在树/表列表默认隐藏（CE `mm:true` 行为），`includeM2M=true` 可见；synced 守卫已断言生效。
8. realtime dispatch role 匹配无单测（Noco.ncMeta.knex mock 厚）；活体 probe 已验证链路。
