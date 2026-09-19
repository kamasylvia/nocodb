# F09 P3 R1 lane1 审查报告（2026-09-19）

**结论：2 error + 1 minor**

- 审查员：lane 1（f09p3r1l1-* / camoufox session f09p3r1l1）
- 基线：f6a9314b5e（P3 实现批）；HEAD 9f10ea52ea 起无 packages/ 变更（核实 `git diff f6a9314b5e..HEAD -- packages/` 为空）
- :8080 = pid 95243，运行 `/Users/kamasylvia/.nocodb-run/packages/nocodb/dist/main.js`，dist 内 grep 到 `markSkippedDuringSync` 等 P3 特征（18 处）——确为 P3 dist；全程零构建/零重启
- 测试数据：`f09p3r1l1-` 前缀，src base pygcki7ums0vlu6 / dst base pjqjem3t4fx8h6x，已全部删除（syncs ×4、detached 表 ×1、两 base 均 200，bases 列表复查无残留）；camoufox session 已关

---

## ERROR 1（核心）：Syncing 窗口内的 realtime 事件被静默丢弃——「跳过→补齐」机制实际不可达

**现象（两次实证）**：
1. c1、c2 两条 single insert 相隔 ~300ms：c1 进镜像（`enqueued incremental run (insert, 1 ids)` + `inserts=1`），**c2 零日志、零 error、永不进镜像**，直至清理时仍缺失。
2. 最小间隔复现（d1/d2 连发）：d1 进、d2 丢，与 1 完全同型。

**根因**（`packages/nocodb/src/helpers/table-sync-realtime.ts:80-97`）：`loadRealtimeTargets` 的查询条件含 `status: TableSyncStatus.Active`。当 sync 正处于 Syncing（realtime claim 占用，或手动 resync 经 `enqueueSyncJob` 置 Syncing）时，事件 tap 的目标查询**直接查空 → `!targets.length` 提前 return**——根本走不到设计中的 CAS-miss 分支（`claimAndEnqueue` 返 null → `markSkippedDuringSync`）。skip 标记永不变置，`enqueueCatchUpIfNeeded` 永无可消费标记。CAS-miss 分支只在 status 恰在查询与 CAS 之间翻转（毫秒窗）时可达，实践中为死代码。

**后果**：违反本轮任务书 P3 范围第 2 条（「长跑窗口内源再改 → 跳过 → 当轮结束后补齐 → 数据最终一致」）与实现自述/GOAL-STATE 定案的同款声明。大表 resync 窗口以秒~分钟计，窗口内所有源变更**静默丢失**（无日志无 error），镜像静默漂移直到下一次无关 realtime 事件或手动 Sync now。用户无任何可感知信号。

**修复方向**：`loadRealtimeTargets` 去掉 `status='active'` 过滤（保留 sync_trigger=realtime），让事件照常走到 CAS——active 则 claim，syncing 则 CAS-miss 置标记走补齐；或在目标查询命中 syncing sync 时置标记。jest 的 44 用例未覆盖「事件到达于 Syncing 窗口」这一时序，修复时应补并发时序用例。

## ERROR 2：bulk insert（数组 POST / CSV 粘贴导入）不触发 realtime——镜像静默缺行

**现象**：源表数组 POST 2 行（v2 records API 标准批量形态）→ 源落库成功，等待 5s+ 镜像不增；对照单行 insert ~4s 跟随。日志确认无任何 TableSyncRealtime 活动。

**根因**：`BaseModelSqlv2.bulkInsert` 多行走 `afterBulkInsert`（BaseModelSqlv2.ts:4197），五处 tap 均未覆盖该 hook。同型的 `bulkUpdateAll`（计数形态，BaseModelSqlv2.ts:4949）也无事件——实现注释已声明，但对用户同样是静默漂移（其唯一兜底是 catch-up 水位 job，而 catch-up 又因 ERROR 1 不可达）。

**后果**：粘贴/CSV 导入是最高频批量数据入口；向导文案承诺「Changes in the source view sync to the mirrored table within seconds」直接失信。与 ERROR 1 叠加后无任何自动恢复路径。

**修复方向**：`afterBulkInsert`（数组形态，逐行 extractPks）加 tap；bulkUpdateAll 计数形态可投一个空 affectedIds 的水位 job（借道现有 incremental 空拉分支）或至少记入已知限制文档。

## MINOR 1

- `updateSync` 的 `selectedFields`（camelCase）静默 no-op，仅 `selected_fields`（snake）生效——P2 已知观察（字段命名不对称 backlog）在 P3 站位中再次踩中，建议提前修（对齐创建入参的 camelCase）。

---

## PASS 面（全部实测通过）

**质量门**：`npx tsc --noEmit` 0；jest Fork 桶 44/44（含 3 个 P3 新用例）；Vite URL 编译法 CreateNewSync.vue / SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts 全 200。

**realtime 全链**（browse+realtime sync，on_delete_action=delete）：
- full-create：3 行镜像 ✓；single insert → 镜像 ~4s 跟随（last_synced_at 同步推进）✓；single update（PATCH id-in-body）跟随 ✓；delete（数组 DELETE=bulkDelete tap，1 ids）→ 镜像行删 ✓
- bulkUpdate（数组 PATCH，2 ids）→ 镜像 2 行更新 ✓；bulkDelete（ids 在镜像中存在）→ 镜像行删 ✓
- **防环**：全程日志仅 9 个 job 对应 9 次真实写，无自激；镜像表引擎写被 `!model.synced` 守卫 + skip_hooks 双抑制 ✓

**mark_deleted + 多 sync 分发**：同源第二 realtime sync（mark_deleted）→ 同一删除事件 fan-out 至 3 个 realtime sync（browse×2+paste×1，日志 3 条 enqueued）：delete 策略镜像删行、mark_deleted 策略镜像 RemoteDeleted=true、其余行 false ✓

**AUTO 解锁 / trigger 面**：`blockTableSyncAuto=false`（useEeConfig.ts:167）；createSync `syncTrigger:'realtime'` 200 落库 `sync_trigger:'realtime'`；`hourly` 400 ✓；manual 默认。**manual sync 行为不变**：源改不跟随（停留旧值），Sync now 后对齐 ✓；realtime sync 无 Sync now 依赖、API resync 仍可用 ✓

**UI 活体**（camoufox, :3000）：向导三入口形态在（NocoDB Sync 卡）；Browse/Paste 双模式；step2 **Automatically/Manually 单选可用**（默认 Manually），选 Automatically 建成 `sync_trigger:'realtime'` 且源改跟随（777 活体）✓；镜像树菜单 active 态全项（Sync now/Pause/Convert to regular table/Delete sync）；UI Delete sync 流（确认弹窗→sync 行消失）✓

**P1+P2 站位**：守卫链——镜像 insert/update/delete 均 400 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`、删表 400 ✓；editor 对 11 端点全 403（realtime 建的 sync 与 manual 同权）✓；selected_fields 增列→镜像新列+增量进数（Status=ok）、减列→列 drop ✓；detach→200、synced=false、镜像可写（insert 200）、sync 行消失 ✓；paste+realtime 组合（uuid 凭据）建成且跟随 ✓

**水位/catch-up 逻辑**：processor 空 affectedIds 分支（LMT 水位拉 + 跳 sweep + 无 LMT 回退全量）与受影响拉取（readByPk 排软删 + 消失 id 按策略）源码审通过、jest 用例覆盖逻辑本身；但其**唯一运行时入口（补齐）因 ERROR 1 不可达**，活体无法独立验证，修复 ERROR 1 后应回归。

**已知遗留确认**（不重复报）：级联止于一跳、补齐标记单进程内存态、水位依赖源 LMT 列、paste resync 不复验 hash——均如自述。

## 未覆盖

- 多 worker 部署下补齐丢失（内存态）——单实例环境无法构造
- editor UI 侧 gate 卡（API 403 已验，UI 复核省略）
