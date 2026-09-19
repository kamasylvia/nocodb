# F09 P3 R5 修复回归（冲刺轮） — lane 4 报告（引擎重点路）

**结论：PASS（0 error + 0 minor）**
审查基线 = 45032e45b0（R4 修复批，HEAD）；:8080 运行 dist 与工作区 dist md5 一致（10c3469c62997b30e26f90adffc71dca），进程 72234（05:55 起）晚于 dist mtime（05:31），活体口径成立。R4 error（resync 响应回显 job）修复在运行 dist 中活体验证通过。
账号 f09p3r5l4-api@lantest.local（workspace-level-creator 经 f01e2e@ce-ee.local dev 账号授予，历轮同口径）；测试数据（2 base / 3 sync / 全部镜像表）已全部删除，token 落盘文件已清除。

---

## 1. 质量门

| 门 | 结果 |
|---|---|
| `npx tsc --noEmit` | exit 0（`.work/ee-ce/f09p3r5l4-tsc.log`） |
| `npx jest --testPathPattern 'Fork'` | **44/44**（3 suites，与基线一致；`f09p3r5l4-jest.log`） |

## 2. 静态审计（引擎链）

### 2.1 realtime tap 防环七处（BaseModelSqlv2.ts）— 全部就位
1. `afterInsert` :5644 — `data && this.model && !this.model.synced` + try/catch
2. `afterBulkInsert` :5697 — `data?.length && … && !synced`（bulk 数组体传播入口）
3. `afterDelete` :5788 — 同型守卫（hard+soft delete 覆盖）
4. `afterBulkDelete` :5830 — 同型守卫（引擎 dest sweep 无 skip_hooks，靠此守卫拦截）
5. `afterBulkRestore` :5909 — 同型守卫
6. `afterBulkUpdate` :6005 — `Array.isArray(newData) && length && … && !synced`（bulkUpdateAll 计数形态不 tap）
7. `afterUpdate` :6149 — 同型守卫

二重保险复核：引擎 dest 写 bulkInsert/bulkUpdate 带 `skip_hooks:true`（processor :219-225/:427-428）短路 after*；tap 仅在 `loadRealtimeTargets` 命中 `source_table_id = 触发表` 时分发。**status 无预过滤**（helper :81-92 注释明确记载 R2 改判）——Syncing/paused sync 对 tap 可见，claim-miss 落 `markSkippedDuringSync` → catch-up 链路可达。

### 2.2 窗口收敛链（processor + helper）— 闭合
- incremental + affectedIds → 按 pk 拉；**incremental 无 ids（catch-up）与 full 统一走全量 pass：upsert + 消失 sweep**（processor :320-409，R2 lane4 E1' 修复语义，本轮复核在位）
- run 完成后 `enqueueCatchUpIfNeeded`（processor :97）：marker 存在才补一跑；claim-miss/异常时**保留 marker** 下次再补（helper :256-266）
- 成功路径翻 Active + last_synced_at + `sync_job_id:null`；失败翻 Error + last_error，**swallow 不 rethrow**（无队列级重试打半写镜像）
- resume 触发 catch-up（service :1181）——paused 窗口变更追平入口

### 2.3 resync 修复（R4 error 回归）
- `resync()` service :1132-1135：`enqueueSyncJob` 结果仅取 `{id, name, status: Syncing}` 返回；job.data 仍带完整 req（引擎写 `cookie: req` 依赖，入队内存态不落 HTTP）
- 活体证实修复在运行 dist 中（响应形态见 T1.4）

## 3. 活体回归（引擎矩阵）

| 项 | 结果 |
|---|---|
| **resync 响应收敛**：POST resync → 200，**69 字节**，keys 精确 `["id","name","status"]`；token 尾 17 字符 grep **0 命中**；rawHeaders/socket/_readableState/cookies/headers 关键词 **0 命中** | PASS |
| **引擎行为不变**：响应 id == sync 行 `sync_job_id`（`job0oz5ojmyhejsdy` 精确一致），immediate status=syncing → 完成后 active + last_synced_at 刷新 + sync_job_id 清 null（processor 设计）；连续两次 resync job 真实更替 | PASS |
| **守卫不变**：paused 下 resync 400；active 下 resume 400 | PASS |
| **realtime 链路**：单插 r6 ~2s 传播（warm-up） | PASS |
| **Syncing 窗口 delete 收敛**（realtime sync，1501 行表 B）：resync 窗内 DELETE b1500 + INSERT win2 → ~8s CONVERGED：b1500 被 sweep 消失、win2 被 catch-up 追平、**mirror=1501=source 精确持平**，结束后 10s 复查无自激/计数漂移 | PASS |
| **paused 窗口三写收敛**：freeze → +r10 / r1→999 / DELETE r3（镜像冻结确认：行数/r3/r10/r1 全部原态）→ resume → ~4s CONVERGED（r3 消失、r10 到位、r1=999） | PASS |
| **bulk 数组体传播**：bulkInsert 数组 x30 ~4s 全到；bulkUpdate 数组 x20（Val=7777）全部传播；bulkDelete 数组 x5 ~2s sweep 收敛 | PASS |
| **事件风暴**：20 单插连发 + 混合风暴（+10 插、3 删、3 改快速交错）→ ~4s 收敛，计数精确持平，3 删全消失、3 改（Val=8888 x3）全到位 | PASS |
| **幂等复跑**：resync 复跑多轮（1551→1551→1551、1561 三连、1568→1568）行数零漂移，无 dup/无丢失；终态 active / sync_job_id=null / last_error=null | PASS |
| **manual sync 语义**（观察项，不计）：manual sync resync 窗内 realtime 写不传播（tap 按 sync_trigger=realtime 过滤，EE 语义正确）；下一次 manual resync 全量 pass 自带 sweep 收敛 | 符合设计 |

## 4. 测试过程归因（lane 自身脚本错误，非引擎缺陷；全程实测排除）

- run1 T1.5 FAIL：断言误写「完成后 sync_job_id 应为新值」——processor 完成路径按设计置 null；真实入队已由 immediate GET `sync_job_id == 响应 id` 证实。
- run1 T1.7 FAIL：in-window 探针误发在 **manual** sync 上——manual 本就不吃 realtime tap（设计如此），换 realtime sync 重测即收敛（run2）。
- run3 T3.2 FAIL：期望常量 111 为上轮 lane 残留值，本表 r1 Qty 原值 1，镜像冻结态实际正确。
- run4 T4.2/T4.3 FAIL：bulk update/delete 用了裸数字数组体（v2 需对象体 `[{"Id":N}]`）→ 源表无操作，镜像自然不变；run4b 用正确体重测全过。
- run4b T4b.1 Val77=21 vs 20：run4 畸形 PATCH 在**源表**留 1 行污染 + T4b.2 随后删掉 5 行已更新行 → T4c.1 复核源=镜像=16 逐侧一致，镜像零错。
- run4b T4b.3 N2 空：脚本 URL 串混入垃圾文本致 S2IDS 取空 → 后续 update/delete 空转；run4c 修正后风暴全过。

## 5. 清理记录
- base `f09p3r5l4-SRC` / `f09p3r5l4-DST` DELETE 均 true；bases 列表 0 残留（sync/镜像随 base 级联）。
- `.f09p3r5l4-*` token/id/payload/响应转储文件全部删除；脚本仅含本地 dev 测试账号口令（红线允许项）。
- f09p3r5l4-api@lantest.local 账号行保留于 dev 实例（无用户删除 API，历轮口径一致）。

## 6. 产物
- 脚本：`.work/ee-ce/f09p3r5l4-{setup,run1,run2,run3,run4,run4b,run4c}.sh`
- 日志：`f09p3r5l4-tsc.log`（exit 0）/ `f09p3r5l4-jest.log`（44/44）
