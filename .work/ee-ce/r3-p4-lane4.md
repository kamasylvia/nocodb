# F09 P4 R3 — lane 4（引擎重点路，ZCode subagent）报告

**结论：PASS / 0 error + 4 minor**

审查基线 = 840c4218aa（R2 修复批，工作树与 HEAD 一致，`packages/` 无未提交改动）；:8080 存活（`GET /api/v1/health` → 200）。**dist 双条件核验通过**：pid 38535 启动 01:41:12 > `~/.nocodb-run/packages/nocodb/dist/main.js` mtime 01:34，且该 dist 含 R2 修复特征串 `Link operations (link / unlink / reorder) are prohibited` ×2（assertLinkWriteAllowed + updateForColumn 两处守卫）⇒ 活体打的确实是修复后 dist。账号 `f09p4r3l4-api/ui/ed@review.local`（UI/API 分离）；camoufox session `f09p4r3l4`。

## 0. R2 lane3 E1 修复回归（活体，本轮核心）

**判定：闭合 ✓**（R2 症状「v3 link 端点 200/201 注入不复现」）

活体（三层 sync 场景：源 `f09p4r3l4-src`+RT 表 mm link → 镜像三层建齐）：

| 入口 | 身份 | 结果 |
|---|---|---|
| `POST /api/v3/data/{dstBase}/{mirror}/links/{mirrorLinkCol}/1` | owner | **422** `ERR_SYNC_TABLE_OPERATION_PROHIBITED`（"Link operations … are prohibited on synced table f09p4r3l4-sync — manage the links in the source table"） |
| `DELETE` 同路径 | owner | **422** 同上 |
| 同两入口 | editor（dst base editor 角色） | **422** ×2（守卫先于 FIELD permission，角色无关） |
| `POST …/links/{srcLinkCol}/{rowId}`（源=普通表） | owner | **200** `{"success":true}`（守卫不误伤合法路径） |

- **junction 配对不被污染**：mirror 镜像 link 列注入尝试后 junction 仍 3 对（r1-rt1 / r2-rt1 / r2-rt2，逐对核实）。
- **静态调用图**：`LTARColsUpdater.updateForColumn` 唯一外部调用点 = `data-v3.service.ts:1600`（v3 nestedLink）；`nestedUnlink` 走 `dataTableService.nestedUnlink` → `baseModel.removeLinks`（经 R1 守卫）。引擎（table-sync.processor）**零调用** LTARColsUpdater——junction 写全走 raw-knex（`recomputeJunctionPairs` :839 / `cleanupJunctionOrphans` :994），不经守卫、防环不破，与 R2 修复 commit 声明一致。
- 守卫落位 `ltar-cols-updater.ts:219-233`（`baseModel.model?.synced` → `prohibitedSyncTableOperation`），与 `BaseModelSqlv2.assertLinkWriteAllowed`（:6598-6609，本轮改 public）同族同文案。

## 1. 引擎三层 link sync 全链（活体）

- **createSync 含 link**：`selected_fields=["Title","Qty","RtLinks"]` → sync active；三层齐（main mapping + linked_shadow mapping + junction mapping，junction `source_table_id=null` 语义正确）；mirror 3 行 / shadow 3 行 / junction 0 对（源侧尚无配对）。
- **源 link 变更 → realtime full-resync → junction 配对 recompute**：源侧 v3 建 3 对 → ~15s 内 junction=3，配对逐对正确（main|shadow 双 RemoteId 键控）；镜像 link 列读取（r1→[rt1]，r2→[rt1,rt2]）正确。
- **shadow upsert+sweep**：shadow 与源 RT 行数/内容一致；窗口收敛段的源行删除后 shadow 侧同步收敛（见 §3）。
- 静态：`syncShadowTable`（:678-830）与主表同 RemoteId upsert + disappearance-sweep 语义；`recomputeJunctionPairs`（:839-989）双端存在性过滤（`!mainPk || !shadowPk` continue）+ 逐对 insert/del，chunked。

## 2. updateSync link 级联（活体五态）

| PATCH | 结果 |
|---|---|
| keep（同字段数组） | 200；镜像 link 列 id **不变**（cw2qj225zghzq37）；junction 仍 3 对；无无谓 resync（status 直回 active） |
| `[]` | **400** `selectedFields must be a non-empty array or null` |
| 删 link（去掉 RtLinks） | 200 + 自动 full-resync；镜像 link 列消失、junction 表 404、shadow+mappings 全清（dst 只剩主镜像） |
| `null` | 200；三层重建（新 shadow/新 junction，shadow 标题复用）+ **自动 full-resync 回填**：shadow 3 行 / junction 3 对（R1 lane1 E1④ 修复持续成立） |
| on_delete_action 双档 | delete/mark_deleted 均接受并生效（见 §4） |

静态核对：keep 分支 `desiredLinkSrcIds`（:1434）+ `keptLinkRtIds` 引用计数（:1442）+ `mainColMappings` 主映射域过滤（:1422）；`dropShadowForRelated` 幂等（mapping 缺失早退）——双 link 同请求齐删时二次调用安全。

## 3. 窗口 delete 收敛（活体）

- **标量增量（P3 站位）**：Active 态改源 r2 Qty=22 → ~14s 内镜像同步 ✓。
- **paused 窗口**：freeze → 窗口内改 r3（Title=r3-win, Qty=33）+ 删 r1 → resume（服务层 re-enqueue catch-up）→ catch-up 走**全量 pass 含 sweep**：镜像 r1 消失、r3-win/33 落库、**junction 3→2**（r1 配对随全 pass recompute 清除）、status=active 无 error。R2 E1'（catch-up 无 sweep ghost）不复现。
- 静态：processor `isIncremental && affectedIds?.length` 为假一律落全量 pass（:339-427，sweep 无条件）；`loadRealtimeTargets` 无 status 过滤（Syncing/paused 经 CAS-miss → markSkipped → run 后 catch-up，paused 期间 marker 由 resume+后续 run 消费）。

## 4. mark_deleted 两档一致（活体）

PATCH 档位 → mark_deleted → 删源 r2 → realtime incremental：镜像 r2 **保留**且 `RemoteDeleted=true`，junction 中 r2 的 2 对**即时清除**（`orphanedMainPks` 并入 flagged pks，P4-R1 lane4b M1 修复活体成立）。⇒ 引出 M-D（注释漂移，见下）。

## 5. paste 与 deleteSync

- **paste+link → 400**："Linked fields cannot be synced from a pasted shared view…"（硬编码英文——M-C）；**paste 纯标量 → 200** 建同步 active，测后删除回收 200（不误伤）。
- **deleteSync 守卫**（族 5）静态成立（`table-syncs.service.ts:1699-1744`：main 失败 → sync 行保留 + 原错上抛，role 序 junction→shadow→main）；活体仅验正常路径（200，级联清理干净）——注错路径本轮未复演（P4-R1 已验，基线无 delta）。

## 6. 质量门

- `tsc --noEmit`：**0** ✓
- jest Fork 桶：**60 passed / 60**（52.9s）✓（与声明 47+13 一致）
- Vite URL（formula-url-xss，`vitest.config.ts` 隔离单跑）：**5/5 passed** ✓（前两次并发跑出现「1 failed / 5 skipped」系已知资源抖动，单跑稳定绿）
- spec 覆盖核对：LTAR guard 组仍 4 例（addLinks / addChild / audit-only / regular 表），**无 removeChild/removeLinks/reorderLink 断言，无 v3 updateForColumn 用例**——本 lane 活体已补位实测，但结构性缺口延续（M-B）。

## 7. UI 活体（camoufox session f09p4r3l4 / f09p4r3l4-ui）

- 镜像表网格：只读语义正确（New record 置灰），3 行数据与 API 一致（r2/r3-win/r4），Title/Qty/RtLinks 三列渲染，RtLinks 为链接列图标。
- 树菜单：主镜像 + LinkedShadow 两表可见，junction 内部表正确不显。
- 向导：NocoDB Sync 入口存在，Browse / Paste link 双模。
- **zh-Hans 未重测**（localStorage 直写不触发 useGlobal 响应）；**R3 基线对 nc-gui 零改动**（840c4218aa 仅 `ltar-cols-updater.ts` + `BaseModelSqlv2.ts` + `.work` 脚本），UI 面无 delta，继承 R2 轮结论。

## M 系列（minor，全部不阻断）

- **M-A（继承 R2 M3，未修）**：源 link 列先被删除时，updateSync drop 循环对残留映射行落入通用分支（`table-syncs.service.ts:1457-1458` `if (srcCol && isSyncLinkColumnUidt(...))`，srcCol undefined → 只删镜像列+映射行），junction 表与 shadow 表（均 synced）成为无主僵尸，仅 deleteSync/detach 可回收。本轮基线未变。
- **M-B（继承 R2 M2，未修）**：LTAR guard 的 spec 覆盖缺口（removeChild/removeLinks/reorderLink 零断言；R2 新守卫 updateForColumn 零用例）。修复批未随修补用例——按全局 §12「回归用例随修随补」属欠账，但活体已由本 lane 双通道 422 实测闭合。
- **M-C（继承 R2 M1，未修）**：i18n 死键 `msg.warning.syncPasteLinkUnsupported`（en/zh 落位零引用）；paste+link 400 实际文案为服务端硬编码英文（活体复现），zh-Hans 用户在该拒绝路径见英文。
- **M-D（新，文档漂移，doc-only）**：`table-sync.processor.ts:991-993` `cleanupJunctionOrphans` docstring 仍写「delete policy only — mark_deleted rows stay and keep their pairs」，与调用方 :486-501（markDeleted 档把 flagged pks 并入 orphanedMainPks 并删除其配对）直接矛盾——P4-R1 lane4b M1 行为修复后注释未同步。行为经活体验证正确（§4），纯注释失实。

## 观察（不计 minor）

- v3 links 端点对象载荷只认**小写 `id`** 键（`normalizeRefRowIds` data-v3.service.ts:1525-1540）；`[{"Id":1}]`（v2 风格）落 `String(object)` → PG 22P02 → 422。上游 APIv3 契约，非 fork 回归，用纯数组 `[1]` 即正常。
- 全 pass 分页无显式 orderBy（offset 分页理论可跳/重行）——P1 既有设计，历轮已接受，R3 无 delta 不另立项。

## 未覆盖（如实列明）

- AUTO 双档（scheduled interval）活体未跑：R3 基线未触碰 trigger 代码，继承 P3 结论。
- E1 六格 / ACL 十一端点 / realtime 七 tap 全量活体未复跑：R3 基线无 delta，P3/P4 R1-R2 已验。
- editor 对 mirror 行级写入路径只验到 readonly 400 挡板（Title readonly 先于 synced insert guard 触发），守卫链终态未逐层剥离——写被挡的终局行为正确。

## 纪律

只读审查未改源码（`git status` packages 无改动）；未构建/未重启/未 pkill/未跑 `dev-backend*.sh`；无 psql、未提权；隔离——仅读任务书指定对照材料（r3-p4-lane-prompt.md / r2-p4-lane-prompt.md / r2-p4-lane3.md），未读本轮其他 lane 报告；测试数据全 `f09p4r3l4-` 前缀（3 账号、2 base、1 sync、三层表与行），测完删净（sync/dst/src 删除均 200，名下无残留 base）；infra 引导账号 f01e2e 仅用于建 base + 邀请 lane 账号（committed 工作脚本既定惯例），全部测试操作走 `f09p4r3l4-api`。camoufox session 已关闭。
