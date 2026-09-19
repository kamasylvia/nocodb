# R1 P3 lane4 — 引擎重点路（incremental/realtime/CAS 补齐/水位/防环）

**结论：3 error + 5 minor**

- 审查员：lane4（f09p3r1l4-*）；基线 f6a9314b5e；:8080 P3 dist 只读实测；源码只读审查。
- 质量门：`tsc --noEmit` exit 0；jest Fork 桶 44/44（3 套件全过）；Vite URL 编译法 4/4 = 200（CreateNewSync.vue / SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts）。
- 活体脚本与原始输出：`.work/ee-ce/f09p3r1l4-run1.sh`～`run6.sh`、`f09p3r1l4-dbq.sh`，结果 `/tmp/f09p3r1l4-results*.txt`；后端日志 `/private/tmp/nocodb-internal.log`（共享实例，含他路流量，按 sync-id 归因）。
- 测试数据：全部 `f09p3r1l4-` 前缀，sync/base 已删（残留清点 0）；账号 f09p3r1l4-api 保留供后续轮次。

---

## 0. PASS 面（先立后破）

| 项 | 证据 |
|---|---|
| realtime createSync 200、sync_trigger=realtime 落库、manual/realtime 外 400 | run1 §3 / run3 A1 / spec「rejects an unknown sync trigger」 |
| full-create：建镜像 synced=true、源行全量镜像（含"建 sync 前已删行不镜像"） | run5 V1 镜像初态 3 行；run4 P2 初态正确跳过已删 a2 |
| **incremental affectedIds 按 pk 拉：insert/update/delete 三类事件亚秒级跟随** | update ~0s（run3 A2、run5）、insert ~300ms（run1 §4）、**active 态 delete ~0s（run6）**；processor 日志 `inserts/updates/deletes` 计数与操作一一对应；消失 id 按 on_delete_action 正确删/标（spec 437/461 两用例 + run6 活体） |
| **防环守卫成立**：①镜像表 allow_sync PATCH 400（创建面阻断级联）；②引擎写 bulkInsert/bulkUpdate 走 skip_hooks 完全跳过 after*（`insert.ts:655`、`BaseModelSqlv2.ts:4731`）；③bulkDelete 无 skip_hooks，靠 tap 的 `!model.synced` 守卫拦截（`BaseModelSqlv2.ts:5643/5773/5815/5974/6119`） | run1 §7：allow_sync HTTP 400 + 静默窗 8s 零 job churn；全程多轮零 "run failed"、零自持入队 |
| CAS 跳过本体：paused 窗口内事件不泄漏 | run5 V2：freeze→status=paused 实证，窗口内 upd/del/ins 三写全 200，镜像 3 秒后零变化 |
| manual resync 对 realtime sync 可用且为唯一修复路径 | run1 §9 resync 200；run5 V4 resync 200 后镜像完全收敛（a1-edited 补入、frozen_ins 补入、a2 RemoteDeleted=true） |
| AUTO 解锁 + 向导 Automatically 档（源码面） | `useEeConfig.ts:167 blockTableSyncAuto=false`（[CE-EE] 标注）；`CreateNewSync.vue:370` 单选 + `:159 syncTrigger` 提交 |

引擎主通路（tap → notifySourceChange → CAS claim → incremental job → affectedIds 按 pk upsert/delete）**在 active 态下工作正确且亚秒级**。问题集中在"非 active 窗口的事件一致性"与"空 affectedIds 水位分支"——见下。

---

## 1. Error（必修）

### E1 — Syncing/paused 窗口的事件被静默丢弃，"CAS miss → 补齐水位 job"机制是死代码

- **代码**：`helpers/table-sync-realtime.ts:80-98` `loadRealtimeTargets` 查询过滤 `status = 'active'`（:90）；`notifySourceChange` :175-176 对空 targets **静默早退**，根本走不到 :119-123 的 CAS claim，也就永远到不了 :188 的 `markSkippedDuringSync`。marker 唯一可设置的路径是 SELECT 与 UPDATE 之间的微秒级竞态、以及入队失败回滚分支——实际不可达。
- **设计承诺**（GOAL-STATE P3 定案 / impl-report §1）："Syncing 中投递跳过 → 当轮结束后补齐水位 job → 数据最终一致"。实现与设计不符。
- **活体证据**：
  1. run5（决定性）：真 paused 窗口内 update a1 / delete a2 / insert frozen_ins（三写全 200）→ resume → 仅 resume 后的 a3 事件入队（日志仅 1 条 `(update,1 ids)`）→ 镜像终态 `[a1, a2, a3-edited]`：**a1-edited（update 类）、frozen_ins（insert 类）、a2 ghost（delete 类，RD=false）三类窗口事件全丢**，无任何补齐 job。
  2. 全服务端日志（P3 dist 起至今）：增量入队 40+ 条，**`watermark catch-up run` / `catch-up enqueue failed` 零条**——补齐从未发生过。
  3. run2 风暴旁证：15 连发 insert，仅 7 个入队（其余事件落在首 job 的 syncing 窗口内被 lookup 丢弃），8 行缺失直至手动 resync。
- **影响**：任何长于事件间隔的 run（全量 resync 必然）期间、以及 paused 期间的源变更被**静默丢失**，镜像与源发散，无任何状态可见（status 仍 active、无 last_error），仅手动 Sync now 可收敛。
- **修复建议**：`loadRealtimeTargets` 去掉 status 过滤（保留 sync_trigger=realtime；如需限制可 `status IN (active, syncing)`，paused/error 丢弃是合理语义但应与设计文档对齐），让 CAS claim 真正做仲裁；marker 路径随之激活。见 E2——补齐 job 本身也需先修。

### E2 — 空 affectedIds 水位拉分支不可用：LMT 系统列的 `(col,ge,<date>)` where 被解析器 422 拒绝

- **活体证据**：对含已更新行（物理 updated_at 有值，见 E3）的源表逐形态探测：`(UpdatedAt,ge,2026-09-19T16:00:00.000Z)`、`(UpdatedAt,ge,2020-01-01)`、`(UpdatedAt,le,2099-01-01)`、空格格式 `2026-09-19 16:00:00` —— 全部 **HTTP 422 `{"msg":"'<value>' is not supported."}`**；仅 `(UpdatedAt,is,null)` 200。
- **代码根因**：where 串解析器把裸日期读作 sub-op 并拒绝——`src/mcp/descriptions.ts:55` 官方自述："A bare date with no sub-operator is read as the sub-operator and rejected"。processor 水位分支（`table-sync.processor.ts:327-348`）拼的恰是 `(LMT,ge,ISO)` 形态（:338 `where: (${srcLmtCol.title},ge,${watermark})`）→ 内部 `list()` 走同一解析 → 抛 NcError（job→Error）或丢过滤器（变成无 sweep 全表拉），无论哪种都不是设计的"增量水位拉"。
- **单测盲区**：spec :488 水位用例 mock 了 `srcBaseModel.list` 直接返回行，where 语义从未被测过。
- **影响**：补齐水位 job 若被触发（当前被 E1 掩护）必然 0 增量或直接 Error；`syncNoUpdatedAtColumn` 引导语义失真。
- **修复建议**：水位查询不要走 LMT where 字符串——用 knex 直查（`qb.where(col, '>=', watermarkUTC)` 绕过 FieldHandler），或改用 `updated_at` 物理列的时间戳比较；并补"真实 where 语义"的单测。

### E3 — 插入行物理 updated_at = NULL：水位语义天然看不到 insert 类事件

- **DB 实证**（psycopg 只读探针 `f09p3r1l4-dbq.sh`，nocodb-dev，schema `ppt3trsql55h1a0`，列型 `timestamp without time zone`）：
  - `a1-edited`（update 过）：`updated_at = '2026-09-19 16:49:33'`（naive UTC，真实 UTC 16:49:33 ✓）
  - `a2`（从未 update）：`updated_at = NULL`
- **代码**：插入路径显式置 NULL（`BaseModelSqlv2.ts:9501` 分支 `isInsertData ? null : this.now()`）；仅 update 内联写入。
- **影响**：watermark 拉取（`(LMT,ge,wm)` 即使按 E2 修好）**永远拉不到"插入后未再更新"的行**——而 realtime 场景窗口内丢失的恰恰多为 insert。加上 delete 行从表中消失（水位 pull 天然不可见），**水位补齐对 insert/delete 两类事件结构性失效**，仅能覆盖 update。
- **修复建议**：与 E1 一并修——marker 携带被跳过的 rowIds/事件类型（如 `Map<syncId, {upserts:Set, deletes:Set}>`），补齐 job 以 `affectedIdsBySource` 精确补投（upsert 走 readByPk、delete 走 on_delete_action），不再依赖水位；水位仅作为 update 类的兜底。impl-report「已知限制」未覆盖此三点，应更新。

---

## 2. Minor

- **M1** `afterBulkUpdate` 的 bulkUpdateAll（count 形态）不 tap（`BaseModelSqlv2.ts:5966` 注释声明选择）→ 网格"按过滤器批量更新"不实时传播，无 marker 无补齐，直到下次全量。修 E1 时顺手覆盖（bulkUpdateAll 知道命中行数>0，可投空 affectedIds 补齐）。
- **M2** 补齐标记为单进程内存态，多 worker 部署丢补齐——impl-report 已文档化；CE fallback 同进程，接受为 fork 限制（维持观察级，不计修）。
- **M3** 可观测性弱：claim miss（notifySourceChange :187-188）与补齐 claim miss（enqueueCatchUpIfNeeded :247-250）均静默无日志；`if (jobId)` 才打日志，jobId 空串时入队了也不留痕。修 E1 时一并加 warn/debug。
- **M4** tap 为 fire-and-forget 且与业务共享 knex 池/事件循环：共享实例高并发下 tap 实际延迟达 1.5-2 分钟（run2：12:08:55 风暴事件的 7 条入队日志落 在 12:10:42-46）。生产单租户不至如此，但"亚秒~秒级"承诺在负载下无上界；后续可评估 tap 去重/专用连接。观察级。
- **M5** 测试缺口：realtime createSync 正路径（impl 自述）、补齐 marker 全链、水位 where 真实语义均无单测。修 E1-E3 时应随修随补。

---

## 3. 方法学注记（供裁决参考）

- 本轮前三次脚本（run1-run4）探针自身有缺陷（jq `// empty` 对 false 假值、v2 无 per-record PATCH/DELETE 路由导致 404 静默、DELETE 需标量 Id body、run4 jqget 未定义致 freeze 空转、`jq '.list|length'` 在错误响应上输出假 0、BSD `head -n -1`），已逐一修正；**E1/F1/F2 的终判证据以 run5（探针含 HTTP 码 + freeze 后 status 验证 + 全量镜像 dump）为准**。run3 的 C/D 段结论（a2 GONE 等）作废，以 run5 替代。
- 水位 where 的"0 hits"初判是 422 错误响应假象，最终以 HTTP 码 + dbq 物理列读数定案（E2/E3）。
- 共享 :8080 有多 lane 并发流量，日志按 sync-id 归因；未对本 lane 结论构成依赖。
- 未覆盖（他路站位）：UI 活体（向导双模式三档/树菜单/删除流）、ACL 十一端点、paste 模式矩阵——非本 lane 焦点。
