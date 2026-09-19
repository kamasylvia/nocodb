# R3 P3 lane4 — 引擎重点路（窗口 delete 收敛终验 / bulk / 幂等 / 风暴 / claim-miss 可观测性）

**结论：PASS — 0 error + 2 minor**

- 审查员：lane4（f09p3r3l4-*，账号 f09p3r3l4-api@ce-ee.local 保留）；基线 5d25acfc51（R2 修复批）；:8080 = pid 75970（起于 09-20 02:21:11，晚于 dist mtime 02:10）只读实测，全程零构建/零重启/零 psql。
- **关键部署事实**：运行 dist 为**中间态**——processor 的 catch-up sweep 主修复已入包并活体验证生效；但 commit 同批的 `table-sync-realtime.ts` claim-miss debug 行**不在 dist 内**（详见 M1）。
- 质量门：`tsc --noEmit` exit 0；jest Fork 桶 **44/44**（3 套件）；Vite URL 编译法 **4/4 = 200 text/javascript**（SyncMenuOptions.vue / CreateNewSync.vue / useEeConfig.ts / useTableSync.ts，transform 产物核真：SyncMenuOptions 产物含 `labels.convertToRegularTable`×3 + `table-sync-convert-confirm` testid，i18n key 在 `lang/en.json:1890`——convert 确认弹窗修复已随 dev server 活体可用）。
- 活体脚本与结果：`.work/ee-ce/f09p3r3l4-run1.sh`（→/tmp/f09p3r3l4-run1.txt）、`f09p3r3l4-run2.sh`（→/tmp/f09p3r3l4-run2.txt）；后端日志 `/private/tmp/nocodb-internal.log`（fd1/2 实证指向该文件）按 sync-id 归因。
- 测试数据：run1 sync `tsspz9cl8e9ixnou6`、run2 sync `tss0ov6qdr80f3tnt`/`tssinli93x2wihfq0`，两 base 对 ×2 全部删除，bases 列表复查 `f09p3r3l4` 残留 **0**。camoufox session 未消耗（引擎路无 UI 断言）。

---

## 0. PASS 面（R1'/R2 E 族终验 + 引擎站位）

| 项 | 证据 |
|---|---|
| **①a paused 窗口 delete 收敛（mark_deleted）——R1 lane4 run5 / R2 四路 ghost 场景终验不复现**：freeze→paused → 三写全 200（upd a1 / ins p_ins / **DEL a2**）→ 3s 零泄漏（a1-edited=0、p_ins=0、a2 仍活行）→ resume → 补齐 job（日志 02:35:51 `enqueued watermark catch-up run`）→ `[incremental]: source rows=6 inserts=1 updates=6`（全量 pass：6 updates 含 a2 的 mark_deleted 扫描更新）→ **三写全追平：a1-edited ✓ p_ins ✓ a2 RemoteDeleted=true ✓** | run1 §5-6；日志 764-769 行 |
| **①b Syncing 窗口 delete 收敛（delete 策略，物理 ghost 消失）**：800 行表 full-create 窗口内三写全 200（w00010→Qty910 / w_ins_win / **DEL w00020**）→ full-create 800 行完成 → 当轮结束补齐（02:39:12 catch-up 入队）→ `[incremental]: source rows=800 inserts=1 updates=799 deletes=1`——**deletes=1 即消失扫描在补齐内物理删除 w00020** → 镜像终态恰 800 行、w00020 零命中、零重复 RemoteId。R2 lane3 双窗口 ghost 症状（镜像 301 vs 源 300）零复现 | run2 §3；日志 807-809 行 |
| **② bulk 数组体传播**：源表 v2 数组 POST 3 行 → **一条 tap `(insert, 3 ids)`**（02:35:47，非 3 事件）→ 镜像 3/3 **wall 383ms**；零重复 RemoteId。R1 症状持续不复现 | run1 §4；日志 765-766 行 |
| **③ 补齐幂等复跑**：run1 resync 后**全行内容逐一比对一致**（RemoteId/Title/Qty/RemoteDeleted 四字段快照 diff 为空）、行数 7 不变、a2 标记不复活不丢失；run2 resync 800 行数不变、已删行不复活；风暴段 7 连 catch-up 全量 pass 串发后零重复 RemoteId——全量 upsert + sweep 的幂等性三角度实证 | run1 §7；run2 §4；日志 819-829 |
| **④ 风暴队列行为**：15 连发 insert → **15/15 mirrored ~300ms**、零重复、status=active、`run failed` 0 条；队列形态 = 2 个 claim 胜出增量 job + 7 连 catch-up 全量 pass（02:39:25-26 约 1s 内收敛），非 15 排队 job | run2 §5；日志 812-829 |
| 守卫链抽查：mirror 直插 400；静默窗 8s status/lastSyncedAt/syncJobId 零 churn | run1 §8 |

## 1. Error

无。R1'/R2 两轮的 E 族（窗口 delete 静默发散）经双策略（mark_deleted 标记腿 / delete 物理腿）× 双窗口（paused / Syncing）活体重演，全部收敛，修复成立。

## 2. Minor

- **M1（部署中间态）**：commit 5d25acfc51 声称的 claim-miss 可观测性（R1 lane4 M3 / lane2 沿革）**在源码不在运行 dist**：`table-sync-realtime.ts:127` 的 `logger.debug("claim missed (syncing/paused) — marked for catch-up")` 在 dist/main.js 中 0 命中（dist 内 `claimAndEnqueue` 仍为 `if (!claimed) return null;`），而同 commit 的 processor sweep 代码与死代码清理（`watermarkStart`/`WATERMARK_OVERLAP_MS` 0 命中）均在包内。活体佐证：本轮 6 次真实 claim miss（run1 paused 窗 3 写 + run2 syncing 窗 3 写）在日志中**零痕迹**，而 debug 级别确认开启（同文件 `enqueued watermark catch-up run` debug 行全日志 20 条）。判 minor 依据：纯可观测性缺失、无正确性影响（marker→catch-up 链两次窗口均实际入队并生效）；但 **dist 与 commit 不同源是事实**，下一轮前需重建并热同步 dist（或裁决接受源码级修复、dist 欠账挂账）。构建/重启属禁区，本 lane 未动。
- **M2（风暴放大略增重，R2 lane4 M1 延续 + R3 新变量）**：15 连发收敛为 9 个 job（2 增量 + 7 连 catch-up），且 R3 起**每个 catch-up pass 增加镜像预扫描 + sweep 两趟**（`processor.ts:329-347` 镜像全扫 + `:393-408` 消失扫描）。小表无感（17 行表 1s 内收敛）；大表（10 万行级）高频写下串行全表 pass 的放大面较 R2 再增厚。正确性无损（800 行表窗口三写秒级收敛）。维持 minor 观察级，建议后续评估 marker 合并/补齐节流。

## 3. 方法学注记

- run1 出现 3 处探针假 FAIL/异常，均为探针缺陷非产品回归：①「a1 edit 泄漏」断言方向写反（MV_A1=0 即未泄漏，判式写反）；② resume 后瞬时读到 status='syncing'——补齐 claim 立即获胜的**修复生效证据**（R2 lane4 同款教训）；③ paused 期 a2 读到 "GONE" 系 jq `//` 运算符把 `false` 当空值的怪癖（实际 RemoteDeleted=false=活行，正确）。产品断言以 §0 PASS 面为准。
- 共享 :8080 有他 lane 并发流量（日志可见 3011 行 resync 等异 sync-id 活动），本 lane 结论仅基于自有 sync id 归因。
- 未覆盖（他路站位）：UI 活体（convert 确认弹窗交互、向导三档等）、ACL、paste 凭据矩阵、类型漂移、selectedFields——本轮引擎路未重跑 P1/P2 全站位（R3 修复不触这些路径），仅守卫链抽查。
- 直接单事件 delete（非窗口）路径与窗口路径共用 `applyDeletePolicy`，窗口双策略已活体覆盖，未单独立项。
