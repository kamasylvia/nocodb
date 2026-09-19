# F09 P3 R2 lane5 审查报告（UI 验证重点路，2026-09-19）

**结论：1 error + 1 minor**

- 审查员：lane5（f09p3r2l5-* / camoufox session f09p3r2l5，已关）
- 基线：27efcca491（R1 修复批，HEAD）；:8080 = pid 50994（01:27:58 启动，晚于 dist mtime 01:06），dist 内 grep 到全部 4 处 P3-R1 修复标记（lane1/2/3 bulk tap、lane1/2/4/5 no-status-filter、lane3 restore tap、lane4 catch-up rework）——确为修复后 dist；全程零构建/零重启/零 psql
- 测试数据：`f09p3r2l5-` 前缀。src base pynpoczht3ftarc / dst base pes3fjn17159yjs、syncs ×3、镜像表 ×2——全部删除，infra 视角 bases 列表复查 **f09p3r2l5 残留 NONE**；src 默认视图共享态已复原（allow_sync=false + uuid=null）。账号 f09p3r2l5-api / f09p3r2l5-ui / f09p3r2l5-ed @example.com（密码同本轮模板 Xc9!vR2tQw7#pLm4）**保留供后续轮次**（沿用 R1 lane4 先例）；两账号已入对应 base 角色组（api=owner×2、ui=owner/owner、ed=editor），清理 base 后自动随删
- 截图存证：/tmp/f09p3r2l5/（wizard-step2-dual / menu-active / menu-syncing2 / delete-dialog / editor-overview 等 12 张）

---

## ERROR 1（E-lane5-1）：paused→resume 补齐丢弃 delete 类事件——no-sweep catch-up 的结构缺口，与任务书「全部追平」不符

**现象（活体，UI 驱动 + API 验证）**：
1. UI 树菜单 Pause sync（status=paused 实证）。
2. paused 窗口内源表三写全部 200：update Id=1 → `seed-a1-paused`、insert → `paused-ins`、**delete Id=3（seed-a3）**。
3. 窗口内镜像冻结（6 行旧态）✓（CAS/paused 不泄漏语义正确）。
4. UI 树菜单 Resume sync → 镜像终态 7 行：`seed-a1-paused` ✓、`paused-ins` ✓、**`seed-a3` 仍在（ghost，RemoteDeleted=false）**——update/insert 补齐，**delete 类丢失**。

**根因**：27efcca491 的 catch-up 重设计 = `affectedIds=null` 的 incremental 走「无消失扫描的全量 upsert」（processor :318-348 旧分支）。insert/update 靠全量 upsert 补齐，但**删除传播只有两个机制**：affectedIds 路径的 `readByPk→null→applyDeletePolicy`，或 full-run 的消失扫描（sweep）。no-sweep catch-up 两者皆无——源里已删的行不在 pull 结果中，upsert 天然看不见删除。Syncing 窗口的 delete 事件（CAS miss → markSkipped → 同一 catch-up）**同型丢失**。任务书 R2 重点 2 宣称「paused 三写 → resume → 全部追平」「插/改/删 → 补齐 → 数据最终一致」——delete 腿不成立。

**重要交叉证据（基线 vs 工作树）**：工作树存在**未提交**的 processor 演进（`git diff HEAD` 唯一 packages/ 变更，31 行）：catch-up 改为 **fall-through 到带消失扫描的全量 pass**（注释 `P3-R2(lane4 E1')`，明言「The previous no-sweep catch-up could not see in-window DELETE events … the sweep is safe and required here」）。即实现方已识别本缺口，但该修正**未提交、未编译部署**（:8080 dist grep `P3-R2(lane4 E1')` = 0，`E2/E3): catch-up = full upsert pass without` = 1）——本轮审查基线上缺口活体存在。裁决建议：按工作树 E1' 提交+部署后回归（注意 E1' 恢复 sweep 后，需复核 R1 lane4 E2 关心的「部分拉取误删」前提——E1' 语境下 catch-up 已是全量拉取，sweep 安全性成立）。

## MINOR 1：Convert to regular table 无确认弹窗（与 Delete sync 不对称）

- UI 树菜单 Delete sync → 确认弹窗（表名 + Cancel/Delete sync，截图 delete-dialog.png）✓；Convert to regular table → **点击即执行**（sync 列表即刻消失、synced=false、镜像可写），无任何确认。detach 属破坏性较小但仍不可逆的操作（sync 配置一去不返），与同菜单 Delete 的确认流不对称。建议补确认或至少 toast。非阻断。

---

## PASS 面（全部实测/截图/源码审）

**质量门**：`npx tsc --noEmit` 0；jest Fork 桶 **44/44**（3 套件）；Vite URL 编译法 4/4=200（CreateNewSync.vue / TreeView/Table/SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts，走 `/_nuxt/` 前缀，产物含 `blockTableSyncAuto = computed(() => false)`——裸路径 200 是 SPA fallback 假象，已甄别）。

**向导（UI 活体，camoufox）**：
- Browse/Paste 双模式；三步流（源选择→字段→Sync settings）完整可走 ✓
- **Automatically/Manually 双档**：两单选均可用、默认 Manually；选 Automatically 建成 `sync_trigger:'realtime'`（DB 落库）+ 镜像 3 行种子 ✓；删除策略双档（Deleted 默认/Retained）在位 ✓
- paste 模式（shared view uuid）三步建成 manual sync ✓（P2 向导流回归）

**E-bulk 修复回归（本轮核心）**：源表**数组体 POST 3 行**（v2 标准 bulk，`[bulk-e1..e3]`）→ 镜像 **1.13s** 内 3 行全部到达（R1 症状「零传播、5s+ 不增」零复现）；单行 update → 镜像 1.16s 跟随；镜像列带 synced 闪电标、UI 树即时可见（截图 dst-tree.png）✓

**afterBulkRestore tap**：源码审 pass（:5901 处 tap，同 `!synced` 守卫族 + extractPksValues）；**运行时无调用方**——全 src grep `afterBulkRestore` 仅定义+接口两处，CE 无 trash-restore 数据端点触发它（上游预留 hook）。tap 防御性正确，待上游接通即生效。观察注记，非缺陷。

**树菜单三态 + Syncing 守卫（UI 活体）**：
- active：Sync now / Pause sync / Convert to regular table / Delete sync 全项（截图 menu-active.png）✓
- paused：Resume sync 项替换 Pause ✓
- **syncing**：1200×4 行填充 + resync 拉长窗口，菜单活体捕捉——仅「Syncing」状态标签（旋转图标），**Sync now/Pause/Convert/Delete 全部隐藏**（截图 menu-syncing2.png，与 SyncMenuOptions.vue :119/:131/:169/:181 的 `status !== Syncing` 守卫一致）✓

**paused 窗口语义**：三写全 200 而镜像冻结 ✓（paused 不泄漏）；Resume 后 update/insert 补齐（~1s 级）✓——delete 丢失见 E-lane5-1。

**删除流三腿（UI 活体）**：
1. Delete sync：确认弹窗（表名明示）→ 确认 → sync 行消失 + 镜像表 404 ✓
2. Convert to regular table：sync 即刻消失、表 `synced:false`、insert 200 可写 ✓（无弹窗 → MINOR 1）
3. Pause/Resume：菜单项切换 + 补齐行为如上 ✓

**Manual sync P1 行为不变**：源 insert `manual-check-1` 后 5s manual 镜像 25 行无此行（不跟随）✓；UI Sync now → API 查询命中（全量对齐）✓

**editor Overview 卡 gate**：Overview.vue:134-141 `isUIAllowed('sourceCreate')` gate（[CE-EE] F09 P2-R3(lane5) 注释）。owner：Overview 页 NocoDB Sync 卡 VISIBLE；editor：`/#/nc/:id/overview` 直达被重定向回表视图（editor ACL include 无 projectOverviewTab + 无 sourceCreate，acl.ts :121/:126 vs editor 块）——gate 双层成立 ✓

**camelCase selectedFields 别名（R2 重点 4）**：PATCH `{"selectedFields":["Title","Qty"]}` 200 → GET `selected_fields` 生效（非 no-op）✓；减列 `{"selectedFields":["Title"]}` → 镜像 Qty 列 drop ✓；snake/camel 混合 body 200（snake 优先，语义无冲突）✓。3 连稳定 200（首次偶发 400 未复现，不立案）

**P1 守卫 UI 面**：镜像表 New record 按钮 disabled（synced 表 UI 禁写）✓；树节点 synced 闪电图标 ✓

## 方法学注记

- **UI 粘贴（canvas 网格）无法由 harness 触发**：NocoDB 新版 canvas grid（`isCanvasTableEnabled=!ncIsPlaywright()`，DOM 无单元格）。合成 paste 事件经捕获探针证实可达 document 但被 handlePaste 守卫链（canPasteCell 等，useCopyPaste.ts:262-284）拒绝，trusted 事件不可伪造。E-bulk 主证据改由 v2 数组体 POST 覆盖（同一 afterBulkInsert tap，任务书「粘贴/CSV 同形态」即此路径）；前端 paste 守卫链本身非本轮审查对象。
- 共享 :8080 多 lane 流量，API 断言均按本 lane 资源 id 归因；一次 camelCase PATCH 400 疑连接层偶发（未复现）。
- 未覆盖：多 worker 补齐丢失（单实例无法构造）；Retained（mark_deleted）策略在 paused 补齐下的行为（E1' 部署后应一并回归——sweep 恢复后 mark_deleted 的 reappear 清 flag 分支已有，活体未跑）。
