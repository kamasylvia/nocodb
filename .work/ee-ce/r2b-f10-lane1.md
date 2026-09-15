# r2b-f10-lane1 — F10 Dashboard R2 收敛（第 1 路独立会审）

## 裁决

**PASS**

（int：48/48 实测过；rev：无有 API 可达链的 issue；实跑门：tsc 0 / jest 12/12）

## int 集成实测（dev server :8080 / nocodb-dev，账号 f10r2b@ce-ee.local creator、f10r2b_ed editor；base f10r2b_A、f10r2b_B，测毕已删）

| 组 | 结果 | 要点 |
|---|---|---|
| T1 CRUD 全链路 | 9/9 | POST→list 含新行→GET 单条→PATCH(title+desc)→回读一致→DELETE→GET 404→list 排除 |
| T2 重名串行 | 2/2 | 同 title 第二次 400 |
| T2 并发同 title ×5 | 3 轮全过 | 每轮恰 1×200 + 4×400，无 500（unique index 兜底，exception-mapper 把 UniqueConstraintViolationError 映射 v2=400） |
| T3 校验矩阵 | 14/14 | title 非串/空/纯空格/256→400；255→200；desc object/number→400；update 侧 desc 非串 400（R1 修复生效）、title 空/非串 400、desc null 清空 200、改成他行 title 400、改成自己 title 200 |
| T4 跨 base 隔离 | 4/4 | A 的 id 走 B 路由 GET/PATCH/DELETE 全 404；B list 无 A 行 |
| T5 权限 | 7/7 | editor 全操作 403（list/create/get/patch/delete）；非成员 403/404；creator 200 |
| DB 核验（pg8000, nocodb-dev） | 11/11 | 行落库（base_id/desc/created_by/owned_by=JWT id）；API list 数==DB count；patch 落库；delete 删行；`nc_dashboards_base_title_unique` 索引存在；清后前缀残留 0 |

注：脚本曾报 DB.4 fail 系测试脚本 user id 硬编码多一字符（`usyj2ey9400qfakvi` vs JWT/DB 实际 `usyj2ey9400qfakv`），解码 JWT 比对一致，非产品问题。

## rev 代码复审（service/controller/model/acl/migration/前端 R1 diff）

- **insert 缓存顺序**（`packages/nocodb/src/models/Dashboard.ts:118-128`）：`metaInsert2` → `this.get()` 先物化对象缓存 → 再 `appendToList`。✓ R1 修复在位。
- **update desc 校验**（`services/dashboards.service.ts:71-78`）：非 string 且非 null → 400，实测 T3.9 佐证。✓
- **dashboard-only 路由已移除**（`controllers/dashboards.controller.ts`）：仅存 base-scoped 五路由；`getDashboardWithBaseCheck` 的 `baseId &&` 分支为防御性死支，无洞。
- **注册闭合**：`noco.module.ts:241/335` controller+provider 已注册；`utils/acl.ts:280-283` 四权限在 permissionScopes.base（base 域正确）；`ProjectRoles.CREATOR/OWNER` 为 exclude 模式默认含、`EDITOR` 为 include 模式不含 → 与 T5 实测一致。
- **migration**（`nc_20260913_dashboard_title_unique.ts`）：先按 (base_id,title) ROW_NUMBER 去重保最早行，再加命名 unique 约束；已注册 `XcMigrationSourcev2.ts:185`；索引实测存在（DB.10）。
- **并发兜底错误链**：metaInsert2 无特判 → 全局 `filters/global-exception/exception-mapper.ts:93-120` UniqueConstraintViolationError → v2 400。实测并发余 4 全 400、无 500。✓
- **Base 删除清理**：`Base.ts:461/714` 接 `Dashboard.deleteByBaseId`。✓
- **前端 R1 diff**：`store/dashboard.ts` `$api` 经 `useNuxtApp()`；`openDashboard`/`createDashboard` 跳 `/{{wsId}}/{{baseId}}/dashboard/{{id}}` 全路径；菜单门只剩 `!blockAddNewDashboard`（`useEeConfig.ts:77` = false）。`duplicateDashboard` 为 null 占位但无任何 .vue 调用点，无 API 可达链，不计 issue。

无有 API 可达链的 issue。

## rev 实跑门

- `cd packages/nocodb && npx tsc --noEmit` → exit 0（0 错误）
- `npx jest baseVariableValidators --runInBand --forceExit` → 12/12 passed

## 备注

- 实测期间 dev server 两次热重启窗口（rspack autoRestart），轮询恢复后继续，未人为重启/杀进程。
- 资源清理：dashboard 行 0 残留（DB 实查）；f10r2b_A/B 两 base 经 DELETE API 删除（200）。
