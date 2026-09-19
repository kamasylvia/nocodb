# F09 P3 实现自述（incremental / realtime + AUTO 解锁，2026-09-19）

HEAD（实现批）；基线 = F09 P2 pass（253c3b6ee5）。质量门：`npx tsc --noEmit` 0 + `npx jest --testPathPattern 'Fork'` 44/44（新增 3 个 P3 用例）+ 改动 SFC Vite URL 200（CreateNewSync / SyncMenuOptions / useEeConfig / useTableSync）+ HMR 日志无错（仅存量 storeToRefs auto-import WARN，非本次引入）。

## 交付面

1. **realtime 分发（源 hooks → incremental job）**
   - 新文件 `packages/nocodb/src/helpers/table-sync-realtime.ts`（零重依赖）：
     - `notifySourceChange(sourceContext, sourceModelId, event, rowIds)`：knex 一次 join（TABLE_SYNC_MAPPINGS × TABLE_SYNCS）查 source_table_id 命中 + sync_trigger=realtime + status=active 的 sync → 逐 sync 原子 CAS 占有（`UPDATE … SET status='syncing' WHERE id=? AND status='active'`，0 行 = 正在 Syncing，跳过）→ `jobsService.add(TableSyncRun, { mode:'incremental', affectedIdsBySource: { [sourceTableId]: ids } })` → 回填 sync_job_id；enqueue 失败回滚 status=active。
     - jobsService 解析路径：`Noco.nestApp.get('JobsService')`（BaseModelSqlv2 无 DI；nestApp 在 Noco.init 后、任何数据 API 前就绪）。req 只传 `{ user: { id: created_by } }` 最小 shim（审计归属），不序列化整个请求对象。
     - **Syncing 中跳过 → 补齐**：CAS miss 时记入进程内 `skippedDuringSync` Set；processor 每轮结束调 `enqueueCatchUpIfNeeded(syncId)` 补投一个**空 affectedIds 水位 job**（claim miss/失败则保留标记下轮再试）。进程内存态：CE fallback queue 与 API 同进程，多 worker 部署只丢补齐不影响正确性。
   - `TableSyncsService.notifySourceChange`（static）委托上述 helper——服务入口语义保留；实现不落 service 文件是因为 BaseModelSqlv2 → service → tables.service → Model → BaseModelSqlv2 会成值级 import 循环，helper 依赖自由。
   - `BaseModelSqlv2` 五处 after* tap（afterInsert / afterUpdate / afterBulkUpdate / afterDelete / afterBulkDelete）：fire-and-forget（`void …`）+ try/catch 吞错 + extractPksValues 传 rowIds；afterBulkUpdate 的 bulkUpdateAll 形态（newData=计数）无 rowIds 不 tap。**防环守卫 `!this.model.synced`**：镜像表是引擎写目标永不 tap（bulkDelete 无 skip_hooks 参数，靠此守卫挡住引擎 sweep 对 dest 侧 afterBulkDelete 的触发）。引擎写 bulkInsert/bulkUpdate 本就 skip_hooks:true 短路 after*。副作用语义：镜像表再作为源（B→C 级联）时引擎写被抑制，级联链止于一跳（fork 简化，防环优先）。

2. **processor incremental 模式**（`table-sync.processor.ts`）
   - `applyFullSync` 接受 jobData，三分支：
     - **affectedIds 非空**（realtime）：逐 id `srcBaseModel.readByPk(id, { ignoreView, ignoreRls })`（排除软删行）拉源行 upsert（RemoteId 键控 dest 单行查找，不全表扫）；拉不到的 id = 消失 → 按 on_delete_action（delete→bulkDelete / mark_deleted→RemoteDeleted=true）。
     - **空 affectedIds**（catch-up/水位）：源表存在 LastModifiedTime 列且 last_synced_at 有值 → `(LMT,ge,last_synced_at−30s)` 水位拉（30s 重叠窗抗飞行中写入，upsert 幂等）+ **跳过消失扫描**（部分拉取下 sweep 误判 stale）；源无 LMT 列或无水位 → 回退全量。
     - **全量**（full-create / 手动 resync）：原路径不动（dest 全表 existing map + 源分页 + sweep）。
   - 全分支共用 upsert/delete/mark 聚合管道（pendingInserts/pendingUpdates/pendingDeletes + CHUNK 200 flush），引擎写仍走 allowSystemColumn 白名单通道（skip_hooks/skipPermissionCheck/skipAttachmentOwnershipCheck）。全量 sweep 的 mark/delete 也并入聚合管道（原两次独立 bulkWrite 合一批，断言口径见 spec 适配）。
   - last_synced_at 水位语义不变：每轮完成置 now；水位拉起点 = 上轮完成时刻 − 30s。

3. **AUTO 解锁 + 向导 Automatically 档**
   - `useEeConfig.ts`：`blockTableSyncAuto` → `false`（[CE-EE] 标记；blockCustomSync 保持 true）。
   - `createSync`：syncTrigger 接受 `manual`（默认）/ `realtime`，其余 400「Invalid sync trigger」；sync_trigger 落库（TableSync.insert extractProps 原生支持）。
   - `CreateNewSync.vue` step2 同步方式步：Manually/Automatically 单选（i18n labels.automatically/automaticallyDesc/manually/manuallyDesc 零新增，zh-Hans 已备）→ create 体传 syncTrigger；realtime 建后状态机不变（首跑 full-create，占同步 status=Syncing→Active）。

4. **顺带修：Convert 后 grid 瞬空白**（`SyncMenuOptions.vue` onDetach）
   - 根因：detach 只 removeMeta（缓存删 + deleted 标记）+ loadTables，活动表的 meta/视图缓存空窗，已打开的 grid 渲染 stale 只读帧。
   - 修复：removeMeta 后 `getMeta(baseId, tableId, true)` 强刷 meta（synced/readonly 解除立即生效）+ `useViewsStore().loadViews({ force: true })` 重拉视图列表。

## 测试

- spec 适配两处（`src/services/table-syncs.Fork.spec.ts`）：
  - 「rejects realtime trigger」→「rejects an unknown sync trigger」（realtime 已解锁，hourly 400 口径）；
  - mark_deleted sweep 用例：mark 行并入 upsert 同批（arrayContaining 断言）。
- 新增 3 个 P3 用例：incremental affectedIds 按 pk 拉取 + 消失 id 按 delete 策略删镜像行 + 部分拉取不扫源；mark_deleted 策略对消失 affected id 打 RemoteDeleted；空 affectedIds 水位拉（LMT 列）upsert 且跳过 sweep、完成后回写 last_synced_at。mock list 支持 `(RemoteId,eq,x)` 过滤 + readByPk stub。
- 约束自查：源侧 tap 仅匹配 SOURCE model id（mapping source_table_id）；引擎 DEST 写被 synced 守卫 + skip_hooks 双重抑制，无环。

## 已知限制 / 遗留（不阻塞，待会审判定）

- 级联镜像（镜像表作另一 sync 的源）不自动传播——synced 守卫刻意为之，防环优先。
- 补齐标记（skippedDuringSync）为单进程内存态，多 worker 部署下 Syncing 窗口内的事件要等下一次水位/手动跑。
- Syncing 窗口内被跳过的事件在当轮 affectedIds 快照之外，若补齐 job 也失败则需手动 Sync now（状态 Error 可见）。
- 水位拉依赖源表 LastModifiedTime 系统列；外部源无该列时增量回退全量（定案语义）。
- realtime createSync 正路径无单测（mock 厚），活体验证归会审阶段。
