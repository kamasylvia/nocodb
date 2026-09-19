# F09 P3 R1 会审 — lane 5(UI 验证重点路)报告

**结论:1 error + 1 minor**(另有 2 条 observation,不计入计数)

- 审查基线:f6a9314b5e(P3 实现批);:8080 运行 P3 dist 未动
- 账号:`f09p3r1l5-ui@example.com` / `f09p3r1l5-api@t.io` / `f09p3r1l5-editor@t.io`;camoufox session `f09p3r1l5`
- 证据截图:`.work/ee-ce/.r1p3l5-shots/`(01–20)
- 测试数据已清理:两个 f09p3r1l5 base 已删(trash),临时 token 文件已删,浏览器会话已关

## 0. 质量门

| 门 | 结果 |
|---|---|
| `npx tsc --noEmit` | 0 错误(exit 0) |
| `npx jest --testPathPattern Fork` | 44/44 passed(3 套件全过) |
| 改动 SFC/TS Vite URL | CreateNewSync.vue / SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts 全 200 |

## 1. E1(error):realtime 事件在 sync 处于 Syncing 窗口时被静默丢弃,无补齐 → 数据最终不一致

- **现象(活体实测)**:向导建 realtime 同步后,源表 80ms 内连续 PATCH(Id=1) + DELETE(Id=2):
  - update 事件正常入 job,镜像 row1→row1-edited ✓;
  - delete 事件到达时 sync 状态=Syncing(job 排队/执行中)→ **被静默丢弃**:源已删 row2 在镜像中永久残留;
  - sync 状态显示 active、last_error=NULL、last_synced_at 正常推进——**无任何异常可见**;轮询 2 分钟以上无自愈,只能靠手动全量 resync 收敛。
- **隔离验证**:sync 恢复 active 后单独 DELETE 源 row3 → **1.5s 内**镜像跟随删除。证明单事件链路正常,丢失精确发生在 Syncing 窗口。
- **根因**(`src/helpers/table-sync-realtime.ts`):`loadRealtimeTargets()` 的 JOIN 带 `.where({..., status: TableSyncStatus.Active})`。sync 一旦被首个事件 claim 成 Syncing,整个排队+执行窗口(秒级)内后续事件在 JOIN 阶段就查不到目标,`targets.length===0 → return`,**根本走不到** `claimAndEnqueue` 的 CAS-miss → `markSkippedDuringSync` 分支。补齐机制只在 JOIN 读与 UPDATE claim 之间的纳秒级竞态下可达,主窗口(设计意图覆盖的场景)完全失效。
- **对照任务书**:P3 验证范围第 2 条「Syncing 投递跳过 + 补齐:CAS miss 跳过 → 当轮结束后补齐水位 job → 数据最终一致」——实测数据不最终一致。实现自述「Syncing 中投递跳过 → 补齐」描述的语义与实际行为不符。
- **修复方向**:`loadRealtimeTargets` 状态过滤放宽为 `status IN (active, syncing)`(或不过滤,交由 CAS 判定),JOIN 命中 syncing 的 sync 时直接 `markSkippedDuringSync(sync_id)`,其余路径不变。注:水位补齐 job 对无 LMT 列源会回退全量,可正确补删(实测通道存在)。
- **影响面**:realtime sync 源高频写入(首批事件互相挤占窗口)是常态场景;静默不一致比报错更危险。

## 2. 活体通过项(UI + API,账号内自洽)

1. **向导双档建同步**:step3「Automatically / Manually」两档单选可选,默认 Manually,i18n 文案正确(en)(05/09)。Automatically → createSync 200,`sync_trigger=realtime` 落库,首跑 full-create,状态 Syncing→Active,树出现镜像表(带 sync 图标)(07)。Manually → `sync_trigger=manual`,行为同 P1。
2. **realtime 自动跟随(active 窗口)**:insert 亚秒级(row4,写后 4s 内已入镜像且 last_synced_at 推进);update 跟随(row1-edited);delete 跟随(row3,~1.5s)。全程未点 Sync now。
3. **manual 语义保持**:源写 6s 后镜像不变(20 行,manual-check 未到)→ 树菜单 Sync now → 21 行到达。AUTO 解锁未影响 manual 档。
4. **树菜单状态**:active 态节点 tooltip「Last synced …」正确(15/10);Paused 态菜单正确切换为「Resume sync」(12),resume 后 DB 恢复 active;Syncing 态菜单项隐藏守卫 code-review ✓(`v-if status!==Syncing`,P2 已覆盖,亚秒瞬态活体未捕捉)。
5. **删除流三腿**:①Cancel——2 syncs/2 表原样(14);②Delete sync 确认——sync 与镜像表同删,树即时刷新(15);③Convert to regular table——sync 删、表转正、普通写路径 200、syncs 剩 0。
6. **Convert 后 grid 瞬空白修复(P3 顺带修)实测通过**:detach 后已打开的目标表 grid 渲染全部数据行不空白、列头排序/筛选符出现、New record 按钮激活、API 写 200(18)。
7. **editor Overview 卡 gate**:editor 账号(+)在 base Overview 无「NocoDB Sync」创建卡(`isUIAllowed('sourceCreate')` gate),API 直 create sync → 403 Forbidden roles: Editor(19);editor 打开 base 直接落在表页,无创建入口。
8. **P1/P2 站位**:wizard step1 Browse/Paste link 双 radio 站位在,Paste link 切换后 shared view URL 输入框正常渲染(20);树/面板/菜单操作正常。

## 3. M1(minor):树 tooltip 状态徽标陈旧

`useTableSync` 的 `sync` ref 仅在上下文菜单打开时 `load()`;tooltip hover 不刷新。t2 已 resume(DB=active)后 hover 仍显示「Paused」(13)。误导性显示,刷新页面后正确。P2 存量行为、非 P3 引入;但 P3 realtime 使状态变化高频化,建议顺手在 tooltip 打开时也 `load()`。

## 4. Observation(不计计数)

- **O1 源软删后 processor 守卫失效(存量)**:源表/源 base 走 trash 软删后,processor 的 `srcModel.deleted` 检查不生效(物理数据仍可读),Sync now 对已删源「成功」且 sweep 照常(t2 删源后 run 成功、镜像保持 21 行)。Error 态因此无法经合法流触达。guard 语义早于 P3,非本次引入;供后续定夺(要么真拦、要么删守卫改提示)。
- **O2 测试方法学**:v2 records 无 by-id PATCH/DELETE 路由(`Cannot PATCH /records/1`),须用集合路径 + body 带 Id;误报 404 需先核对写路径。
- 环境说明:本实例 fresh signup 默认 org-level-viewer,无 baseCreate;按前轮先例(F03 r1a/r1b 模式)由既有 admin 测试账号(f01e2e)将本 lane 三个 `f09p3r1l5-*` 账号提为 workspace-level-creator(editor 账号保持 base 级 editor)。UI 账号与 API 写均出自同账号体系,符合 UI/API 分离纪律。

## 5. 证据索引

| 项 | 截图 |
|---|---|
| 向导 step1 Browse/Paste 站位 | 03 |
| step3 双档单选(默认 Manually) | 05、09 |
| realtime 建后树+镜像 3 行 | 07、08 |
| active tooltip「Last synced」 | 10、15 |
| paused 菜单 Resume sync | 12 |
| paused 态陈旧徽标(M1) | 13 |
| 删除确认对话框 / 删除后树 | 14、15 |
| convert 后 grid 不空白可编辑 | 17、18 |
| editor 无创建卡 + grid 正常 | 19 |
| paste 模式站位 | 20 |

— lane 5(f09p3r1l5),2026-09-20 00:3x
