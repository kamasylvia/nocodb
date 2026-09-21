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
- **updateSync 加/删**（**P4-R1 重写**，R1 四路 E1 收敛后）：
  - 去留判定：drop 循环以「**主映射域**（`fk_table_sync_mapping_id === mainMapping.id`）」+「**desired 集合**」判定——标量按标量 desired，link 按 **desiredLinks**（selected_fields 数组过滤后的 syncable links；**null = 全部 syncable links**）。仍在 desiredLinks 中的 link 层不拆毁；真掉线的 link 才走 dropMirrorLinkColumn + dropShadowForRelated（引用计数按 desiredLinks 解析）。原实现按 desiredSrcIds（仅标量）判定，任何 selection PATCH 都会把已映射 link 全部误删（lane1/3b/4b/5 E1 同判）。
  - 加腿 = `ensureShadowForRelated` + `addMirrorLinkColumn` + updateSynced(J) + mapping 行（同 create）；**shadows Map / takenTitles 提循环外**且以**既有 linked_shadow mappings 播种**——同 RT 第二条 link 共享 shadow（原实现每次迭代传全新 Map，双 shadow 会让引擎 `shadowRemoteToPkBySource` 按 source_table_id 键控 last-wins、junction 拿错表 pk，E1 修复后该雷即激活，故同批修）。
  - **结构变更完成后 enqueue 一个 full-resync**（数据回填；lane1 E1④——原实现 PATCH 后静置 junction=0/shadow=0 等手动 resync）。keep-only PATCH（无增无删）不投。
- **sourceSchema**：columns 响应附加 link 列（`{id,title,uidt,link:true}`），向导零改动自然可选（UI 按 title 渲染）。**P4-R1 修订**：paste 分支**不列** link 列（paste 凭据为单视图暴露面，link 同步仅 browse 模式，见 §10 族4）。

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
- **incremental（affectedIds 非空，realtime scalar 事件）**：仅主表 pass；新增 **junction 孤儿清理**——pendingDeletes 落地的 dest main pk 集合，对每个 junction mapping 删 `mainSideFk IN (pks)` 的孤儿行。**P4-R1 修订（lane4b M1）**：mark_deleted 策略下被标 flag 的行同样清理其 junction 配对——junction 配对在**两档下均镜像源 junction**（行级 on_delete 策略只管镜像行本身：delete 删行 / mark_deleted 打标保行）。原实现 mark_deleted 增量档保留陈旧配对到下次 full pass，与 full 档行为不一致。shadow/junction 重算不做（等 link 事件或 catch-up 全量档）。
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
| `packages/nocodb/src/services/table-syncs.service.ts` | `isSyncLinkColumnUidt` 分类导出、`loadSyncableLinks`（mm + 同 base + 非自引用过滤）、`insertTableSyncMapping`、`setupMirrorSystemColumns`（P1 内联块抽出，main/shadow 共用）、`ensureShadowForRelated`、`addMirrorLinkColumn`（columnAdd 建 mm link + junction → `Model.updateSynced(junction,true)`）、`dropMirrorLinkColumn`（junction 级联）、`dropShadowForRelated`（引用计数）、createSync 三层构建 + 失败全量清理、updateSync 加/删级联、deleteSync role 排序级联（junction→shadow→main）、detachSync 三表全部转正、sourceSchema 双分支 link 列（`link:true`） |

> **P4-R1 勘误**：上表原稿写 updateSync 级联为「keptLinkRtIds 引用计数」——R1 实测该逻辑为死代码（keptLinkRtIds 守卫条件对 link 映射恒 continue，集合恒空），updateSync 实际行为是「任何 selection PATCH 全量拆毁已映射 link」。已在 P4-R1 修复批重写（见 §10 族1/族2）。
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

## 10. P4-R1 修复批记录（2026-09-20）

> 输入 = R1 四路 error 报告收敛的四大族（lane1 / lane3b / lane4b / lane5），全部必修项 + 2 个 minor 顺手项。全部改动 `// [CE-EE] F09 P4-R1` 标记。

### 族↔修复映射

| 族 | 报告来源 | 修复 |
|---|---|---|
| **1. updateSync link 级联**（4 路同判 E1/E3） | lane1 E1、lane3b E3、lane4b E1、lane5 E1 | `updateSync` 重写：drop 循环限定主映射域（`fk_table_sync_mapping_id===mainMapping.id`，顺带修 lane4b E1 子效应「shadow 列身份映射被静默清除」）；link 映射去留按 **desiredLinkSrcIds**（selected_fields 解析出的 desiredLinks）判定——keep-link PATCH 不再拆毁三层；`keptLinkRtIds` 改由 desiredLinks 直接解析（原死代码）；null=全字段**含全部 syncable links**（既有 link 保留 + 未映射 link 补齐）；真掉线 link 才走 dropMirrorLinkColumn + dropShadowForRelated |
| **2. 双 shadow**（lane3b M1、lane4b M2、lane5 M1） | 同上 M 族 | 加腿循环的 `shadows: Map` / `takenTitles` 提出循环，且以**既有 linked_shadow mappings 播种**（查 dest model 存活才复用）——同 RT 第二条 link 复用 shadow，引擎 `shadowRemoteToPkBySource` 键冲突随共享消失 |
| **3. LTAR 链接通道守卫**（lane3b E1、lane4b E2） | 同上 | `BaseModelSqlv2` 新增 `assertLinkWriteAllowed`（422 同族 `ERR_SYNC_TABLE_OPERATION_PROHIBITED` + link 专属 customMessage），挂 **addChild / removeChild / addLinks / removeLinks / reorderLink** 五入口（`nestedLink/nestedUnlink/v1-v3 alias/linkSwap/ltar-cols-updater` 全部汇入）。addLinks/removeLinks/reorderLink 在 checkPermission **之前**（守卫与角色无关）；addChild 在 onlyUpdateAuditLogs 早退之后（audit replay 零写数据，放行）。引擎不受影响：junction 写走专用 raw-knex 通道（recomputeJunctionPairs / cleanupJunctionOrphans），不经这五个方法，无需 bypass 标志 |
| **4. paste+link 升权**（lane3b E2，裁定=拒收） | 同上 | createSync 前置校验：`isPaste && selectedLinks.length ⇒ 400`（消息说明 paste 凭据仅单视图暴露面、link 同步仅 browse 模式）；paste 分支 sourceSchema **不再列** link 列（不留 UI 死胡同）。文案进 i18n：`msg.warning.syncPasteLinkUnsupported`（en.json + zh-Hans.json） |
| **5. deleteSync 僵尸**（lane3b M3） | 同上 | 主镜像 tableDelete 失败且表仍存活 → 原错误上抛、**不删 sync 行**（保 detach/重试出口）；表已不存在（out-of-band 删除）→ 视为成功继续；junction/shadow 仍 best-effort |
| **6. mark_deleted 两档一致性**（lane4b M1） | 同上 | 选**实现**：incremental 档 mark_deleted 被 flag 的行同步清理 junction 配对（`orphanedMainPks` = pendingDeletes ∪ flagged）——两档统一语义「**junction 配对恒镜像源 junction；行级 on_delete 策略只管镜像行**」。§4 声明同步修订 |
| 附带（lane5 观察） | createSync 失败清理顺序 | `createdDestTableIds` 逆序删除（junction→shadow→mirror），PG 下 junction FK 不再挡 best-effort 清理 |

### 改动文件

| 文件 | 内容 |
|---|---|
| `packages/nocodb/src/services/table-syncs.service.ts` | 族1/2/4/5：updateSync 级联重写 + shadows 播种共享 + 结构变更后 enqueue full-resync + paste+link 400 + paste sourceSchema 裁剪 + deleteSync 主镜像守卫 + createSync 清理逆序 |
| `packages/nocodb/src/db/BaseModelSqlv2.ts` | 族3：`assertLinkWriteAllowed` + 五入口挂守卫 |
| `packages/nocodb/src/modules/jobs/jobs/table-sync/table-sync.processor.ts` | 族6：incremental mark_deleted 配对清理对齐 full pass（含注释修订） |
| `packages/nc-gui/lang/en.json` / `zh-Hans.json` | 族4：`msg.warning.syncPasteLinkUnsupported`（en + zh-Hans） |
| `packages/nocodb/src/services/table-syncs.Fork.spec.ts` | 13 个 R1 回归用例（见下） |

### 回归用例（table-syncs.Fork.spec.ts，47→60）

- **P4-R1 updateSync link cascade**（4）：keep-link PATCH 不拆毁（无 columnDelete/tableDelete/tableCreate/insertColumnMappings、不投 resync）；null PATCH 含既有 links；真掉线 link 全级联 + 投 full-resync + sync 行保留；同 RT 双 link 加腿共享既有 shadow（无 tableCreate、双 junction、updateSynced×2、投 resync）。
- **P4-R1 paste+link rejection**（2）：paste createSync 选 link 400（消息含 browse mode、零 job）；paste sourceSchema 不列 link 列。
- **P4-R1 deleteSync zombie guard**（2）：主镜像删除失败 → 原错误上抛 + sync 行保留；主镜像已不存在/删除成功 → sync 行删除。
- **P4-R1 LTAR link-channel guard**（4）：addLinks 422（先于权限检查）；addChild 422；audit-only replay 放行；普通表不触发。
- **P4-R1 mark_deleted junction pairs**（1）：incremental mark_deleted flag 行的 junction 配对同步清理（bulkDelete 不发生 + whereIn(d_main, [flagged pk])）。

### 质量门与活体

- `npx tsc --noEmit`：exit 0。
- `npx jest --testPathPattern 'Fork'`：**60/60**（3 suites；P1–P3 44 + P4 3 + R1 13）。
- 活体（:8080 重建 dist → rsync ~/.nocodb-run → 重启，nocodb-dev，`.work/ee-ce/f09p4r1-fix-selftest.sh` **19 PASS / 0 FAIL**，测试 base 全清）：
  - **A keep-link PATCH**：mirror Ns 列 id 不变、mappings=3、junction 表在且数据未动、无结构变更不投 resync（旧版全拆）。
  - **B 双 link 加腿**：PATCH 后立即 shadow=1（旧版翻倍）junction=2；full-resync 自动跑完（status active），双 junction 配对 1/1 回填（旧版静置 0），mirror Ns+Ns2 并存。
  - **C 镜像 link 写守卫**：注入 422（旧版 201）、unlink 422（旧版 200），错误码 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`。
  - **D paste+link**：createSync 400 + 消息含 browse-mode 说明；sourceSchema paste 分支不列 link；paste 纯标量 200 不受误伤。
  - **E null PATCH**：补齐后建的新 link（Ns2）+ 保留既有 Ns，shadow 仍共享（main+1S+2J）。
- 后端 dev server 已带 R1 修复批构建运行（pid 见 /tmp/nocodb-internal.log）。

### 遗留（新增/更新，均不阻塞）

1. §9 原 8 条全部维持（realtime 风暴简化档、无 LMT 早退、v3 attachment、shadow 列漂移、bt/hm/oo 裁剪、order 不同步、junction 隐藏、dispatch 无单测）。
2. **旧行为自愈路径**：R1 之前被旧 updateSync 拆毁的 sync（若仍在）可用「PATCH 移除该 link → PATCH 加回 + resync」重建三层；新代码不再产生该损伤。
3. 源 link 列被删除后其残留 mapping 的 junction mapping 行成为惰性孤儿（引擎因 srcCol 缺失自动跳过；P4 前既有边角，未在本轮处理）。
4. lane3b M2（columnAdd 对 synced 表无守卫，P1 起既有）未在本轮范围，维持已知裁剪记录。

## 11. P4-R4 修复批记录（2026-09-22）

> 输入 = R4 唯一 error（lane5 E1，双 junction 共享 shadow 下 updateSync drop 腿 404 + 部分拆毁 + 重试留孤儿 junction）+ lane1 M1（processor 注释腐化，doc-only）。全部改动 `// [CE-EE] F09 P4-R4` 标记。

### error↔修复映射

| 项 | 报告来源 | 根因 | 修复 |
|---|---|---|---|
| **E1 drop 腿共享 shadow 拆毁序** | lane5 E1 | drop 循环逐 link `dropMirrorLinkColumn` 后**立即** `dropShadowForRelated`——全 link 落选时 `keptLinkRtIds` 为空，第一条 link 的 drop 即删共享 shadow → 第二条 link 的 `columnDelete` 撞已删结构 404 中断循环；重试时 dest 列已不存在 → `dropMirrorLinkColumn` 解析不出 junction → junction mapping 行永久残留 | **两阶段 drop**：phase 1 循环只拆每条落选 link 的镜像列 + junction + 各自 mapping 行（此时全部 shadow 仍站立）；循环后新增**收敛 sweep**（见下）；phase 2 才做 shadow 引用计数判定——`keptLinkRtIds`（存活引用集）+ 逐条复验「无其它 mapping 行仍引用该 RT」双闸，通过才 `dropShadowForRelated` |
| **E1 重试收敛** | 同上 | 同上（部分拆毁态不可收敛） | ① `dropMirrorLinkColumn` 幂等化：dest 列缺失 → 跳过 columnDelete 不报错；columnDelete 抛 404 族（`not found`/404）→ 吞掉继续走 junction/mapping 清理，其它错误照常上抛；② 新增 **junction 僵尸 sweep**：link drop 发生过的 PATCH 里，重读 dest 模型，凡 junction-role mapping 的 junction 不再被任何存活 link 列引用（早前中断 PATCH 的残留态）→ `tableDelete` best-effort + 无条件删登记行。keep-only PATCH 不触发 sweep（与 R1 行为逐字节一致） |
| **M1 注释腐化** | lane1 M1（doc-only） | processor 头注释仍写 catch-up「WITHOUT the disappearance sweep」，与 P3-R2 实际实现（catch-up 落入全量 pass 含 sweep）矛盾 | 注释改为准确表述（指向 P3-R2 分支） |

### 改动文件

| 文件 | 内容 |
|---|---|
| `packages/nocodb/src/services/table-syncs.service.ts` | E1：drop 循环两阶段化（`droppedLinkRtIds`/`droppedLinkSrcColIds` 收集）+ junction 僵尸 sweep + shadow 引用计数 phase 2；`dropMirrorLinkColumn` 404 族幂等容错 |
| `packages/nocodb/src/modules/jobs/jobs/table-sync/table-sync.processor.ts` | M1：pull-shape 头注释修正（catch-up = 全量 pass 含 sweep） |
| `packages/nocodb/src/services/table-syncs.Fork.spec.ts` | 3 个 R4 回归用例（见下），60→63 |
| `.work/ee-ce/f09p4r4-fix-selftest.sh` | 活体自测脚本（本节验证所用） |

### 回归用例（table-syncs.Fork.spec.ts，60→63）

- **drops ONE of two same-RT links**：删 L1 → 仅 L1 镜像列 + L1 junction 删；共享 shadow 保留；L2 三层不动（无重建、无 updateSynced）；投 full-resync。
- **drops BOTH same-RT links**：双 junction + 共享 shadow 全清且各恰一次（shadow 1 次，非 2 次）；双 junction mapping 行 role-scoped 删除断言；投 full-resync。
- **converges on retry after mid-loop failure**：columnDelete 首调「列 meta 已毁 + 非 404 错误上抛」模拟部分拆毁 → PATCH rejects；同 PATCH 重试 → sweep 清僵尸 junction + L2 正常级联 + shadow 引用计数删除 → 表集合等价断言（sweep 在循环后，顺序与 happy path 不同）。

### 质量门与活体

- `npx tsc --noEmit`：exit 0。
- `npx jest --testPathPattern 'Fork'`：**63/63**（3 suites；P1–P3 44 + P4 3 + R1 13 + R4 3）。
- 活体（:8080 R4 构建 → rsync ~/.nocodb-run → 受控重启，双条件核验过：进程启动 04:06:36 > dist mtime 03:57:30；dist 特征串 `P4-R4`×5、`P4-R2`×2、`prohibitedSyncTableOperation`×7；nocodb-dev；`.work/ee-ce/f09p4r4-fix-selftest.sh` **21 PASS / 0 FAIL**，测试 base 清零核验过）：
  - 双 link 同选建 sync → 1S+2J，配对回填 1/1。
  - **删单条** → 200；shadow 保留、余 1 junction 配对 1、Ns 列删 Ns2 列留。
  - **加回** → 复用共享 shadow（1S+2J），配对 1/1。
  - **一条 PATCH 全删（lane5 E1 精确触发，旧代码此处 404 + 孤儿 junction）** → 200；roles=[main]，双 junction 表 + shadow 表全删（404 核验），镜像 link 列零残留。
  - **重复轮**（null 重建 → 再全删）→ 收敛可重复，零残留。

### 遗留（新增/更新，均不阻塞）

1. §9/§10 遗留全部维持；§10 遗留 3「源 link 列被删后惰性孤儿」——本批 sweep 在**该 sync 下一次 selection PATCH** 时会顺带清掉僵尸 junction（提前自愈），无需专门迁移。
