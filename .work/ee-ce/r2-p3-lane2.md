# F09 P3 R2 修复回归审查报告 — lane 2（2026-09-20）

**结论：1 error + 3 minor**

- 审查员：lane 2（f09p3r2l2-*；camoufox session f09p3r2l2）
- 基线：27efcca491（R1 修复批，`fix(nocodb,nc-gui): F09 P3 R1 — bulk-insert tap, syncing-window dispatch, catch-up rework`）；HEAD = 27efcca491，修复后无代码变更
- :8080 = pid 50994（01:27AM 起，晚于 dist mtime 01:06），dist 内 grep 到 `markSkippedDuringSync` / catch-up / afterBulkRestore 特征 12 处——确为修复后 dist；全程零构建/零重启/零 dev-backend 调用
- 质量门：`npx tsc --noEmit` exit 0；jest Fork 桶 3 套件 44/44；Vite URL 编译法 CreateNewSync.vue / Sync/Table/Form.vue / Sync/index.vue / useEeConfig.ts / useTableSync.ts 全 200
- 测试数据：`f09p3r2l2-` 前缀，src base（1506 行）/dst base（镜像+detached paste 表）/probe base 已删（200×3），DB 复查 live bases=[]、nc_table_syncs 残留=0；camoufox session 已关。账号 f09p3r2l2-api / -editor / -ui 保留供后续轮次（R1 lane4 先例）

---

## ERROR 1：Syncing/paused 窗口内 delete 类事件不补齐——catch-up 全量 upsert（无消失扫描）结构性不覆盖删除，窗口删除在镜像滞留 ghost

**现象（两轮独立实证）**：
1. **paused 窗口**（T2，lane4 run5 同场景）：freeze → 源三写（insert `paused-ins` / update r2→`r2-paused-edit` / delete r3，全 200）→ resume → resume 自动触发 `enqueued watermark catch-up run`，catch-up run 日志 `[incremental]: inserts=1 updates=5 deletes=0`——insert/update 全追平，**r3 ghost 留存镜像**，直至手动 resync（full sweep deletes=1）清除。
2. **Syncing 窗口**（T3，1500 行大表 resync 中并发三写，status=syncing 实证）：resync full run（deletes=1 只清掉 full pass 扫描前的 r3 ghost）→ 窗口 delete 的 bulk-a 由 catch-up（`updates=1506 deletes=0`）漏过 → **bulk-a ghost 留存**，再次手动 resync（deletes=1）才清除。

**根因**：R1 修复把 catch-up 从水位拉改为「无消失扫描的全量 RemoteId upsert」（processor :321-343），upsert 语义天然只含 insert/update——**窗口内 delete 事件既不在 affectedIds 拉取路径（claim miss 时事件 ids 未随 marker 保存），也不在 upsert pass 路径（无 sweep）**。marker 仍是裸 `Set<syncId>`（table-sync-realtime.ts:45），不携带事件类型/行 id，catch-up 无法对被跳过的删除应用 on_delete_action。delete 类是 E-syncing「跳过→补齐」链路上唯一无落点的分支。

**对照验收口径**：本轮任务书 R2 重点 2 原文——「**paused 窗口**事件 → resume 时自动补齐（lane4 run5 场景：paused 三写 → resume → **全部追平**）」。R1 判 error 的 lane4 run5 症状即含「a2 ghost（delete 类）」；R2 修复后同场景回归 ins/upd 追平而 delete ghost 复现，验收场景未完全达成。commit message「without the disappearance sweep (idempotent, always correct)」声明了 upsert 的幂等正确性，但未声明放弃 delete 补齐，GOAL-STATE 定案「Syncing 中投递跳过（当轮跑补齐）」未区分事件类型。

**后果**：resync/Syncing 窗口（大表以秒~分钟计）与 paused 窗口内的源删行在镜像**静默滞留**：delete 策略下显示已删数据；mark_deleted 策略下更糟——源已删而镜像行 RemoteDeleted=false 仍作正常数据呈现。无日志、无状态可见，唯一恢复路径是手动 resync（本次实测有效）。自动一致性承诺对 delete 类失效。

**修复方向**：marker 升级为 `Map<syncId, { upserts: Set, deletes: Set }>`（claim miss 时按事件类型记 id），catch-up 在全量 upsert pass 后对 `deletes` 集逐 id 走 `readByPk` 判空 → `applyDeletePolicy`（复用 affectedIds 拉取分支既有逻辑，R1 已验证该分支 delete 语义正确）；或 marker 记录 delete ids 后投一个 affectedIds=deletes 的增量 job。同步更新 spec :488 用例名与 GOAL-STATE 定案描述。

---

## MINOR

- **M1** spec 用例名与断言体矛盾：`table-syncs.Fork.spec.ts:488` 名为「incremental run without ids falls back to the full pass **with sweep** (R2 lane4 E1')」，用例体却断言 `bulkDelete not.toHaveBeenCalled()`（无 sweep，与实现一致）。名字是水位拉时代残留，误导后续维护者对 catch-up 语义的理解。
- **M2** R1 修复面零新增单测（jest 仍 44 = R1 基线数）：E-bulk tap、paused 窗口 marker 置位、resume 补齐、camelCase selectedFields alias 均无用例。R1 lane1 修复方向明确要求「修复时应补并发时序用例」、lane4 M5 要求「随修随补」，未落实；本轮全部依赖活体实测覆盖。
- **M3** R1 lane4 M3 可观测性未随 E-syncing 一并修：claim miss（table-sync-realtime.ts notifySourceChange `if (jobId === null)` 分支）与 catch-up claim miss（enqueueCatchUpIfNeeded else 分支）仍静默无日志。窗口事件丢失（尤其本报告 ERROR 1 的 delete 类）在日志层零痕迹，排障只能靠对照后端全量日志按 sync-id 归因。

---

## PASS 面（R1 修复主项回归 + 站位全继承，全部实测）

**E-bulk 修复（R1 ERROR 2）**：realtime sync 源表数组体 POST 3 行（v2 批量/paste-CSV 同路径）→ 镜像 t+1.5s 全数到达（POST 0.15s 返回），日志单一 incremental job `inserts=3`；规模复测 1500 行（3×500 数组分批）全量传播（镜像 1507 = 源 1506 + 1 ghost，fill-1499 抽查在位）✓
**E-syncing 修复——激活面（R1 ERROR 1）**：`loadRealtimeTargets` 已去 status 过滤（保留 sync_trigger=realtime + role='main'，源码审 :87-104）：paused 窗口事件 claim miss → marker 置位 → **resume 自动触发 catch-up run**（日志实证，API resume 与 UI resume 各一次）；Syncing 窗口事件 → run 结束自动 catch-up（resync full run 后日志实证）。「死代码」复活 ✓
**E-watermark 修复（lane4 E2/E3）**：catch-up 不再拼 `(LMT,ge,ISO)` where（processor 无 watermarkStart 引用），全量 upsert pass 跑通零 422 零 job Error（日志 `[incremental]: ... updates=1506` 实证）；updated_at=NULL 的纯插入行（paused-ins / fill-*）经 catch-up 可达（inserts 计数实证）✓
**camelCase alias（R1 MINOR 1）**：PATCH `selectedFields:["Title"]` 200 且落库生效，resync 后镜像 Qty 列 drop；加回 `["Title","Qty"]` 后 Qty 列回归且值真实进数（fill-5 Qty=5 双侧一致）✓
**P3 主链站位**：full-create 3 行镜像；active 态单行 insert/update 亚秒跟随；1500 行 filler 后镜像与源 1506=1506 收敛；manual resync 对 realtime sync 可用且为 ghost 唯一清理路径（deletes 计数与 totalRows 双证）✓
**守卫链**：镜像 insert/update 400（readonly 列守卫）、delete 400 族 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`、删镜像表 400「Synced tables cannot be deleted」；守卫写后静默窗日志 0 条（零自激）✓
**paste 模式 + realtime**：uuid 分享凭据 `sourceInputMode=paste` + `syncTrigger=realtime` 建成（mark_deleted 策略），1506 行全量到位，窗口外源 insert 6s 进镜像且 RD=false；同事件 fan-out 双 sync（browse+paste 镜像同时在数）✓
**多 sync 分发/防环**：全程无自持入队、无 run failed、无双跳传播 ✓
**trigger 面**：`syncTrigger:'hourly'` 400「Invalid sync trigger」✓
**ACL**：editor 账号对 table-syncs 十端点（list/get/create/update/delete/resync/freeze/resume/detach/source-schema）全 403 ✓
**类型漂移**：源 Qty Number→SingleLineText 后 resync，镜像列型跟随（bigint→text），日志「propagated column type change」✓（已还原）
**detach**：200、镜像 synced=false、转正可写（insert 200）、sync 行消失 ✓
**UI 活体**（camoufox :3000，UI 专用账号）：镜像表 New record disabled（synced UI 守卫）；树菜单 active 态全 4 项（Sync now/Pause sync/Convert to regular table/Delete sync），UI Pause → paused、菜单三态变体（Resume sync）、UI Resume → 自动 catch-up（`inserts=1 updates=1507`，窗口写入追平）、UI Delete sync → 确认弹窗 → sync 行消失（列表=[]）✓

**afterBulkRestore tap**：源码审通过（BaseModelSqlv2.ts :5693-5706 同守卫族 tap，数组/单条两形态）——CE 无 row-restore HTTP 路径（trash restore 属 EE 树），活体不可达，如实声明。

## 方法学注记

- 本实例 xc-auth 头认证（Bearer 401）；注册账号默认 org-level-viewer + workspace-level-no-access，需 super admin（首户 f01e2e@ce-ee.local）提权 org+workspace 两级 creator 方可建 base（userUpdate 的 org role 不级联 workspace，两级都要提）。
- UI 与 API 同账号互踢：每次 signin 滚动 token_version 使对侧 JWT 失效（两轮 401 实证）——任务书「UI/API 账号分离」纪律的机制根源，本轮已分账。
- 共享实例日志含他路流量，结论按 sync-id `tssx8acltw8z0mbqc` 归因；DB 探针全程只读事务、硬编码 nocodb-dev。
- 未覆盖：多 worker 部署下内存态 marker 丢失（单实例无法构造，维持 R1 已知限制）；editor UI 侧 gate 卡（API 403 已验，UI 复核省略）。
