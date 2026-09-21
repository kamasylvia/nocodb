本 lane 结论如下（**沙箱禁写：`write_file` 与网络/运行时全被 host 权限层拦下，报告未能落盘 `.work/ee-ce/r2-p4-lane3.md`，以下为全文，待落盘**）。

---

# F09 P4 R2 — lane 3（reasonix）报告

**结论：1 error + 3 minor**（不 PASS）

审查基线 = 5368ef1366（R1 修复批）；:8080 存活（`GET /api/v1/health` → 200，uptime 129621s ≈ 36h）。账号前缀 `f09p4r2l3-*`（未创建，见 §0）；camoufox session `f09p4r2l3`（未能启动，见 §0）。

## 0. 环境限制（本轮 lane 的活体不可执行 —— 必读）

本 lane 在**只读沙箱 + 无网络写通道**中运行：`curl` / `python3` / `node` / `npx` / `lsof` / `fuser` / `ps` / `for` 循环 / `$(...)` / `/dev/tcp` 全部被权限层拦下（`blocked: the current constraints forbid state mutation`），子代理 `read_only_task` 同样被拦（已复现）。因此：

- **不能**跑带 `xc-token` 的 API 活体，**不能**跑 camoufox（`create_tab` / `evaluate_js` 非 read-only，被拦）⇒ **R2 重点 1–7 的活体项全部未执行**（UI 活体、三层建同步、守卫 422、paste 400、realtime 补填、ACL 十一端点、zh-Hans 展示）。
- **不能**跑质量门（`tsc --noEmit` / `jest`），不能 `ps`/`lsof` 核验 :8080 进程的 dist 新鲜度。
- 唯一可用网络通道 `tool:web_fetch`（read-only GET、无自定义 header）只证明后端存活；其 uptime 起点 ≈ 09-20 10:04 **早于**修复批 commit 时间 10:20，因 dev server 的 rspack 父进程受 autoRestart 影响，**不足以判定 dist 含修复** → 列为未核验。

故本报告 = **静态审查 + 源码级调用图核验 + 既有 spec 精读**，活体项如实标注「未执行」。

## E 系列（error，必修）

### E1【安全/数据完整性，R1 族 3 未闭口】v3 link 端点绕过 `assertLinkWriteAllowed`，镜像 junction 仍可被注入/删除

**静态证据（调用图，5368ef1366 工作树）**：

- `controllers/v3/data-v3.controller.ts:191-221`：`POST /api/v3/data/:modelId/links/:columnId/:rowId`（`@Acl('nestedDataLink')`）→ `dataV3Service.nestedLink`。
- `services/v3/data-v3.service.ts:1583-1617`：**不经** `baseModel.addLinks`，而走 `LTARColsUpdater({ baseModel, logger }).updateLTARCol(...)`。
- `db/BaseModelSqlv2/ltar-cols-updater.ts:203-238`（`updateForColumn`）：只做 `checkPermission(FIELD, RECORD_FIELD_EDIT)`，随后**直接** `addOrRemoveLinks(baseModel).addLinks({...})`（`:231`）；文件内注释自认 "calls the addOrRemoveLinks helper directly rather than baseModel.addLinks()"。
- `db/BaseModelSqlv2/add-remove-links.ts`（`addOrRemoveLinks` 定义 `:162`）：整个 `db/BaseModelSqlv2/` 子模块 grep `synced` **零命中** ⇒ helper 无 synced 守卫；`assertLinkWriteAllowed` 仅挂 `BaseModelSqlv2.ts:6654/7050/8922/8942/8965`（addChild/removeChild/addLinks/removeLinks/reorderLink）。
- 对比：批量档 `BaseModelSqlv2.updateLTARCols`（`:4752`）内部的 `update()` 走 `trxBaseModel.removeLinks/addLinks`（`ltar-cols-updater.ts:173/185`）→ **经守卫**；只有单列档 `updateForColumn`（v3 link 端点专用）绕过。

**后果**：`POST /api/v3/data/{mirrorTableId}/links/{mirrorLinkColId}/{mirrorRowId}` 对 synced 主镜像 link 列注入源中不存在的配对 / 解除真实配对，**无 422**（`updateForColumn` 不查列 readonly、不查 `model.synced`；FIELD edit 检查 base owner 必过，editor 视 CE 默认 ACL 判定——后者未活体核验，保守留白）。junction 写为 raw knex、读路径无视 synced ⇒ realtime 档下次 full pass 可自愈，**manual sync 档下污染/破坏无限期存活**——与 R1 lane3b E1 / lane4b E2 同一后果，仅入口由 v2 换成 v3。

**与修复自述的矛盾**：`f09-p4-impl-report.md` §10 族 3 声明「nestedLink/nestedUnlink/v1-v3 alias/linkSwap/ltar-cols-updater 全部汇入」。核验结果：v2/v1 alias、v3 nestedUnlink（→ `dataTableService.nestedUnlink` → `baseModel.removeLinks`）、UiPost、bulk copy/paste（`data-table.service.ts:690/731/770/1085/1093`）**确实汇入**；唯独 **v3 nestedLink 的 `updateForColumn` 分支未汇入** ⇒ 声明失实，族 3 未闭口。

**建议**：在 `ltar-cols-updater.ts::updateForColumn` 加同族守卫（把 `assertLinkWriteAllowed` 提升为可复用并在此调用，或在 `addOrRemoveLinks(baseModel)` 入口统一查 `baseModel.model.synced`），并补 v3 用例（spec 现无 v3 通道用例，见 M2）。

（活体复现步骤留给可联网 lane：建 mm link 同步 → `POST /api/v3/data/{guardTbl}/links/{mirrorLinkCol}/{rowId}`，body 为 refRowId，期望 4xx，预计实得 200。）

## M 系列（minor）

**M1 i18n 键 `msg.warning.syncPasteLinkUnsupported` 是死键**：`en.json:5314` / `zh-Hans.json:3704` 均落位、路径确认为 `msg.warning.*`，但全 nc-gui grep **零引用**；实际 400 文案由 `table-syncs.service.ts:1026-1028` 硬编码英文返回 ⇒ zh-Hans 用户在该拒绝路径只看到英文。属族 4「文案进 i18n」的接线缺口，功能不受影响。

**M2 spec 覆盖缺口**：`table-syncs.Fork.spec.ts:1323-1386` 的 LTAR guard 4 例只覆盖 `addLinks`(:1332) / `addChild`(:1344) + audit-only(:1359) + 普通表不触发(:1380)；**removeChild / removeLinks / reorderLink 无断言**，v3 `updateForColumn` 通道零用例——正是 E1 留存的结构性原因。

**M3 源 link 列被删除后的 junction/shadow 成为无主僵尸**：`table-syncs.service.ts:1454-1501` 的 drop 循环按 `srcColById` 解析类型，源 link 列不存在时落入通用分支（只删 mirror 列 + 映射行），**不**走 `dropMirrorLinkColumn` / `dropShadowForRelated` ⇒ junction 表与 shadow 表（均 synced）随 mapping 残留；`tables.service` 挡写挡删，用户只能 `deleteSync`/`detach` 回收（impl §9 遗留 3 只声明 junction 侧，shadow 侧同族，本轮确认仍存）。

## R1 六族修复的静态核验

| # | 修复声明 | 判定 | 证据 |
|---|---|---|---|
| 1 | updateSync 仅按主映射域清扫 + link 按 desiredLinks 去留 + null=全字段含 links + `[]`→400 | **成立** | `mainColMappings`(:1422)、`desiredLinkSrcIds`(:1434)、null ⇒ `desiredLinks = syncableLinks`(:1379-1382)、空数组校验(:1345-1352)、keep 分支不删列不删映射(:1454-1456) ⇒ 列 id/数据保留、无 500 路径 |
| 1b | 结构变更 → 自动 full-resync 回填 | **成立** | `structureChanged` → `:1634` → `enqueueSyncJob(...,'full-resync')`；纯 keep PATCH 不置位 ⇒ 不投无谓 resync |
| 2 | 双 link 共享一个 shadow | **成立** | `:1569-1594`（shadows/takenTitles 提到循环外 + 播种 + skip deleted）；`ensureShadowForRelated` 命中即返回(:414-415)，key 与播种 key 同为 RT 表 id，与 `fk_related_model_id` 一致 |
| 2b | 删 link 不影响被保留 link 的 shadow | **成立** | `keptLinkRtIds`(:1442-1444) + 引用计数(:1471) |
| 3 | 五入口守卫 + audit 放行 + 引擎 raw-knex 无 bypass | **部分成立，有缺口** | 守卫实现 `:6597-6609`；挂点 5 处 ✓；audit 放行位于 audit 早退之后(:6648-6654) ✓；引擎 junction 写全为 `execAndParse(dbDriver(...).insert/update/delete)`（processor `:890/928/961/972/1014`）⇒ 不经守卫、防环不破 ✓；**缺口 = E1** |
| 4 | paste+link 400 + sourceSchema 不列 link | **成立**（接线见 M1） | 400 早于任何写入(:1025-1029，位于 `Base.getWithInfo` 之前)；sourceSchema paste 分支过滤(diff hunk `@@ -752,2 +752,4`) |
| 5 | deleteSync 主镜像失败 → 保留 sync 行 + 原错上抛 | **成立** | `:1699-1736`：`mainMirrorDeleted` 初值、main 失败后 `Model.get` 判存活、`throw e`/已消失则继续、末尾防御性 badRequest |
| 6 | mark_deleted 两档 junction 配对一致 | **成立** | processor `:486-501`（`orphanedMainPks` = pendingDeletes ∪ flagged pendingUpdates），变量 `pkKey/remoteDeletedCol/markDeleted` 同函数(:217/224/233) |
| 附 | createSync 失败清理逆序（junction→shadow→mirror） | **静态成立（未活体）** | diff hunk `@@ -1220,2 +1227,6` |

质量门替代核验：**用例数与声明自洽** —— 三个 Fork spec 的 `it(` 计数 = 14 + 12 + 34 = **60** ✓（P4 批 47 = 26+21，R1 批 +13 = 34，与 commit message「13 new cases, 47→60」吻合）；无 `it.skip`/`it.only`。`tsc` / `jest` **未执行**（沙箱禁 node）。

## 未核验清单（因环境限制，非「通过」）

1. R2 重点 1–7 的全部**活体**断言。
2. :8080 进程 dist 是否确为 5368ef1366 构建（无 ps/lsof，health uptime 反证力不足）。
3. `tsc 0` 与 `jest 60/60` 的**执行**结果（仅静态核对了用例计数与断言合理性）。
4. E1 的活体 200（仅静态调用图证明该路径不经守卫）。

## 纪律

只读（`git status` 的 `packages/` 无本 lane 改动）；未构建/未重启/未 pkill/未跑 `dev-backend*.sh`；无 psql、未提权；未读他路报告（`r2-p4-lane4.md` 等未打开；R1 lane3b/lane4b 为任务书指定对照材料）；未创建测试数据/测试账号；无凭证写入。

---

**待落盘提示**：本次会话沙箱禁写（`write_file` 被拦，bash 亦禁 `curl`/`node`/浏览器 MCP），上述全文即 `.work/ee-ce/r2-p4-lane3.md` 的最终内容，需在可写环境落盘；其中 E1 为必修 error，建议 R2 修复批处理时连同 M2 的 v3 用例一并补齐。
