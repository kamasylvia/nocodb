# F09 P4 R3 — lane 3（安全审计重点路）报告

**结论：PASS / 0 error + 2 minor**

审查基线 = 840c4218aa（R2 修复批）；后端 :8080 存活（pid 38535，`GET /api/v1/health` → 200），dist 双条件核验：dist mtime 2026-09-22 01:34:28 < 进程启动 01:41:12 ✓，且 dist 内 grep 命中守卫特征串（`manage the links in the source table` ×2、`F09 P4-R2(lane3 E1)` 注释）→ **:8080 运行的确含 R2 E1 修复**。账号前缀 `f09p4r3l3-*`（owner/editor/ui 三账号，API/UI 分离）；camoufox session `f09p4r3l3`。脚本：`.work/ee-ce/f09p4r3l3-run1.sh`（v3 守卫活体，ALL PASS）、`f09p4r3l3-run2.sh`（安全面活体，ALL PASS）、`f09p4r3l3-ui-setup.sh`（UI 环境）。

## E 系列

无。

## R2 E1 修复回归（活体，全部通过）

**修复实现核验**（840c4218aa diff）：`ltar-cols-updater.ts::updateForColumn` 入口最前（先于 checkPermission 与任何写入）inline `baseModel.model?.synced` 检查 → `prohibitedSyncTableOperation`（422 同族，customMessage 指引去源表管理 links）；`assertLinkWriteAllowed` 改 public 供后续复用。守卫判定只依赖 `model.synced`，与角色无关——editor/owner 对镜像均拦，对普通表不触发，行为与 R1 五入口一致。

**调用图闭合**：`LTARColsUpdater` 全仓仅两调用方——v3 `nestedLink`（单列档 `updateForColumn`，新守卫处）与 `BaseModelSqlv2.updateLTARCols`（批量档，内部走 `trxBaseModel.removeLinks/addLinks` 五入口守卫，R1 已覆盖）。v3 DELETE links → `dataTableService.nestedUnlink` → `baseModel.removeLinks`（R1 守卫）。引擎 junction 写仅 `recomputeJunctionPairs`/`cleanupJunctionOrphans` 两私有 raw-knex 方法，不经 updater → **无 bypass 需求，也无误伤面**。

**活体**（run1，三层 sync：mirror+shadow+junction，junction 初始配对 2）：

| # | 断言 | 实测 |
|---|---|---|
| 1 | owner 对镜像 `POST/DELETE /api/v3/data/:base/:modelId/links/:colId/:rowId` | **422** `ERR_SYNC_TABLE_OPERATION_PROHIBITED`（Link operations ... prohibited）✓ |
| 2 | **editor** 对镜像 v3 POST/DELETE（R2 症状 200/201） | **422** 同上，**不复现** ✓ |
| 3 | 拦截后 junction 配对数 | 仍 = 2，无部分写入 ✓ |
| 4 | 合法路径不误伤：owner 源普通表 v3 POST links；editor dest 普通表 v3 POST/DELETE links | 200 / 200 / 200 ✓ |
| 5 | 读路径：owner v3 GET 镜像 links | 200（返回 shadow 关联数据）✓ |
| 6 | v3 PATCH 镜像标量 | 400 `Column "Title" is readonly column and cannot be updated`——P1 镜像列 readonly 既有语义，非守卫误伤 ✓ |
| 7 | 引擎通道无 bypass 佐证：源加配对 → resync | junction 2→3，raw-knex 通道照常回填 ✓ |
| 8 | P2 站位：editor junction 直写 / editor bulk 删镜像行 | 422 / 422 `ERR_SYNC_TABLE_OPERATION_PROHIBITED` ✓ |

活体勘误（供后续 lane 参考）：v3 links 端点完整路径为 `/api/v3/data/{baseId}/{modelId}/links/{colId}/{rowId}`——baseName 段**真实参与解析**（占位 `x` → 422 `ERR_BASE_NOT_FOUND`）；v2 bulk 删行 body 需 `[{"Id":<id>}]`（裸 `[1]` → 400 参数错）。

## 安全面（run2，全部通过）

1. **paste 凭据面**：paste sourceSchema password gate 生效（无密码 → `{passwordProtected:true}`；错密码 → 400 Invalid shared view password）；paste schema **不列 link 列**（`columns=["Title","Qty"]`）；**paste+link createSync → 400**，消息含 browse-mode 指引（凭据升权面：share 凭据仅单视图，link 同步会拉全相关表——createSync 注释与实现一致）；paste 纯标量 createSync 成功不误伤。静态核验 paste 分支 `syncableLinks` 经源 context 真实加载 → 400 路径可达（非死代码）。
2. **响应凭据剥离**：createSync / GET sync 详情 / GET sync list 三响应均 **零命中** `source_uuid` / `source_password_hash`。静态闭环：`toType()` 白名单字段（sync 行级不含凭据列）+ `listSyncs`/`getSync` 对 mappings 显式 delete（P2-R3 strip）+ createSync/updateSync/detach/freeze/resume 全部经 `getSync` 返回。
3. **detach ACL**：editor 对 detach → 403；owner detach → `{ok:true,tableId}`，mirror `synced=false` + 插行 200（三表转正可写语义）✓。
4. **ACL 抽查**：editor 对 table-syncs list/create/resync/detach/delete 五端点 → **全 403** ✓。

## P1-P3 站位回归（抽查）

- **守卫链**：junction 直写 422、editor 删镜像行 422（上表 #8）——P2 语义无回归。
- **AUTO 双档**：realtime sync 建成 active，源插行 **~2s** 出现在 mirror（P3 realtime 链路无回归）；manual 档 resync 回填正常（run1 #7）。
- **三层构建**：run1/run2 两次建 sync 均 main+linked_shadow+junction 三 mapping 齐、full-create 后 junction 配对数精确（2），attach/detach 面正常。
- **UI 活体（轻量）**：editor（ui 账号）打开 dest base——树菜单三层表条目可见；aria snapshot 抓到 **`button "New record" [disabled]`**（editor 对 synced 镜像 UI 卡 gate 真实 DOM 证据）；首帧截图 grid 渲染 Title/T2s link 徽章与 API 数据一致（p1=1 link / p2=0）。

## M 系列（minor，均为 R2 已知遗留维持，不新增）

- **M1（维持）i18n 死键** `msg.warning.syncPasteLinkUnsupported`：en.json/zh-Hans.json 均在、组件零引用；实际 400 文案仍为后端硬编码英文（run2 活体确认）。功能不受影响。
- **M2（维持）spec 无 `updateForColumn` 通道用例**：`table-syncs.Fork.spec.ts` 的 LTAR guard 4 例仍只覆盖 addLinks/addChild/audit/普通表；R2 E1 修复仅靠本轮活体锁住（422 实测），**无单测回归锁**。建议后续补一条 updateForColumn 守卫用例。
- （记录）M3（源 link 列删除后 junction/shadow 僵尸）维持 R2 判定，本批未涉及。

## 质量门

- `npx tsc --noEmit`（packages/nocodb）：**exit 0**。
- `npx jest --testPathPattern 'Fork'`：**60/60，3 suites 全过**（116s）。
- Vite URL 门：`npx vitest run test/formula-url-xss.test.ts --config test/vite.config.ts`：**5/5 过**。注：默认 10s hook timeout 在本机外置盘 IO 下超时误报（首跑 `Hook timed out`，`--hookTimeout 60000` 重跑全过）——环境慢非断言失败。

## 未覆盖（环境/范围限制，非「通过」）

1. UI link cell 写路径的 422 toast 展示与 zh-Hans 文案：camoufox 截图存在已知帧缓存问题（AGENTS §7），本轮会话 grid 行数据在 dev 前端持续不渲染（API 层 200 正常，属 :3000 dev 环境态，非后端缺陷）；后端 422 与 editor gate 均已由 API 活体 + aria disabled 按钮覆盖。
2. zh-Hans 编辑器全弹窗走查（其余 lane 的 UI 重点分工项）。
3. 删除用户账号：NocoDB 无删除用户 API，`f09p4r3l3-{owner,editor,ui}` 三账号保留（全前缀可辨，与历轮 lane 账号同惯例）。

## 纪律

只读审查（`git status` 无源码改动；本 lane 仅新增 `.work/ee-ce/f09p4r3l3-*.sh` 脚本与本报告）；未构建/未重启/未 pkill/未跑 `dev-backend*.sh`；无 psql、未提权；隔离未读他路 R3 报告（对照材料 R2 lane-prompt/r2-p4-lane3/impl-report 为任务书指定）；测试 base 全部删除（清零核验：bases 列表 `f09p4r3l3*` 计数 = 0），测试记录行/记录随 base 删除；无凭证写入 git 跟踪文件（账号口令仅存于 `.work` 白名单脚本，遵循既有惯例）。
