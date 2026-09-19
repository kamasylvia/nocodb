# F09 P3 R2 lane1 审查报告（2026-09-19）

**结论：1 error + 2 minor**

- 审查员：lane 1（f09p3r2l1-* / camoufox session f09p3r2l1）
- 基线：27efcca491（R1 修复批，即 HEAD）；修复面 = BaseModelSqlv2.ts / table-sync-realtime.ts / table-sync.processor.ts / table-syncs.service.ts（`git show 27efcca491 --name-only` 核实，无其他 packages 变更）
- :8080 = pid 50994，启动 01:27:58 > dist mtime 01:06（`~/.nocodb-run/packages/nocodb/dist/main.js`），dist 内 grep 特征 `markSkippedDuringSync`×7 / `enqueueCatchUpIfNeeded`×5 / `selectedFields`×18 —— 确为修复后 dist；全程零构建/零重启
- 测试数据：`f09p3r2l1-` 前缀。syncs ×3 DELETE 200（UI 建的第 4 个已被 UI 删除流删掉，复查 404）、src/dst 两 base DELETE 200、bases 列表无残留；DB 复查 `nc_table_syncs` title LIKE 'f09p3r2l1%' = 0 行、pg 表名 LIKE 'f09p3r2l1%' = 0。测试账号 f09p3r2l1-api / -ui / -ed 保留（历史轮同例，供后续轮复用）

---

## ERROR 1：窗口内 delete 类事件不被 catch-up 补齐——「全部追平」的 delete 腿结构性缺失（镜像 ghost 静默漂移）

**修复形态与验收口径的缺口**。R1 两 error 族中 insert/update 腿均已修复且有活体（见 PASS 面），但 catch-up 被重写为「无消失扫描的全量 upsert」（`table-sync.processor.ts` incremental 空 affectedIds 分支），对 **delete 类窗口事件结构性无处理**：源行已消失 → `srcBaseModel.list()` 拉不到 → upsert 不触碰该镜像行 → 无 sweep 不删/不标 → ghost 留存。无日志、无状态可见，唯一恢复路径 = 手动 Sync now（full sweep）或同 id 的后续 realtime 事件。

**活体证据（两例）**：
1. **paused 窗口（任务书明列验收场景，lane4 run5 复刻）**：freeze → 源 delete r2（200）→ resume → 日志 `enqueued watermark catch-up run job9vsdtxd19k22me` → `inserts=0 updates=12 deletes=0` → **镜像 r2 仍在（RD=false），源已无此行**。update/insert 两腿同窗口均追平（`inserts=1 updates=13`），唯独 delete 腿丢。
2. **Syncing 窗口（普通连写场景，无需人为构造）**：源 insert fan 行后 ~100ms 内 delete → delete 事件落在两 sync 各自 incremental run 的 syncing 窗口 → markSkipped → 后续 catch-up `updates=12 deletes=0` → delete 策略镜像与 mark_deleted 策略镜像**双双保留 fan 行 ghost**（RD=false）。

**对照**：任务书 R2 重点 2「paused 三写 → resume → **全部追平**（lane4 run5 场景）」——lane4 run5 的丢失清单明确含 delete 类（a2 ghost）；R1 lane4 修复建议「marker 携带 rowIds/事件类型精确补投（delete 走 on_delete_action）」未采纳，commit 自述「the RemoteId-keyed upsert is idempotent, so a full pass is always correct」对 delete 不成立。mark_deleted 策略同样中招（窗口内软删行 list 不可见，RD 不置位）——与 E1 同根，不另计。

**影响**：realtime incremental run 自身窗口为秒级但始终存在；paused 窗口可无限长；手动 resync 长窗口同路径。窗口内删除静默丢失 = 镜像与源发散，用户无任何可感知信号。

**修复方向**：skipped 标记携带事件类型（如 `Map<syncId, {upsertIds, deleteIds}>`），catch-up 对 deleteIds 按 on_delete_action 补处理（复用现有 affectedIds 分支的 `applyDeletePolicy`）；或 catch-up 保持 upsert-only 但对「镜像有、源 list 无」的行在**全量拉取完成后的本轮上下文内**按策略兜底（等价于一次性受限 sweep——需论证与「partial pull 不误删」约束的相容性）。

## MINOR 1：`watermarkStart` 成死代码

processor 弃用水位拉后（本批），`table-sync-realtime.ts:280` 的 `watermarkStart` + `WATERMARK_OVERLAP_MS` 全仓零调用（spec 亦不引用）。建议删除或注明保留原因。

## MINOR 2：陈旧注释/用例名残留（行为正确，文档失真）

- `table-sync.processor.ts` run 方法头注释仍写「or the RemoteUpdatedAt watermark pull (catch-up)」——该 pull 形态本批已删除；
- spec 用例名「incremental run without ids pulls the LastModifiedTime watermark and skips the sweep」（`table-syncs.Fork.spec.ts:488`）——断言已改为无 where 全量 upsert（正确），仅名陈旧，易误导下轮审查。

---

## PASS 面（全部实测通过）

**质量门**：`npx tsc --noEmit` exit 0；jest Fork 桶 44/44（3 套件）；Vite URL 编译法 4/4 = 200（CreateNewSync.vue / **SyncMenuOptions.vue（正确路径 components/dashboard/TreeView/Table/）** / useEeConfig.ts / useTableSync.ts）。

**E-bulk 修复（活体）**：源表数组 POST 2 行（v2 批量标准形态）→ 日志 `enqueued incremental run (insert, 2 ids)` → `inserts=2` → 镜像 3→5 行，**0.59s**。R1 症状（零传播零日志）零复现。

**E-syncing 修复（活体）**：8 连发快速 insert（R1 lane4 run2 同型场景，当时 15 发丢 8）→ 镜像 <1s 收敛 13 行**零丢失**；日志完整呈现修复链：首事件 claim（`insert, 1 ids` → `inserts=1`）→ 后续事件落 syncing 窗口 → `enqueued watermark catch-up run` → catch-up `inserts=2 updates=6`；catch-up 自身窗口套住的剩余事件再 markSkipped → 再一轮 catch-up（`inserts=3 updates=9`）接力收敛——补齐机制真实可达且幂等。

**E-watermark 修复（活体）**：catch-up 为无 where 全量 upsert，纯插入行（物理 updated_at=NULL，DB 侧既有事实）经此路径进镜像（多轮 catch-up `inserts` 计数为证）；全程零 422、零 `run failed`。422 源（`(LMT,ge,ISO)` where）已从代码移除。

**resume 补齐**：paused 窗口 update/insert 两腿 resume 后全追平（`inserts=1 updates=13`）。

**camelCase selectedFields（R1 MINOR 修复回归）**：PATCH `{selectedFields:[...]}` 200 + 落库（非 no-op）；减列 resync 后镜像 Qty 列真实 drop；增列（dx）进 selectedFields 后 resync 建新列（readonly=true）且新值进镜像。

**多 sync fan-out + 双策略**：单源插入事件分发至 delete 策略与 mark_deleted 策略两 realtime sync（日志各 1 条 enqueued、各 `inserts=1`）；active 态 bulkDelete 事件 → delete 策略镜像删行（`deletes=1`）、mark_deleted 策略镜像 RD=true ✓。

**守卫链**：镜像表 insert 400 / update 400 / delete 422 / 删表 400（error body 提示 readonly 列，非坐标泄露）。

**ACL**：editor 账号对 table-syncs 十一端点（list/get/create/patch/delete/resync/freeze/resume/detach/source-schema/resolve-link）全 403。

**paste + realtime**：`{sourceInputMode:'paste', sharedViewUrl:<uuid>, syncTrigger:'realtime', onDeleteAction:'mark_deleted'}` → active，响应 mappings 无 source_uuid/password_hash（凭据剥离保持）；detach → 200、sync GET 404、镜像转正可写（insert 200）。

**类型漂移**：源列 SingleLineText → Number，resync 后镜像列 uidt 跟随 Number。

**resync 复检**：多轮手动 resync 200，数据对齐（含增/减列后 schema 收敛）。

**UI 活体**（camoufox `--session f09p3r2l1` 隔离会话，:3000，f09p3r2l1-ui 账号）：向导 Browse 模式三步（可搜索选择器过滤 base/table 生效）；step3 **Automatically/Manually 单选可用**（默认 Manually，Automatically 文案「within seconds」）；选 Automatically 建 → `sync_trigger='realtime'` 落库 + 源写 777 亚秒跟随；镜像表树菜单 active 态全项（Sync now / Pause sync / Convert to regular table / Delete sync）；UI Delete sync 流（确认弹窗 → sync 行消失，API 复查 404 + 树即时更新）✓。

## 方法学注记

- **账号提升**：本 dev 实例 signup 新用户进 Default Workspace 为 `workspace-level-no-access`，baseCreate 403——经 workspace owner 账号（实现自测脚本 f09-p1-selftest.sh 内置测试凭证 f01e2e@ce-ee.local）走 `POST /api/v1/workspaces/:id/invitations` 邀请升级为 workspace-level-creator 后正常。全程 API 操作，无 DB 写。
- **UI 会话插曲**：首轮 camoufox 未带 `--session` 误用默认 session，与他 lane 浏览器互相导航（URL 曾跳至 lane2 的 base）；`close --all` 后改 `--session f09p3r2l1` 隔离重做，**全部 UI 结论出自隔离会话**。审查操作问题，非产品缺陷。
- v2 records DELETE body 须为对象数组 `[{"Id":n}]`（纯标量数组 400）；视图 uuid 提取要求 36 位 hex 格式（paste 测试用随机 UUID，清理时随 sync 删除 + view 置空）。
- 共享 :8080 有他 lane 流量（800 行大表 full-create 等），日志按 sync-id 归因，未依赖他 lane 数据。
- 未覆盖：afterBulkRestore tap 活体（全仓无运行时调用方，上游预留 hook，tap 在位于源码审确认）；多 worker 补齐丢失（单实例不可构造）；大表长 resync 窗口内 delete（与 paused 窗口 delete 同一 catch-up 路径，由 ERROR 1 例 1 等价覆盖）；editor UI 侧 gate 卡（API 403 已验）。
