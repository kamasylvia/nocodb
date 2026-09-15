# rc-f10-lane-fconv — F07 Snapshots + F10 Dashboards 收敛确认（int + rev）

HEAD = 294c79ef5d（工作树干净）。隔离声明：未读任何 r*.md 报告；只读 TASK.md / 仓根 AGENTS.md / 源码 / 运行系统。

## int（全实测，nocodb-dev，资源前缀 fconv_ 已清理含孤儿 schema DROP）

### F07 Snapshots — 39/39 PASS（脚本 `.work/ee-ce/rc-f10-fconv/f07_int.py`）
- 生命周期：create → processing → completed；副本 base 存在、title 前缀 `Snapshot`、含 fconv_t1 表、数据 2 行一致；restore → 新 base `fconv_snap_src (restored)` 含表含数据；delete snapshot → 200、快照行 404、副本 base 404 且 pg `deleted=true`。
- 删源 base 联动：DELETE baseC → `nc_snapshots` 行清零（pg 直查）+ 快照副本 base 连带软删（pg `deleted=true`）。
- 副本缺失路径：completed 后手动软删副本 → GET status=`error` → restore 400 → delete snapshot 仍 200 且行移除。
- 校验/权限：title bool/int/dict → 400；513 chars → 400；512 chars → 200（列宽一致）；processing 互斥并发 ×2 至多 1 成；跨 base GET/restore/DELETE ×3 → 404 且快照完好；editor GET/POST → 403。
- 备注两处非缺陷确认：restore 为异步复制（duplicateBase 排队即返回 `{base_id}`），completed 判定语义含数据就绪（processor 在 importModelsData 后才清 `status='job'`），测试按该语义轮询后数据一致；editor 账号用自建 fconv_ed@ce-ee.local。

### F10 Dashboards — 36/36 PASS（脚本 `.work/ee-ce/rc-f10-fconv/f10_int.py`）
- CRUD：POST → 200（id `dash` 前缀 + order 递增）→ list → 单条 → PATCH 重命名 → DELETE → GET 404。
- 校验：重名 create/PATCH 撞车 → 400；title int/bool/dict/null → 400；`''`/`'   '` → 400；256 → 400（255 → 200）；desc 非串 create/PATCH → 400；PATCH `description:null` 清空 → 200。
- 跨 base：baseE 路由访问 baseD dashboard GET/PATCH/DELETE ×3 → 404 且本体完好。
- editor（baseD 成员）：list/create/patch/delete ×4 → 403。
- 并发同 title ×5 → **恰 1 成 4×400**（`nc_20260913_dashboard_title_unique` 唯一索引兜底 check-then-insert 竞态）。
- 删 baseF → `nc_dashboards_v2` 行清零（pg 直查）。

## rev（当前 HEAD，范围 6ab23da061..HEAD 27 文件）

- 后端找茬面：base-snapshots.service / BaseSnapshot / base-snapshots.controller / dashboards.service / Dashboard / dashboards.controller / utils/acl / extract-ids / Base.ts hook / migration 全部终核——**未发现有 API 可达链的缺陷**。要点：snapshot restore 的 `fk_workspace_id` 经 metaInsert2 注入（实测 restore 成功佐证）；extract-ids dashboardId 分支只做 base 上下文回填不做提权（跨 base 404 / editor 403 实测佐证）；cleanupByBaseIdWithCopies 在 Base.delete 与 softDelete 双挂（T2/T6 实测）；唯一索引 migration 先去重后建索引、数组注册位置在时序末尾，正确。
- 前端面：store/dashboard.ts、CreateNewActionMenu.vue（`!blockAddNewDashboard` gate）、dashboard/[dashboardId].vue、BaseSettingsMenu、project/View.vue（`baseSnapshotList` 新 ACL key 替换 `manageSnapshot`）、Snapshots.vue 终核——无可达缺陷。useEeConfig 仅解 `blockSnapshots` / `blockAddNewDashboard` 两 gate，`isEeUI` 未翻转。
- 一致性：[CE-EE] 覆盖 23/27 改动文件；4 个 0 标记文件 = lang/en.json、lang/zh-Hans.json（纯 i18n 文本）+ models/index.ts、XcMigrationSourcev2.ts（纯 import/注册行，与 F05 既有装配行模式一致）——豁免判定，如实记录。Api.ts / nocodb-sdk / ncUtils.ts（isEeUI）零改动（git diff 验证）。前端 lib/acl.ts creator 块含 8 项、editor 块无 —— 与后端 acl.ts（creator exclude 型放行、editor include 无）双侧一致。
- 测试基建（实跑）：后端 `tsc --noEmit` exit 0；jest Fork 桶 26/26（2 suites）；vitest 17/18 文件过（130 tests passed | 5 skipped），唯一失败 = `pwa-self-destroying.test.ts`（上游遗留，import 已删 pwa.config，AGENTS §3.2 已记录），`formula-url-xss` 并发抖动单跑 5/5 过。
- AGENTS §2.1 准确性：逐条核对成立——快照=异步完整副本、副本为活 base（fork 限制如实）、restore 复制为新 base、删快照走 softDelete、`duplicateBase` options 确无 base variables 复制通道（processor 仅 excludeData/excludeHooks/excludeViews/excludeScripts）。
- 工作树：`git status` 空。

## issues（均为 minor / 观察项，无 code error）

1. `.work/TODO.md:17`（F10 行）：仍写「model/migration 已有，补 controller + UI」——滞后于实际（F10 已实现并入库 6eb3b80c1d + 294c79ef5d，本轮收敛确认）。建议改为「实现完成，会审收敛中」。
2. `.work/ee-ce/GOAL-STATE.md:9`：行「当前功能: F07 Manage Snapshots」未随 F10 R2 更新（同文件第 5/7 行已是 F10 语境），行间不一致。建议同步为 F10。
3. （观察项，不计 error）F07/F10 无专属新增单测（jest 26 个与 vitest 130 个均为既有回归集）；两功能正确性由本轮 int 75 断言实测覆盖。
4. （观察项，不计 error）restore 返回时副本 job 尚在跑（上游 duplicateBase 排队即返回语义）；UI 直接跳转新 base，大数据集会短暂看到空 base 后数据就绪。注释已声明异步，属设计选择。

## 裁决

**int PASS（F07 39/39 + F10 36/36）+ rev 0 code error（2 minor 文档同步 issue + 2 观察项）→ 总裁决 PASS（本路）。**
