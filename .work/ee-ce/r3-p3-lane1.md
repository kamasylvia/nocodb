# R3 P3 lane1 — R2 两 error 修复回归审查报告（窗口 delete 收敛 / Convert 确认弹窗，2026-09-20）

**结论：PASS（0 error + 3 minor）**

- 审查员：lane 1（f09p3r3l1-*）；基线 5d25acfc51（R2 修复批）= HEAD；:8080 = pid 75970（起于 02:21:11，晚于 dist mtime 02:10），dist 内 grep 到 R2 修复特征串（`full-pass catch-up` ×3 / `claim missed` ×2 / `watermarkStart` 0 hits）——确为修复后 dist。全程零构建/零重启/零 psql/零 dev-backend 调用。
- 质量门：`tsc --noEmit` exit 0；jest Fork 桶 **44/44**（3 套件）；Vite URL 编译法 **4/4 = 200 text/javascript** 真产物（CreateNewSync.vue / SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts，`/_nuxt/@fs/` 经 localhost:3000，注意该 dev server 只监听 IPv6）。编译产物双确认：`useEeConfig.ts` 产物内 `blockTableSyncAuto = computed(() => false)`（AUTO 解锁在）；`SyncMenuOptions.vue` 产物内 `isConvertConfirmOpen` ×7 + `table-sync-convert-confirm` testid（R2 弹窗修复在前端产物中生效）。
- 活体脚本与结果（已归档本目录）：`f09p3r3l1-run1.sh`（探针缺陷中止，教训见 §4）→ **`f09p3r3l1-run1b.sh`（→ run1b.txt，0 FAIL）**、`f09p3r3l1-run2.sh`（→ run2.txt）；ids 留档 `f09p3r3l1-ids.txt` / `f09p3r3l1-run2-ids.txt`。后端日志 `/private/tmp/nocodb-internal.log` 按 sync-id 归因（共享实例，多 lane 并发流量未影响本 lane 结论）。
- 测试数据：run1b 两 base 对（sync `tsshqqmjviccrz7aj` mark_deleted / `tssghghzky12jjh0x` delete）、run2（sync `tss013yixueif76yy` + manual `f09p3r3l1_r2manual`）、UI base 对（sync `tss5xkvtm0g7tm7n5`）全部删除；infra 侧 bases 列表复查 `f09p3r3l1` 残留 **0**。账号 f09p3r3l1-api / f09p3r3l1-ed / f09p3r3l1-ui 保留供后续轮次。camoufox session `f09p3r3l1` 已 close。

---

## 0. PASS 面（R2 两 error 修复回归主结论）

### R3-1 窗口 delete 收敛（R2 四路同判 E1' 族）——修复成立，ghost 场景零复现

| 场景 | 证据 |
|---|---|
| **realtime 单删（无窗口）** | 删 a3（HTTP 200）→ 镜像 `RemoteDeleted=true` ~400ms（run1b §4） |
| **paused 窗口三写 → resume → 全追平（决定性）** | freeze 200 → 三写 upd/ins/del 全 200 → 3s 零泄漏（a1-edited/p_ins 不进镜像、a2 仍活行）→ resume 200 → **三腿 @+1s 全部自动追平：a1-edited 进、p_ins 进、a2 `RemoteDeleted=true`**（run1b §5；终态行 `{"Title":"a2","RemoteId":"2","RemoteDeleted":true}`）。R1 lane4 run5 与 R2 四路的 ghost 场景重演 **0/2 复现** |
| **Syncing（大表 resync）窗口三写** | 800 行 delete 策略表 resync → poll7 捕获 syncing → 窗口内三写全 200（w00010→Qty910 / w_ins_win / w00020 删）→ 补齐后 **update/insert 追平 + w00020 镜像行物理清除（sweep 生效）**，终态 800 行（run1b §6） |
| **日志链决定性（deletes 首次出现）** | 02:42:56 catch-up `enqueued watermark catch-up run jobf0trp0wssus7t7` → `[incremental]: source rows=2 inserts=1 updates=3 deletes=0`（updates=3 = a1 值更新 + sweep 对 a2/a3 置 flag）；sync3 02:42:58 `[incremental]: source rows=800 inserts=1 updates=799 deletes=1`、02:43:07 `deletes=1`——**R2 时代 catch-up 恒 deletes=0，本批 sweep 已在跑** |
| **幂等复跑一致** | 第二轮 resync 窗口删 w00030 → 同被 sweep（镜像 0 hit）；镜像=源行数 799=799；两轮 RemoteId 零重复（run1b §7） |
| **修复形态与源码一致** | `table-sync.processor.ts:320-409`：incremental 无 ids 落入全量 pass（镜像全扫 existingByRemoteId → 全量 upsert → disappearance sweep 按 on_delete_action 删/置 flag）；修复批 commit 注释明确「a full pull observes every row, so the sweep is safe and required」 |

### R3-2 Convert 确认弹窗（R2 lane5 minor 修复）——UI 活体成立（camoufox session f09p3r3l1，账号 f09p3r3l1-ui）

| 断言 | 证据 |
|---|---|
| 树菜单 Convert → 弹窗出现 | `data-testid=table-sync-menu-convert` 点击 → `.nc-table-sync-convert-modal` present，title=**Convert to regular table**，Cancel（`table-sync-convert-cancel`）/Convert（`table-sync-convert-confirm`）双钮 |
| Cancel 不动作 | Cancel 点击 → 弹窗关；API 复查 sync `tss5xkvtm0g7tm7n5` 仍在 |
| **真 Esc 键**不动作 | camoufox `press Escape`（合成 KeyboardEvent 不受信不计）→ 弹窗关，sync 仍在 |
| Confirm 转正生效 | Confirm 点击 → sync list **1→0**（API 裸数组实测）、表保留树内、2 行数据保留、**转正后可写**（POST 200） |
| 附带 UI 活体 | 镜像表 grid「New record」button disabled（synced 只读守卫 UI 可见） |

### P3 站位继承抽查（run2，全部 PASS）

- **bulk 传播（R2 E-bulk 回归）**：源表数组体 POST 3 行 → 日志恰一条 tap `(insert, 3 ids)`（非 3 事件）→ 镜像 4 行 @0.4s；bulk PATCH 数组 body-Id 2 行 → tap `(bulkUpdate, 2 ids)` → 镜像 b1.Qty=11 @~200ms；RemoteId 零重复
- **camelCase selectedFields**：PATCH `{"selectedFields":["Title"]}` 200 → GET 持久化 `["Title"]`；恢复 `["Title","Qty"]` 生效
- **守卫链**：直写镜像 insert 400 / update 400 / delete 422 全拒
- **ACL**：editor 对 createSync/freeze/resync/PATCH/delete/detach **六端点全 403**；攻击后 sync title 未被动
- **detach（API 侧）**：owner detach 200 → sync 移除、表保留、转正可写（UI 侧由 R3-2 覆盖）
- **双 trigger**：manual createSync 200（trigger=manual）；非法 `hourly` → 400
- **resync 复检**：run1b §6/§7 两轮 resync 全过（含窗口注入）

---

## 1. Minor（无 error）

- **M1 注释/命名腐化残留（R2 M2/M3 同族漏网，修复批自述已清理但四处未同步）**：
  ① `table-sync.processor.ts:30-32` 头注释替换后自相矛盾且病句——「an incremental run with no ids / without touched ids falls back to the full pass (upsert + sweep) **and skips the disappearance sweep** — a partial pull must never sweep unobserved rows」：上一行说含 sweep，下一行说 skip；
  ② `table-sync.processor.ts:55`「or the full-pass catch-up (catch-up), **skipping the disappearance sweep**」与实现相反；
  ③ `table-sync-realtime.ts:102-104` claimAndEnqueue docstring 仍写「the processor falls back to the **RemoteUpdatedAt watermark pull**」——该机制已删；
  ④ `table-sync-realtime.ts:34/:229/:252`（含运行日志串「enqueued **watermark** catch-up run」）「watermark」命名已无机制对应。行为正确（本轮活体全过），纯安全网文档腐化；随下次改动顺手清理即可。
- **M2 镜像写拦截层是 readonly 列校验而非 synced 守卫（R2 lane3 M2 延续，未恶化）**：run2 §6 镜像 insert 被拒 400，但错误串 `Column "Title" is readonly column and cannot be updated` 而非 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`——拦截有效（列 readonly + HTTP 不可达双层），纵深防御缺口维持 minor 观察级。
- **M3 catch-up 全量 pass 负载放大（R2 lane4 M1 结构同源，sweep 使单次成本略增）**：catch-up 现为 O(N) 全量 upsert + 镜像全扫 + sweep（另有 per-row `findDestRowByRemoteId` 逐行 list）。800 行表实测无感（catch-up 秒级完成）；10 万行级大表 + 高频写下每轮窗口事件串行触发全表 pass。正确性无损（幂等实证），负载放大建议后续评估 marker 合并/节流。

## 2. 环境注记（非 finding）

- run1 首败根因：同 DEST base 前一 sync full-create 未结束时第二个 createSync 被 `Another table sync is still running in this base` 400 拦截——`table-syncs.service.ts:588-595` 按 `TableSync.list(context, baseId)`（condition base_id）判定，**base 级互斥设计内行为非缺陷**；run1b 已改为 sync2 到 active 再建 sync3。
- run1/run2 共 4 条探针伪 FAIL（S3ID 被 note 输出污染、jq `// empty` 把 `false` 变空串、listSyncs 裸数组误用 `.list[]`、镜像 insert 断言绑错误串）——均已定性并按修正探针/微探针复验为 PASS（detach 后 list 1→0 微探针、readonly 拦截串归属 R2 M2）。
- camoufox 会话中途过期一次（UI token TTL），重登后完成 Confirm 路径；合成 `KeyboardEvent` 不受信会被 NcModal 忽略——UI 断言一律以 camoufox 原生 `press`/`click` 为准。

## 3. 纪律声明

只读审查零改码；:8080 只读实测未触碰；未跑 psql；隔离未读任何他路 R3 报告（仅按任务书读 R2 lane3/lane4 作对照）；测试数据全 `f09p3r3l1-` 前缀且残留 0；凭证未入任何 git 跟踪文件。
