# F09 P3 R3 lane3 审查报告（安全审计重点路，2026-09-20）

**结论：PASS — 0 error + 3 minor**

- 审查员：lane 3（账号 f09p3r3l3-api / f09p3r3l3-ed / f09p3r3l3-ui，UI 与 API 账号分离；camoufox session `f09p3r3l3`，已关闭）
- 基线：5d25acfc51（R2 修复批）= HEAD，tree 干净（仅 .work 流程文件）；:8080 = pid 75970（02:21 起）运行 `~/.nocodb-run/packages/nocodb/dist/main.js`（mtime 02:10 < 进程启动），dist 内 grep 到 R2 修复特征串（`claim missed` ×2、`enqueued watermark catch-up run`、`propagated column type change`）——确为修复后 dist，与 HEAD 同源。全程零构建/零重启/零 psql。
- 活体脚本：`.work/ee-ce/f09p3r3l3-run1.sh` / `run1b.sh` / `run2.sh` / `run2b.sh`；结果 `/tmp/f09p3r3l3-results1{,b,2,2b}.txt`；后端日志 `/private/tmp/nocodb-internal.log` 按 sync-id 归因。

---

## 0. PASS 面

### 0.1 R3-1 窗口 delete 收敛（本轮核心，R1'/R2 四路同判 E 族回归）

| 场景 | 实证 |
|---|---|
| **paused 窗三写**：freeze → PATCH/DELETE/POST 三写全 200 → resume 200 → 日志 `enqueued watermark catch-up run` ×1 → catch-up run `[incremental]: source rows=3 inserts=1 updates=2 deletes=1` | **w-upd Qty=42 追平、w-ins 进镜像、w-row2 ghost 物理消失（查询 0 行、RemoteDeleted=''）**，镜像 3 = 源 3。R1 lane4 run5 / R2 四路 ghost 场景零复现 |
| **Syncing 窗三写**（800 行表 resync 中 PATCH/DELETE/POST 全 200）→ catch-up 入队 ×1 → run `[incremental]: source rows=800 inserts=1 updates=799 deletes=1` | c-upd Qty=555 追平、c-ins 进镜像、被删行恰扫掉 1 行，镜像总数 800 = 源终态 800 |
| **幂等复跑**：连续 resync 两轮 | 800/800 一致，零重复行；本 lane 全部 sync 零 `run failed` |

修复形态源码核验：processor `applyFullSync` 中无 ids 增量（catch-up）fall through 到全量 pass（`table-sync.processor.ts:320-408`），消失扫描（sweep）在 full pull 观测完备时执行；带 ids 的增量路径仍无 sweep（部分拉取不误删语义保持）。resume 端点接 `enqueueCatchUpIfNeeded`（`table-syncs.service.ts:1195-1197`）。

### 0.2 R3-2 Convert 确认弹窗（UI 活体，camoufox f09p3r3l3）

树菜单 `Convert to regular table` → 确认弹窗出现（dialog 含 `table-sync-convert-cancel` / `table-sync-convert-confirm` 双钮）；**Cancel** → 弹窗关、syncs=1 保持；**Esc**（弹窗开 → Esc）→ 弹窗关、syncs=1 保持；**Convert** → 弹窗关、syncs=0、镜像表 `synced=false`、10 列 + 2 行数据完整保留。全链符合任务书验收。

### 0.3 质量门

`tsc --noEmit` exit 0；jest Fork 桶 3 suites **44/44**；Vite URL 编译法 **4/4 = 200 text/javascript 真 transform 产物**（CreateNewSync.vue / SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts）。AUTO 解锁回归：`useEeConfig.ts:167 blockTableSyncAuto=false` 源码 + Vite 产物双确认。

### 0.4 安全五项

1. **realtime tap 防环（✓）**：七处 tap（afterInsert/afterBulkInsert/afterDelete/afterBulkDelete/afterBulkRestore/afterBulkUpdate/afterUpdate）grep 实证 7/7 同守卫族 `!this.model && !this.model.synced` → tap 整段不执行；引擎 dest 写携 `skip_hooks:true` 双层门（insert.ts:655 / delete.ts:769）。活体：源数组 POST 2 行 → 恰一 tap `(insert, 2 ids)` 亚秒传播进镜像；单行 update/delete 传播（mark_deleted 置 `RemoteDeleted=true`）；静默窗 8s 零 churn（日志 7→7、镜像稳定 5 行）；paste sync 收敛后零自激（4→4）；级联源封死——mirror 作源 createSync 400（"Source base must be a different base"）+ mirror view `allow_sync` PATCH 400。
2. **affectedIdsBySource 注入面（✓）**：构造点仅 `claimAndEnqueue`（ids 来自 `extractPksValues` 真实 DB 主键）；HTTP 侧 `updateSync` body 白名单解构（title/on_delete_action/selected_fields[camelCase 别名]）、resync/freeze/resume/detach 无 body、`enqueueSyncJob` 只传 syncId+mode——无任何端点把请求体透传进 jobData。
3. **paste 凭据面（✓）**：错误密码 400 零泄露；无密码仅回 `{passwordProtected:true}`（响应 keys 实证恰此一项）；正确密码解析坐标；paste+realtime 建成并 full-create 4 行 + 源插行 realtime 传播（p-ins 进镜像）；getSync/listSyncs 响应 grep 无 `source_uuid`/`source_password`/明文密码残留；paste resync 200（不复验 hash 为已知遗留）。
4. **detach ACL（✓）**：controller 端 `@Acl('tableSyncDelete')`（`table-syncs.controller.ts:193`）；editor 对 createSync/PATCH/resync/freeze/resume/**detach**/DELETE 全 403，sync title 未被改动；service 层 Syncing 状态守卫在位。
5. **`(RemoteId,eq,${remoteId})` where 插值复查（维持防御性 minor → M3）**：R2 修复批未触碰该形态；构造点仍仅 processor 内部（remoteId=源表 PK），HTTP 不可控；活体 `(RemoteId,eq,8)` 恰 1 行正常匹配。外部源 text PK 场景理论注入面维持 R2 M4 结论。

### 0.5 站位回归（本 lane 抽检）

camelCase `selectedFields` PATCH 生效（=Title）+ 增列恢复（=Title,Qty）——R2-4 修复保持；mirror 拒写守卫链五形态（单行/数组 insert 400、bulkUpdate 400、bulkDelete 422、v1 bulkUpsert owner 400）。

---

## 1. Minor（3）

- **M1 文档注释腐化（R2 修复批引入，随下次改动顺手清）**：`table-sync.processor.ts` L28-32 头注释现为自相矛盾句——"…falls back to the full pass (upsert + sweep) **and skips the disappearance sweep**"（新语义 + R1 旧尾巴拼接，代码实际 sweep）；L53-55 job() 注释、L227-230 拉取形态注释同残留 "WITHOUT the disappearance sweep"。`table-sync-realtime.ts` L102-104 claimAndEnqueue doc 仍写 "falls back to the RemoteUpdatedAt watermark pull"（水位机制 R1 已删）、L34/L227-229 "watermark catch-up" 措辞残留、L279 死行。与 R2 lane4 M2/M3 同族——spec 名已正名但三处实现注释未同步。
- **M2 zh-Hans 缺 `labels.convertToRegularTable` 键**：`lang/en.json:1890` 有、zh-Hans.json 0 命中——中文 UI 的 Convert 弹窗标题/确认钮回落英文。化妆品级，建议补翻译。
- **M3 `(RemoteId,eq,…)` 插值维持防御性 minor**：见 0.4-5，R2 M4 延续未修（本轮确认不可达 HTTP，风险不变等级不变），建议维持 knex 参数化 backlog。

**观察级（不计修）**：① `afterBulkRestore` tap 仍为 EE-gated 死路径（CE 无调用方），守卫族一致、前向兼容，R2 M1 维持；② 窗口 catch-up 全量 pass O(N)/次成本维持（R2 lane4 M1 同族，本次 800 行表两连跑无感）；③ run1 E3 复查本 lane sync 零 `run failed`。

---

## 2. 方法学注记（供裁决）

- **run1 两 FAIL 为本 lane 探针缺陷，非产品回归**：800 行造数循环 `for c in 1..8` 每次 POST 同一 CHUNK（c-0000..c-0099），源表实为百行标题 ×8——假 ghost（c-0006 ×7 是源里真实存在的 7 个同标题行）+ 假缺失（c-0100 本不存在）。run1b 全量落盘核对定案：mirror where 探针与实际 title 分布逐一相符（api=实际 7/0/0/1/1）、镜像终态与源完全一致、catch-up `deletes=1` 恰扫被删实例。**终判以 run1 A 节（paused 窗小表）+ run1b B' 节（Syncing 窗 800 行）为准**；教训：批量造数循环体内必须重建 chunk（防后续轮把同形态假象误判成 sweep 误删/漏删）。
- macOS BSD `date` 无 `%3N`、zsh 无 `EPOCHREALTIME`——run2 时戳两处报错（仅耗时注记丢失，断言不受影响）。
- UI 会话两次意外登出（JWT 疑似短时失效），重登后闭环全部断言；Esc 路径首测因菜单未开而空转，已按「开菜单→点 Convert→确认弹窗开→Esc→弹窗关 + syncs=1」严谨重测通过。
- 共享 :8080 有他 lane 并发流量，全部结论按本 lane sync-id 归因，零依赖他路数据。
