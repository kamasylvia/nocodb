# R2 P3 lane4 — 引擎重点路（E-bulk / E-syncing / E-watermark 回归 + 风暴队列）

**结论：1 error + 4 minor**

- 审查员：lane4（f09p3r2l4-*）；基线 27efcca491（R1 修复批）；:8080 = pid 50994（起于 01:27:58，晚于 dist mtime 01:06）只读实测，全程零构建/零重启。
- 质量门：`tsc --noEmit` exit 0；jest Fork 桶 **44/44**（3 套件）；Vite URL 编译法 **4/4 = 200 text/javascript**（CreateNewSync.vue / SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts，已验证返回真 transform 产物而非 HTML 兜底，见 §3 方法学）。AUTO 解锁回归：`useEeConfig.ts:167 blockTableSyncAuto=false` 源码 + Vite 产物双确认。
- 活体脚本与结果：`.work/ee-ce/f09p3r2l4-run1.sh`（→/tmp/f09p3r2l4-run1.txt）、`f09p3r2l4-run2.sh`（→/tmp/f09p3r2l4-run2.txt）；后端日志 `/private/tmp/nocodb-internal.log` 按 sync-id 归因。
- 测试数据：run1 sync `tsszc4zimgge38jve`、run2 sync `tsss1zm5kvx4iak98`/`tssne29rbe9dr8b4p`，两 base 对 ×3 全部删除，bases 列表复查 `f09p3r2l4` 残留 **0**；账号 f09p3r2l4-api 保留供后续轮次。

---

## 0. PASS 面（R1 三 error 族修复回归主结论）

| 项 | 证据 |
|---|---|
| **E-bulk 修复成立**：源表 v2 数组体 POST 3 行 → **一条 tap `(insert, 3 ids)`**（日志 01:42:39 jobr2x3blsslnx5vc，非 3 条事件）→ 镜像 3/3 **wall 388ms**（首轮 poll 即命中），RemoteId 零重复。R1「零传播」症状零复现 | run1 §4；日志 01:42:39 |
| **paste/CSV 同形态（源级）**：grid paste → `useCopyPaste.ts` bulkUpsertRows → `useGridViewData.ts:437/483 dbTableRow.bulkUpsert` → `BaseModelSqlv2.bulkUpsert:3612` → `afterBulkInsert:4200`（本次已 tap 的唯一站点）；单行 paste 走 afterInsert（P3 已 tap） | 源码链 grep |
| **E-syncing 修复成立（paused 决定性重演）**：freeze→paused → 三写（upd a1 / ins p_ins / del a2，全 200）→ 3s 零泄漏 → resume → **status 瞬时 'syncing'（补齐 claim 立即获胜，恰为修复生效的证明）** → 补齐 job 落日志（01:46:20 job4f9tqksxmga3r1 "enqueued watermark catch-up run"）→ **a1-edited + p_ins 在 ~500ms 内自动追平，零手动 resync** | run2 §5-6；日志 01:46:15-20 |
| **E-syncing 修复成立（Syncing 窗口）**：事件落于 run 在飞 → claim miss（静默置 marker）→ **run 一结束补齐立即入队**：sync2 全量建 3 行小表上 insert job 与 catch-up run 同秒成对出现（01:46:11）；sync3 窗口三写中 update/insert 经补齐追平（Qty=910、w_ins_win 均进镜像）。R1「markSkipped→补齐是死代码」不再成立 | run2 §7；日志 01:46:11 / 01:46:22-23 |
| **E-watermark 修复成立（形态）**：旧 `(LMT,ge,watermark)` where 串 **src 内 0 hits**（grep）；processor 不再 import `watermarkStart`；补齐 = 无消失扫描的全量 upsert（`processor.ts:321-343`），**插入行（updated_at=NULL 类）经此路径可达**（p_ins、w_ins_win 活体追平） | grep + run2 |
| **无消失扫描（no-sweep）实证**：a2（paused 窗口内删除）在补齐全量 upsert 跑完（a1/p_ins 追平即为该 pass 的存在证明）后 **ghost 仍在、RemoteDeleted=false** —— sweep 确实未跑 | run2 §6 NOTE |
| 风暴队列行为：15 连发 insert → **15/15 镜像 ~600ms**、零重复 RemoteId、status=active、`run failed`/`catch-up enqueue failed` 均 0 条；队列以「1 增量 job + k 次补齐 full pass」收敛（01:43:54-55 共 5 条 catch-up 日志）而非 15 个排队 job | run1 §6；§1 M1 |
| 单事件回归（修正形态 body-Id）：update 200 → 镜像 ~400ms；delete 200 → RemoteDeleted=true ~400ms；守卫链 mirror insert 400；静默窗 8s 零 churn | run2 §4、run1 §7 |
| **camelCase selectedFields 别名（R1 lane1 M1）修复**：PATCH `{"selectedFields":["Title"]}` → GET 持久化 `["Title"]`，恢复双列同样生效（`table-syncs.service.ts` 前置归一化 + P2 spec 覆盖） | run2 §8 |

---

## 1. Error

### E1' — 窗口内 delete 类事件仍静默发散：补齐（无 sweep 全量 upsert）结构性看不到删除，「paused window never loses changes」承诺对 delete 类不成立

- **活体证据（run2 §6，决定性）**：paused 窗口内删源行 a2 → resume → 补齐 pass 已跑（同窗的 a1-edited/p_ins 均追平）→ **镜像 a2 仍是活行 `RemoteDeleted=false`**（实测读回 `{"Title":"a2","RemoteId":"2","RemoteDeleted":false}`），直到手动 resync 前用户看到的是「源已删、镜像标记为在档」的静默发散。
- **代码根因**：`table-sync.processor.ts:321-343` 补齐分支只调 `upsertSourceRow`，**无任何 `applyDeletePolicy` 路径**；skip marker（`skippedDuringSync: Set<string>`）只存 syncId **不带被跳过的 rowIds/事件类型**——delete 事件到达时的 ids 在 claim miss 处被丢弃。delete 策略（物理删）同盲区：镜像物理 ghost 行同样永不在补齐中清除（源级断定，未单独活体）。
- **与修复批自述冲突**：`table-syncs.service.ts:1175-1177` 注释「resume re-enqueues one catch-up run **so a paused window never loses changes**」——对三类事件中的一类（delete）为假；R2 任务书「paused 三写 resume **全追平**」的验收口径同样只达成 2/3。R1 E1 的判 error 症状集（lane4 run5 的 a2 ghost）中此子症状延续至今。
- **影响**：mark_deleted 策略下用户看到已删源行仍为在档数据（比物理 ghost 更有误导性）；无 status/last_error 信号，唯一修复 = 手动 Sync now。
- **修复方向**（二选一，均在既有结构内）：① marker 携带事件负载（`Map<syncId, {upserts:Set, deletes:Set}>`，即 R1 lane4 E3 的原建议），补齐对 deletes 走 applyDeletePolicy；② 补齐分支既然已拉**全量**源数据，补一次镜像扫描 + sweep 即信息完备（「部分拉取不得 sweep」的顾虑对全量 pass 不成立；sweep 与并发删除的竞态由下一轮 marker→补齐兜底，最终一致成立）。

---

## 2. Minor

- **M1** 风暴放大：burst 到达时队列以「claim 成功的 1 个增量 job + 每个在飞 run 结束后的 1 次 catch-up **full pass**」收敛。小表无感；大表（10 万行级）一次 15 连发可串行触发多次全表 pass（每次 pass 还含 per-row 镜像 list 查询），期间持续占住 claim、阻断后续增量。正确性无损（本次 15/15 @600ms），负载放大建议后续评估 marker 合并/去重或补齐节流。
- **M2** spec 测试名与注释滞后：`table-syncs.Fork.spec.ts:488`「pulls the LastModifiedTime watermark」——断言体已是新行为（全量 upsert + 无 sweep，通过），但名称/注释仍描述已删除的水位机制，且未断言 `where` 参数不出现。安全网文档腐化，随下次改动顺手正名。
- **M3** 注释/死代码残留：`table-sync.processor.ts:28-32` 头注释仍写「incremental runs without ids pulls the RemoteUpdatedAt watermark (last_synced_at)」与实现不符；`table-sync-realtime.ts:280 watermarkStart` + `WATERMARK_OVERLAP_MS` 已无 src 调用方（0 hits），为死导出。
- **M4**（R1 lane4 M1 延续，修复批未声明处理）`bulkUpdateAll` 计数形态不 tap（`afterBulkUpdate` 注释声明选择）→ 网格按过滤器批量更新（UI 走 `useData.ts:293`）仍静默不传播、无 marker 无补齐。维持 minor 观察级。

---

## 3. 方法学注记

- run1 首版探针用了不存在的 per-record `PATCH/DELETE .../records/:id` 路由（404 被吞），update/delete 两 FAIL 为**探针缺陷非产品回归**（R1 lane4 方法学注记同款教训）；修正为 body-Id 形态后在 run2 §4 全过。E-bulk/pass 面结论不受影响。
- Vite URL 编译法注意：Nuxt dev 对任意路径（含不存在的 .vue）经 `/_nix/@fs/` 返回 200 text/html 假阳性；本轮以 `/_nuxt/@fs/<abs>` + content-type `text/javascript` + transform 产物正文三重确认，4/4 为真。
- run2 resume 后瞬时读到 status='syncing' 被探针记为 FAIL——实为补齐 claim 立即获胜的**修复生效证据**（探针断言写死 active），已按 PASS 面口径归位。
- afterBulkRestore tap：源码站位正确（同 `!model.synced` 守卫族、`BaseModelSqlv2.ts:5899`），但 **CE fork 内无任何调用方**（restore 流在 EE overlay；nc-gui `useBaseTrash.ts:27 restoreFromTrash` 为 CE 空实现）——本 fork 无法活体验证，属正确就位的死路径，不计 finding。
- 共享 :8080 有多 lane 并发流量，日志按 sync-id 归因；未对本 lane 结论构成依赖。
- 未覆盖（他路站位）：UI 活体、ACL 十一端点、paste 模式凭据矩阵、类型漂移全套——非本 lane 焦点，本轮仅抽守卫链与 camelCase。
