# F09 R8 lane1 审查报告（f09r8l1-* / session f09r8l1）

结论：**PASS（0 error + 1 minor + 1 观察项）**。HEAD = ca5416fc8a（后端 :8080 即 R7 修复态 9c4db33fe1，无后端改动）。

## A. 编译健康（先行门，PASS）

- `/_nuxt/components/project/Action/CreateNewSync.vue` → 200；`/SyncMenuOptions.vue` → 200（500 = 编译错误，未出现）
- base 页（grid/base-home）实测：`vite-error-overlay` 0、无 "error loading dynamically imported module"、title 正常
- R7 坏页已修复确认

## B. R5 四象限 + E1 六格（PASS，方法学注记见末）

调用者 dest-qualified（dest 无行 + ws-no-access 者先被 dest 侧 ACL 403 拦截，属守卫顺序，非产品缺陷；下述 Q2*/Q3*/C2*/C4* 为 dest-creator 临时提权后测得的 service 层真实判定）：

| 格 | 结果 | 预期 |
|---|---|---|
| Q1 非私有+零行+wsc→srcB | 200 / plat 200 | 200 |
| Q2* bedit 显式 editor→srcA | 200 / plat 200 | 200 |
| Q3* zero→srcA（dest-qualified） | 404 ERR_BASE_NOT_FOUND / plat 403 | 404 |
| Q4 wsc inherit→srcB | 200 | 200 |
| Q5 私有+零行+wsc→srcP | 404 / plat 404 | 404 |
| Q6 wsna inherit→srcP 私有 | 404 | 404 |
| C1 非私有 no-access+ws-creator | schema 404 / plat 403 | 404/403 |
| C2* 非私有 no-access+ws-noaccess | schema 404 / plat 403 | 404/403 |
| C3 私有 no-access+ws-creator | schema 404 / plat 404 | 404/404 |
| C4* 私有 no-access+ws-noaccess | schema 404 / plat 404 | 404/404 |
| C5 wsc createSync→no-access 源 | 404 + dest tables `[]`（不落镜像） | 404+无镜像 |

## C. ACL 十端点（PASS）

owner 全 200；editor/viewer 全 403；匿名全 401；delete(404-id) owner 404 其余 403/401；resolveLink own 501 / editor 403；realtime trigger own 400（付费锁保持）。

## D. 引擎 e2e（PASS）

- full-create：3 行，RemoteId=1/2/3 对照正确；列 `RemoteId/RemoteDeleted: system=true show=false`，其余 system 列 show=true（双保险在位）
- resync upsert：源 +r4 → dest 4 行
- 删除双策略：`delete` 腿删源 r4 → resync 后 dest `["r1","r2","r3"]`（行消失）；`mark_deleted` 腿删源 rb1 → dest `rb1.RemoteDeleted=true, rb2=false`
- freeze→paused / resume→active / deleteSync→镜像表 404 + dest tables 清空（trash 语义）
- 注：v2 单行 DELETE 路径形为 `DELETE /records` + body `{"Id":N}`（`/records/:rowId` 404 系我初始形状误用，非产品问题）

## E. 守卫链（PASS）

- editor 对镜像：PATCH 400 / INSERT 400 / DELETE(body 形) 422；grid 读 200（读允许、写全拒，符合设计）
- editor createSync / source-schema → 403；allow_sync 缺失 createSync → 400；坏源表 create → 404
- 沿袭（不计）：source-schema 对无 allow_sync 视图仍 200 返回（仅 create 侧强制，R 列已知灰区）；title `RemoteId` 被改写为 `RemoteId_1` 后成功（保留名守卫仅 400 特定名，非全量保留——与"保留名 400"已知项表述有差，实测如实记录，落观察项不断言违反）

## F. UI 段（本轮重点）

1. **树菜单新鲜度 PASS**：Sync now（API active）→ 重开 `Synced table + Sync now + Pause`；freeze（API paused）→ 重开 `Paused + Sync now + Resume`；resume（API active）→ 重开 `Synced + Pause`。open-watch 生效。
2. **向导创建流 PASS**：step0 可搜索（`srcA`→命中 1 项、`tbl_a`→命中表）→ schema step（view + 全字段默认）→ settings step → Create sync：modal 关闭、**树即时出现 `f09r8l1_tbl_b_…`（无刷新）**、API status active、无 toast 堆积（0 notices）。
3. **删除流**：非当前打开表删除 → URL 不变、树即时移除（PASS）；当前打开表删除 → API 404 + 树移除已验证，**跳转目标 URL 未及观测**（confirm 后浏览器 session 掉线，见观察项）；删至 0 表 → **minor1**。
4. **editor 三入口 PASS**：`proj-view-btn__create-new-sync` false、`proj-view-tab__syncs` false、树菜单无 `table-sync-menu-*`、toolbar 无 sync 项；API 侧 create/source-schema 403 fail-closed。

### minor1：删至 0 表后 URL 未归一到 base 根

删 aclprobe（最后一表，当前正打开）后树空 + 主区 "No tables"（内容态正确），但 URL 仍停留在 stale grid 路径 `/nc/<base>/<tbl>/<view>/…`，未跳 base 根 URL。用户未被卡死（空态正确），仅 URL 陈旧。cosmetic。

### 观察项1：当前打开表删除的自动跳转 URL 未观测

ui-sync 删除 confirm 点击后 session 掉线（:3000 代理抖动，本轮第 5 次掉线后均自恢复）；API 404 + 次日树（重访树仅剩他表）证实删除与树刷新生效，但"自动跳剩余首表 URL 与主区一致"断言无直接证据。建议他路若已覆盖则采信他路。

### 方法学注记（给 orchestrator）

ws-no-access 且 dest 无 base 行的调用者调 source-schema，先命中 dest 侧 ACL 403（到不了 assertSourceReadAccess）。R6/R7 prompt 的"零关系 404"格若调用者无 dest 行，实测恒为 403。建议后轮 prompt 明确 dest-qualified 调用者（或接受 403/404 双 fail-closed 码）。

## G. 质量门

- **前端编译健康（本轮指定门）：PASS**（附录 A 双 200 + 页面无 overlay）
- `tsc --noEmit`：**未完成**（300s 超时，按纪律不重试）
- `jest table-syncs.Fork.spec`：**未完成**（首跑 280s 无输出超时；重跑后台进行中，落盘时仍无结果）
- diff 审计：`71896a841f..HEAD` 非 `.work` 文件仅 5 个（Node.vue 1 行 + SyncMenuOptions + CreateNewSync + jobs-map + table-syncs.service），`store/sync.ts / syncUtils.ts / acl.ts / ncUtils.ts` 零改动；`blockTableSync=false`、`blockTableSyncAuto=true` 保持；后端 service 全带 `[CE-EE] F09` 标记
- 回归探针：F07 snapshots 200、F05 variables 200（F10 dashboards 路径 404 系我探针路径误用，不作结论）

## H. 清理

6 base（srcA/B/P/N/P2 + destD）+ 全部 sync 已删；测试账号残留于 dev 库（既往轮同例，无 base 归属）。截图 2 张落 `/tmp/f09r8l1/`（tree-before.png 等，流程副产物）。

---
lane: f09r8l1 · 账号前缀 f09r8l1-* · 无他路报告读取 · 无源码修改 · 后端零重启/pkill
