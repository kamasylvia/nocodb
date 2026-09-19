# F09 P3 R1 会审报告 — lane 2（API 实测 + 引擎活体 + 源码审 + UI 活体）

**结论：2 error + 2 minor**

审查基线 f6a9314b5e（P3 实现批，main HEAD 9f10ea52ea 前的最后一功能提交）；:8080 = P3 dist（pid 95243，~/.nocodb-run 副本），全程未动进程/源码。账号 f01e2e@ce-ee.local（owner，与并行 lane 共用存在 token 互踢干扰，已在测试装置层消化）；UI/API 分离不彻底的偏差：UI 段因 f01e2e 被并行路互踢两次重登，UI 数据断言改由页面内 JWT+API 复核补齐。测试数据前缀 `f09p3r1l2-*`，**已全部清理**（3 个 base 删除含级联 sync/镜像表，`GET /meta/bases` grep 零残留；camoufox session f09p3r1l2 已关闭；测试账号 f09p3r1l2-e-*/f09p3r1l2-api-*/f09p3r1l2-dbg 无自删通道，留库待管理员清理，历轮同例）。

---

## E1（error）— bulk insert 多行写不触发 realtime 传播，且无任何补齐机制

**位置**：`packages/nocodb/src/db/BaseModelSqlv2.ts` 五处 tap 挂点选择 + `packages/nocodb/src/helpers/table-sync-realtime.ts`。

**事实**：tap 覆盖 afterInsert（单行）/afterUpdate/afterBulkUpdate/afterDelete/afterBulkDelete，但 CE 的 bulkInsert 多行分支走 **afterBulkInsert（:4200）——无 tap**。bulkUpsert 侧 `insertedDatas.length > 1`（:4202）同走 afterBulkInsert，同样无 tap。与 update 侧（1 行→afterUpdate、>1 行→afterBulkUpdate，两分支均有 tap）**不对称**，代码无注释声明此为有意取舍；实现自述与已知遗留清单均未列此缺口。

**实测复现**（realtime sync `tssxne7sg4jhq6wqy`，delete 策略，镜像 3 行基准）：
- `POST /api/v2/tables/<src>/records` 数组 3 行（bulk-a/b/c）→ HTTP 200，等待 6s → 镜像 `where=(Title,like,bulk-)` **0 行**；日志零新增 enqueued（此前 4 个单行事件恰好 4 个 job：insert/update/bulkUpdate/delete 各 1）。
- 同批 3000 行 bulk seed（T4.1/T4c.1 各 3000）同样零 job；镜像滞留直至手动 resync（全量拉回 3000 行）或其它单行事件。
- 对照：单对象 POST（`{"Title":...}`）1s 内传播 ✓。

**放大面**：前端 grid 粘贴多行、CSV/Excel 导入、v2 bulk API 全部落 bulkInsert——realtime sync 的典型写入形态恰是缺口形态。滞留行无限期不同步（无 markSkipped→无 catch-up；受 E2 影响水位兜底也不可达），直到用户手动 Sync now 或无关单行事件触发别的行刷新。数据不丢（源完好），但 realtime「亚秒级」承诺静默失效且无 UI 提示。

**建议修法**：afterBulkInsert 补 tap（`insertedDataList.map(extractPksValues)` 传 rowIds，与 afterBulkDelete 同形态）；或文档化裁剪并计入已知遗留。注意 afterBulkInsert 也是 webhook 分发位，tap 放在该方法体内 `!this.model.synced` 守卫不变。

## E2（error）— Syncing 窗口内的源事件静默丢失：CAS-miss 标记与补齐/水位拉机制实际不可达

**位置**：`table-sync-realtime.ts` `loadRealtimeTargets`（:87-91 `.where({..., status: TableSyncStatus.Active})`）与 `notifySourceChange`（只对查询结果循环）→ `claimAndEnqueue` 的 CAS（`WHERE status='active'`）→ `enqueueCatchUpIfNeeded`。

**矛盾**：实现自述与 commit message 声称「events landing while a run holds the sync are marked and a watermark catch-up job is enqueued when the run completes」。但 `loadRealtimeTargets` 以 `syncs.status='active'` 前置过滤——**事件到达时正在 Syncing 的 sync 根本不在 targets 里**，循环不会触达它：既不投递、也不走 `claimAndEnqueue→null→markSkippedDuringSync`。标记集合恒空 → processor 每轮结束的 `enqueueCatchUpIfNeeded` 恒早退 → 空 affectedIds 水位 job 永不产生 → **processor 的水位拉分支（`isIncremental && srcLmtCol && watermark`）为活体不可达死代码**（仅单测 mock 可达）。全日志 grep `watermark catch-up` 零命中。任务书范围 2（Syncing 跳过+补齐→最终一致）与范围 3（水位拉/无 LMT 回退/跳过 sweep）在此机制下无法达成。

**实测复现**（对照实验，6007 行大表拉长 resync 窗口）：
- resync 触发后 3s（run 进行中）源插 `midrun2` → HTTP 200。
- 正在 Syncing 的 sync1（tssxne7sg4jhq6wqy）：12:04:23 full-resync 完成（source rows=6007 inserts=3000 updates=3007，扫描早于 midrun2 提交，不含它）→ **无 catch-up 日志** → 轮询 60s+ 镜像 `where=(Title,eq,midrun2)` **恒 0 行**。镜像缺行坐实，直到下次无关事件/手动 resync。
- 对照组 sync2（tssvvxiqo5zsrqbqr，当时 active）：12:04:26 收到同一事件 `enqueued incremental run (insert, 1 ids)` → 镜像2 出现 midrun2 ✓——证明分发链本身工作，缺口精确锁定在「syncing 状态被前置过滤」。
- 附带发现：T4 首轮（3007 行表）midrun-ins 之所以「出现在镜像」，是 resync 全量扫描恰好晚于该行提交而顺带带回——非补齐机制生效，勿据此判 PASS。

**影响**：resync/full-create 窗口随表规模秒~分钟级，窗口内所有源写静默丢失传播；realtime 语义在长跑后不可靠且无自愈。**建议修法**：`loadRealtimeTargets` 去掉 status 过滤（status 放行至 CAS 判定），或对 syncing 的 sync 分支直接 `markSkippedDuringSync`；paused 仍应排除（冻结语义）。修复后 T4/T5 水位路径补一轮活体回归。

## M1（minor）— loadRealtimeTargets 未过滤 mapping role=main

`table-sync-realtime.ts` join 查询仅按 `source_table_id + trigger + status`，无 `mappings.role='main'`。P1–P3 仅有 Main mapping 无实际影响；P4（LinkedShadow/Junction）落地时同一 sync 会因 shadow/junction mapping 重复进入 targets：第二次起 CAS miss 误打 skipped 标记（当轮结束多跑一次无害水位 job）。注释自称「main mappings sourcing this table」，与实现不符。建议补 `.where(role: 'main')` 与注释对齐。

## M2（minor）— claimAndEnqueue 回填 sync_job_id 失败时产生窄双投窗口

`claimAndEnqueue`（:125-158）：`jobsService.add` 成功后若 `sync_job_id` 回滚更新失败走 catch → 释放 status=active，但 job 已入队 → 下一个事件可再 claim 再投 → 同 sync 两 job 并列。CE fallback queue 同进程串行 + upsert 幂等兜底，无数据错误，仅双跑/竞态面。建议：回填失败仅 warn，不回滚 claim（processor 完成时本就会清 sync_job_id）。

---

## 实测通过项（全部活体验证）

**T1 realtime 全链（delete 策略，sync tssxne7sg4jhq6wqy）**：createSync `syncTrigger:'realtime'` → 200，`sync_trigger=realtime` 落库；首跑 full-create 3/3 行；源单行 insert/update（PATCH 单对象 + 数组 bulkUpdate 两形态）/delete（DELETE body 带 Id）→ 每事件恰一个 incremental job、**1s 内**镜像跟随（日志逐条对上：`(insert, 1 ids)`/`(update, 1 ids)`/`(bulkUpdate, 1 ids)`/`(delete, 1 ids)`）。注：v2 单行写不带 `:rowId` 段（PATCH/DELETE 走 body Id）——首测误用 v1 形态产生的假象已排除，非实现缺陷。
**防环**：源写→镜像更新后 sync 状态/水位收敛，无循环放大 job；引擎写被 `!model.synced` 守卫 + skip_hooks 双重抑制（T1.6 + 全程日志无自触发）。API 直接写镜像被拦（readonly 列守卫 `Column "Title" is readonly...`）。
**T2 mark_deleted（tssvvxiqo5zsrqbqr）**：与 delete 策略 sync 共存同源，同事件双投各自按策略执行：源删 r2 → mirror2 `RemoteDeleted=true` + mirror1 行删除 ✓；源重插 → 双镜像复活、flag=false ✓。
**T3 realtime sync 的手动 resync**：POST `/resync` 200 → active，全量拉回（含 bulk 滞留行），重构后的 full pass 聚合管道（pendingInserts/Updates/Deletes + CHUNK 200）数据正确（mirror=source=6007/3007 两轮核对）。
**T5 守卫链/ACL/selected_fields/detach**：镜像删表 400 `Synced tables cannot be deleted`；editor 对 realtime sync 的 resync/freeze 403（写 op 拒）；selected_fields=["Title"] realtime sync 传播 ✓（单行新记录 1s 进镜像）；detach（正确路径 `/table-syncs/:id/detach`）→ `{ok:true}`、`synced=false` 转正、sync 行移除、**后续源事件停止进旧镜像** ✓。P3 顺带修的 Convert 后 grid 瞬空白源码面复核（removeMeta→getMeta(force)→loadViews(force) 时序成立）。
**T6 trigger 校验/paste+realtime**：`syncTrigger:'hourly'` → 400 `Invalid sync trigger: hourly` ✓；paste 模式（sharedViewUrl=uuid）× realtime 组合 → `source_input_mode=paste`、`sync_trigger=realtime`、首跑后单行事件 1s 传播 ✓。
**UI 活体（camoufox session f09p3r1l2）**：向导 step3「Automatically — Changes in the source view sync to the mirrored table within seconds / Manually — Sync only when you click Sync now」双 radio 可见，**Automatically 可选中（checked）**；Create sync 后 modal 关闭、树出现镜像表节点；页面内 JWT 复核新建 sync `tssqdvw2tdzzus7q9`：`trigger=realtime, status=active` ✓。AUTO 解锁（useEeConfig `blockTableSyncAuto=false`，[CE-EE] 标记在位）成立。
**P1/P2 站位**：full-create/full-resync/resync 管道重构后数据正确（两轮大表核对）；守卫链、detach、paste、selected_fields、editor 写拒、未知 trigger 400 抽测全过——覆盖 processor 重构与 createSync 改动的全部触达路径；未触达面（freeze/resume、源列类型漂移、E1 六格、删除流三腿等）由 P2 R1–R4 既有结论继承，本批 diff 未触碰其路径（git show 核对）。

## 质量门

- `npx tsc --noEmit`：**0** ✓
- `npx jest --testPathPattern 'Fork'`：**44/44**（3 suites；与实现基线一致，含 3 个 P3 新增 incremental 用例 + unknown-trigger 用例）✓
- Vite URL 编译门：改动 SFC `CreateNewSync.vue`/`SyncMenuOptions.vue` 均 **200** ✓；:3000 Nuxt 200、:8080 API 401（正常鉴权面）✓

## 裁定建议

E1、E2 必修（连击清零重开）。E2 修复（loadRealtimeTargets 放行 syncing 至 CAS 层）顺带使水位拉分支活体可达，建议修复轮补：水位拉窗口实测（含 30s 重叠）+ 无 LMT 列回退全量 + 部分拉取不 sweep 三项活体（当前仅单测覆盖）。E1 修复后补 bulk insert 传播活体。M1 随 E2 顺手修（同一查询）；M2 可记 backlog。

—— lane 2 / f09p3r1l2 / 2026-09-20
