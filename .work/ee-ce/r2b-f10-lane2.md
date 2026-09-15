# r2b-f10-lane2 — F10 Create Dashboard R2 收敛确认（第 2 路：int + rev）

日期：2026-09-13。基线 commit 294c79ef5d（R1 fix），工作树 clean。
后端 http://127.0.0.1:8080（dist/main.js，PID 84805；测试窗口内其它 lane 重启过一次，两次 401 波动为环境噪音，非产品行为）。DB = nocodb-dev（pg8000 实测查证）。资源前缀 f10r2c_，测完已清（dashboard 残留 0；测试 base 全删）。

## issues

### ISSUE-1（P1，必修）R1 的 DB 级同 title 唯一约束实际未生效 — 迁移接错源 + getMigration 缺 case

**1a. `getMigration` switch 缺 case → 拥有 v2 迁移的存量库升级后启动即崩**
- `packages/nocodb/src/meta/migrations/XcMigrationSourcev2.ts:80`（import）、`:185`（migrations 数组）有 `nc_20260913_dashboard_title_unique`，但 `getMigration` 的 switch（:194-368，末 case 为 `nc_098_default_workspace`）**没有对应 case** → 返回 undefined。
- knex 3.1.0 `lib/migrations/migrate/Migrator.js:497-514`：pending migration 执行 `migrationContent[direction](trxOrKnex)`，undefined → `TypeError: Cannot read properties of undefined (reading 'up')` → migrate.latest 拒绝 → 启动失败。可达链：任何含 `xc_knex_migrations`（v1 表）的存量部署跑 v2 迁移时必炸。

**1b. 本部署/全新安装走 v0 源，v2 迁移永不执行 → unique index 不存在**
- `packages/nocodb/src/meta/meta.service.ts:1127`：`hasTable('xc_knex_migrations')` 为 false 时 v1+v2 迁移块整体跳过，仅跑 `XcMigrationSourcev0`。全新安装与 nocodb-dev 均属此形态。
- **DB 实测**（pg8000，nocodb-dev）：迁移表仅 `xc_knex_migrationsv0`；`nc_dashboards_v2` 上索引仅 pkey / share_uuid_idx / nc_dashboards_context / oldpk_idx，**无 `nc_dashboards_base_title_unique`**。
- 后果：并发防重只剩 service 预检查（check-then-insert，`dashboards.service.ts:49-54`）+ 单进程 list 缓存串行化。T3 实测 1×200/4×400 达标是**碰巧**（单实例、缓存热）；多实例部署或缓存未命中窗口内可全部成功写库。R1 commit message 声称的"concurrent same-title creates cannot all succeed"在真实部署形态下不成立。
- 修复方向：同 schema 变更需落在 v0 源（全新安装路径，如 nc_001_init 加约束或新增 v0 迁移）+ 保留/修正 v2 路径的 case 映射；二选一或双落，须覆盖两种部署形态。

### ISSUE-2（low）description 无长度上限，600 字符返回 200（验收矩阵要求 400）
- 实测：POST base A `{"title":"f10r2c_t1e_..","description":"d"×600}` → **200**（行已建）。
- `dashboards.service.ts:40-46`（create）与 `:71-78`（update）只校验类型不校验长度；DB `description` 列 = text 无限。矩阵偏差，客户端可达。低危（无溢出面，纯规格偏差）。

### ISSUE-3（low）title 长度校验 create/update 不一致：同一 title create 200、update 400
- create 先 trim 后测长（`dashboards.service.ts:31-39`）；update 先测原始 length（`:89`）。
- 实测：`title = "z"×254 + "  "`（原始 256，trim 后 254）→ CREATE **200**；同形态 title PATCH 另一 dashboard → **400**。
- 行为不一致（update 偏严），非安全洞；与 ISSUE-2 同批修 service 校验时可顺手对齐（统一 trim 后测长）。

## int 实测通过面（对照验收矩阵）

| 项 | 结果 |
|---|---|
| T1 非法输入矩阵 | title 123/true/{}/[]/null/""/"   "/缺/256/601 → 全 **400** ✓（10/10）；desc 123/true/{}/[] → **400** ✓（4/4）；desc 600 → 200 ✗（=ISSUE-2）。边界 title 255 → 200 ✓ |
| T2 跨 base | A 的 dashboard id 走 B 路由：GET/PATCH/DELETE → **404×3** ✓；A 路由 sanity 200 ✓ |
| T3 并发同 title ×5 | **1×200 + 4×400**，无 409/5xx ✓（但 DB 层无兜底，见 ISSUE-1b） |
| T4 ACL | base-viewer（f10r2c 经 base invite roles=viewer）：list/get/post/patch/delete → **403×5** ✓；creator（f01e2e）：list/get/post/patch/delete 全 **200** ✓，PATCH 持久化 ✓，删后 GET 404 ✓ |
| T5 base 删除清行 | base D 删除 → `nc_dashboards_v2` 该 base 行数 **0** ✓（另 A/B 及首跑 A/B/D 共 5 base 删除后均 0 ✓）；代码侧 `Base.softDelete`（Base.ts:461）与 `Base.delete`（Base.ts:714）两路均调 `Dashboard.deleteByBaseId` ✓ |

## rev 复审通过面

- 路由收敛：controller 仅 base-scoped 5 条（dashboards.controller.ts:28-89）；全仓（nocodb src / nc-gui / sdk）grep 无 `/api/v2/meta/dashboards` dashboard-only 残留 ✓。service `getDashboardWithBaseCheck` 的 baseId 可空分支成死代码但无害。
- `Dashboard.insert`：`this.get(context,id)` 先于 `NocoCache.appendToList` ✓（Dashboard.ts:121-128）；cache list key `dashboard:<baseId>:list` 与 CacheMgr 构造（CacheMgr.ts:275-279）一致 ✓。
- ACL op 对齐：controller 用 dashboardList/Create/Update/Delete ↔ `utils/acl.ts:279-283` permissionScopes.base（base 数组 135 行起）✓；op-names.ts 无 dashboardList 与 F05 先例（baseVariableList 亦无）一致，非问题。
- 迁移去重 SQL（v2 迁移文件内 ROW_NUMBER 保最早行）逻辑本身正确，但见 ISSUE-1（接错源）。

## rev 实跑门

- `npx tsc --noEmit`（packages/nocodb）→ **exit 0，0 错误** ✓
- `npx jest baseVariableValidators` → **12/12 passed** ✓

## 总裁决

**issues 存在，非 PASS。** ISSUE-1 为 P1 必修（R1 的核心修复在真实部署形态下未生效 + 潜在启动崩溃链）；ISSUE-2/3 为 low，建议同批修。int 功能面本轮实测 35/36（唯一失败即 ISSUE-2），其余全部达标。
