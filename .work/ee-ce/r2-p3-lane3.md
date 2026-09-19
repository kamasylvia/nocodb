# F09 P3 R2 lane3 审查报告（安全审计重点路，2026-09-20）

**结论：1 error + 4 minor**

- 审查员：lane 3（账号 f09p3r2l3-api / f09p3r2l3-ed，camoufox session 未启用——本轮结论全部由 API/源码/日志取证，无 UI 断言依赖）
- 基线：27efcca491（R1 修复批）= HEAD；:8080 = pid 50994 运行 `~/.nocodb-run/packages/nocodb/dist/main.js`（dist mtime 09-20 01:06 < 进程启动 01:27），dist 内 grep 到三处 R2 修复特征串（bulk-insert tap / bulkRestore tap / catch-up rework）各 1 处——确为修复后 dist。全程零构建/零重启/零 psql。
- 活体脚本：`.work/ee-ce/f09p3r2l3-run1.sh`～`run4.sh` + `/tmp/f09p3r2l3-micro.sh`；结果 `/tmp/f09p3r2l3-results1..4.txt`；后端日志 `/private/tmp/nocodb-internal.log`（共享实例，按 sync-id 归因，未依赖他路流量）。

---

## 0. PASS 面（先立后破）

**质量门**：`npx tsc --noEmit` exit 0；jest Fork 桶 3 suites 44/44；Vite URL 编译法 4/4 = 200（components/project/Action/CreateNewSync.vue、components/dashboard/TreeView/Table/SyncMenuOptions.vue、composables/useEeConfig.ts、composables/useTableSync.ts）。

**E-bulk 修复回归（活体 ✓）**：源表数组 POST 2 行（v2 标准批量形态 = paste/CSV 同通路）→ 镜像 <1s 全进；日志恰一入队 `enqueued incremental run (insert, 2 ids)` + `[incremental]: inserts=2`；静默窗 8s 零 churn、镜像稳定 5 行零自激；单行 insert 对照 ~300ms（R1 症状零复现）。

**E-syncing/E-watermark 修复（ins/upd 类活体 ✓）**：
- paused 窗口：freeze → 三写（全 200）→ resume → `enqueued watermark catch-up run` 日志 → catch-up `[incremental]: inserts=1 updates=2` → 窗口 update（w-upd Qty=42）与 insert（w-ins）全部追平。
- Syncing/resync 窗口（300 行表）：resync 中三写（全 200）→ 两连 catch-up（`inserts=1 updates=299` / `updates=300`，幂等复跑一致）→ 窗口 update（c-upd）、insert（c-ins）追平。
- 补齐不再走 RemoteUpdatedAt where（processor 源码已删 `srcLmtCol`/`watermarkStart` 拼接，改无扫描全量 upsert）→ 无 422、无 run failed；插入行（updated_at=NULL）经全量 pass 可达。幂等性实证：同表连跑两轮 catch-up 计数一致、无重复行。

**camelCase selectedFields（R2-4 ✓）**：PATCH `selectedFields:["Title"]` 生效（Qty 列 drop）、再 `["Title","Qty"]` 增列生效——P2 backlog 的 no-op 已修。

**realtime tap 防环（源码 + 活体 ✓）**：
- 七处 tap（含 R1 新增 afterBulkInsert/afterBulkRestore）同守卫族 `!this.model.synced`；引擎 dest 写 bulkInsert/bulkUpdate 带 `skip_hooks:true` → after* 整段不执行（`db/BaseModelSqlv2/insert.ts:655` 门），bulkDelete 无 skip_hooks 但守卫拦截——双层防护。
- 状态过滤移除后 `loadRealtimeTargets` 仅按 `role='main' + sync_trigger='realtime'` 匹配（P4 shadow 映射不双投）；级联源封死：mirror view `allow_sync` PATCH 400 + createSync 同 base 400。
- 防环 CAS 链闭合：事件→claim miss→markSkipped→run 末/resume `enqueueCatchUpIfNeeded`→consume 后入队→该 run 末 consume 已空不再级联（日志实证每窗口恰 1-2 次 catch-up，无自持循环）。

**affectedIdsBySource 注入面（✓）**：构造点仅 `claimAndEnqueue`（ids 来自 `extractPksValues` 的真实 DB 主键）；HTTP 无注入面——jobs API 仅 list（`/api/v2/jobs/:baseId` POST=jobList），resync/updateSync 不接收 affectedIdsBySource；processor 按 `mainMapping.source_table_id` 取 key，异 key → `[]`。

**paste 凭据面（✓）**：resolve-link/createSync 错误密码 400（bcrypt.compare，无密码先 400 且零泄露只回 passwordProtected 标志）；paste+realtime 建成并 full-create 4 行；getSync/listSyncs 响应无 `source_uuid`/`source_password_hash`/明文密码。

**detach ACL / P1+P2 站位回归（✓）**：editor 对 detach/resync/freeze/update(PATCH)/delete/createSync 全 403（detach 复用 tableSyncDelete ACL 生效）；sync title 未被改动；mirror 单行 insert/数组 bulkInsert 400、bulkUpdate 400、bulkDelete 拒绝（ERR_SYNC_TABLE_OPERATION_PROHIBITED）；v1 bulkUpsert owner 400 / editor 403。

**守卫链测试数据**：五轮全部清理（syncs 删、bases 删），bases 列表复查 `f09p3r2l3-` 残留 = 0；我名下五个 sync id 日志零 "run failed"。

---

## 1. ERROR（E-syncing 族残留）：窗口内 delete 事件不收敛——镜像 ghost 行永久残留，无自愈路径

**现象（双窗口双复现，三写全部 HTTP 200 实证）**：
1. **paused 窗口**（run3，sync tssnpzptun5cr93ql，delete 策略）：freeze → PATCH w-row1→w-upd(200)、DELETE w-row2(200)、POST w-ins(200) → resume → catch-up `inserts=1 updates=2 deletes=0` → w-upd/w-ins 追平 ✓，但 **w-row2 仍在镜像**，镜像 4 行 vs 源 3 行。
2. **Syncing/resync 窗口**（run4，sync tssjtpikwga5qge26）：resync 中 PATCH c0000→c-upd(200)、DELETE c0001(200)、POST c-ins(200) → 两连 catch-up（`inserts=1 updates=299` / `updates=300`）→ c-upd/c-ins 追平 ✓，但 **c0001 ghost 残留**，镜像 301 vs 源 300。

**结构根因**（源码）：skip marker 只记 sync_id 不记 rowIds（`table-sync-realtime.ts:45-53`，实现取了 R1 lane4 E3 建议的反面）；补齐 = 无消失扫描的全量 upsert（`table-sync.processor.ts:321-343`）；`list()`/`readByPk` 均排除软删行 → 窗口内被删的源行永远无人对账。delete 策略下 ghost 行以活数据形态滞留；mark_deleted 策略更糟——行 RemoteDeleted=false 滞留（源已删、镜像显示正常）。无自愈：realtime sync 无任何 sweep 路径，发散持续到手动 full resync——正是 R1 lane4 E1 定罪的错误形态（静默发散），从「全部事件丢失」收窄为「delete 类丢失」。

**对照验收**：本轮任务书 R2-2 明文「源插/改/删 → 事件进 markSkipped → 当轮结束补齐 → 数据最终一致」「paused 三写 → resume → 全部追平（lane4 run5 场景）」——delete 类两项均不满足；R1 已知遗留清单未豁免此项。修复方向：marker 携带事件 rowIds+事件类型（lane4 E3 原建议），catch-up 末尾对 marker 中 delete ids 按策略补对账（readByPk 404 → applyDeletePolicy），upsert 部分维持现状。

## 2. Minor

- **M1**：R1 新增的 `afterBulkRestore` tap 在本仓是死代码——trash restore 为 EE-gated no-op（`nc-gui/composables/useBaseTrash.ts:27-36`，`trashUnavailableReason='license'`），后端 `afterBulkRestore` 零调用者（全 src grep 仅定义+接口声明）→「软删恢复同样传播」运行时不可达、无法活体验证。tap 本身无害且守卫族一致（前向兼容），但修复声明覆盖了不可达路径，impl 自述应标注。
- **M2**：mirror bulkUpsert 的实际拦截来自 readonly 列校验（`Column "Title" is readonly column and cannot be updated`，400）而非 synced 守卫链——`bulkUpsert` 全程无 before* hook（`trx.batchInsert` 直写）。今日不可绕（镜像列全 readonly + raw 参数不可达 HTTP），属纵深防御缺口：若未来镜像列放开 readonly 或内部 raw 调 bulkUpsert 于 synced 表，守卫链不设防。建议补显式守卫。
- **M3**：claim miss 双处静默（`notifySourceChange` :194-195、`enqueueCatchUpIfNeeded` :249-257 的 else 只重置 marker 无日志）——R1 lane4 M3 建议的 warn/debug 未随 E1 一并修。本次排查靠成功日志反推，miss 场景不可观测（窗口事件恰在 CAS 边界丢失时无任何痕迹）。
- **M4**：`findDestRowByRemoteId` 的 `(RemoteId,eq,${remoteId})` where 串插值——remoteId=源表主键值。nc_ 表自增 int 不受控，但外部源（pg/mysql）text PK 场景存在 where 语法注入面（构造 PK 改变匹配行 → 错行更新/删除）。建议 knex 参数化。防御性 minor。

**观察级（不计修）**：① 窗口事件密集时 catch-up 全量 pass 成本 O(N)/次（300 行表两连跑），单进程串行不风暴，大表+高频写下补齐延迟无上界（R1 lane4 M4 同族）；② bulkUpdateAll（count 形态）仍不 tap（R1 M1 已知维持）；③ 同一 ERR_SYNC_TABLE_OPERATION_PROHIBITED 在 insert/update 返 400、bulkDelete 返 422——状态码不一致，语义均为拒绝。

## 3. 方法学注记（供裁决）

- run2 的窗口 update/delete「FAIL」为探针自身缺陷：v2 无 per-record PATCH/DELETE 路由（PATCH/DELETE `/records/:rowId` 404 静默——R1 lane4 方法学注记同一陷阱），且空 Id 探针产生假 422/假 ghost。**终判以 run3/run4（修正探针：数组 PATCH/DELETE，写操作 HTTP 码逐一实证 200）为准**；run2 中仍有效的结论：paste 凭据七项、ACL 七项、camelCase selectedFields、resume catch-up 日志。
- 共享 :8080 有他 lane 并发流量（日志可见同类测试），本 lane 结论仅基于自有 sync id 归因。
- camoufox session 未消耗（无 UI 断言；API 层已覆盖本 lane 安全面）。
