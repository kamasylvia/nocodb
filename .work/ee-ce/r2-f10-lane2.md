# r2-f10-lane2 — F10 Create Dashboard R2 收敛确认（第 2 路：集成测试 + 代码复审）

基线：commit 294c79ef5d（R1 修复后 HEAD）。后端 dev 8080 实测（nocodb-dev），账号 f01e2e@ce-ee.local（creator）/ f10r2b@ce-ee.local（base viewer）。资源前缀 f10r2b_，测毕 base A/B 及 scratch base 均 DELETE，DB（pg8000 实查）f10r2b 残留 0 行。本文件覆盖 R1 轮同名归档（R1 6 error 已由 294c79ef5d 修复，闭合确认见文末）。

## 裁决：**PASS**

## int 集成实测

### 1. 非法输入矩阵 — 全 400/200，语义明确
create 路径（POST /api/v2/meta/bases/{A}/dashboards）：
- title=123 / {"a":1} / true / [] / null → 400 `Dashboard title must be a string`
- title="" / "   " / 缺失 → 400 `Dashboard title is required`
- title 256 / 601 字符 → 400 `exceeds 255 characters limit`
- desc=123 / {"a":1} / true / [] → 400 `Dashboard description must be a string`
- desc 600 字符 → 200，DB 核对 length=600 无截断

update 路径（PATCH，R1 issue 4 修复验证）：
- desc=123 / {"a":1} / ["x"] / true → 全 **400**（不再静默 stringify）
- title=123 → 400 `must be a non-empty string`

### 2. 跨 base 隔离
- A 的 dashboardId 走 B base 路由 GET / PATCH / DELETE → 全 **404**（extract-ids middleware 层即拦，`Dashboard '...' not found`）
- dashboard-only 路由 `/api/v2/meta/dashboards/{id}` GET/PATCH/DELETE → 全 **404 Cannot GET/PATCH/DELETE**（R1 已 drop 路由；无 500、无 metaGet2 base_id null 错误路径）
- 同 title `f10r2b_xbase` 异 base 可建 → 200，DB 两行分属两 base
- 正常路径 sanity：GET@A 200 返回正确行

### 3. 并发同 title ×5（单 token 单进程 5 线程；5 轮常规 + 1 轮抓 body）
- 5/5 轮均**恰 1×200、4×400**，无 500
- 400 body 证实 DB 兜底：`ERR_DATABASE_OP_FAILED ... unique constraint violation ... code 23505`（CE 全局映射为 400，非裸 500）
- DB 核对（pg8000 → nocodb-dev）：9 个 race title 各**恰 1 行**；`pg_indexes` 实查 `nc_dashboards_base_title_unique` 在位；`base_id IS NULL` 行 = 0（metaInsert2 meta.service.ts:345 自动落 base_id，unique 约束不会被 NULL 绕过）
- 附：service 层查重（`Dashboard.list`）工作正常——并发 4 败者部分即命中 `already exists` 400 路径，R1「顺序 create 全 200」未复现

### 4. ACL
- f10r2b 以 base viewer 加入 A：LIST / GET / POST / PATCH / DELETE dashboard 全 **403** `Forbidden ... dashboardList/Create/Update/Delete`
- creator：POST / PATCH（title、desc、desc=null 清除）/ DELETE 全 **200**；自 title rename 200；dup title 400；不存在 id 404；re-delete 404
- 静态闭合：`dashboard*` 4 op 注册于 `permissionScopes.base`（`packages/nocodb/src/utils/acl.ts:276-281`），role 表 VIEWER include 不含、CREATOR/OWNER 为 exclude 型自动获得 → creator+ only；FE `packages/nc-gui/lib/acl.ts:150-155` 同款（ProjectRoles.CREATOR）
- 附加：desc=null 清除 200 且 DB 值 NULL；base delete 级联清理（删 A/B 后 nc_dashboards_v2 残留 0）

## rev 代码复审

- **create 查重+插入竞态窗口**：check-then-insert + DB unique(base_id,title) 兜底（`nc_20260913_dashboard_title_unique.ts`，dedup 先行）；23505 → 400 映射实测正确
- **metaGet2 base_id 条件**：controller 仅存 base-scoped 路由；`extract-ids.middleware.ts:130-150` 先由 `params.baseId` 填 context（Base.get 校验存在），L409-419 dashboardId 分支仅作反查兜底——base_id null 不可达；dashboard-only 路由已 drop 实测 404
- **缓存**：`NocoCache.get` key 含 cacheContext(base_id)（NocoCache.ts:123）跨 base 不串；`getDashboardWithBaseCheck` 的 base_id 比对为第二道防线；insert 先 materialize 后 appendToList（R1 修序在位）
- **ACL op 注册闭合**：controller 4 @Acl op 与 permissionScopes.base 一一对应，无未注册/未用
- **migration**：up 先 dedup（ROW_NUMBER 保最早）再建 unique，down dropUnique，幂等可逆

### 实跑门
- `npx tsc --noEmit`（packages/nocodb）：**exit 0，0 errors**
- jest `baseVariableValidators`：**12/12 passed**

### 观察项（非 error，不要求修复）
- `packages/nc-gui/store/dashboard.ts`（F10 重写）未再导出上游 CE stub 的 `activeDashboard`/`activeDashboardId`。消费端 `Topbar.vue:10`、`share-and-collaborate/View.vue:19` 经 storeToRefs 解构得 `undefined`，与上游 stub `null` 同为 falsy：Topbar 分支行为不变、View.vue share-dashboard 分支同样隐藏，实测无 ReferenceError（store return 已无未定义标识符引用，R1 issue 5 的崩溃路径不存在）。如求 store 契约完整可补回 null computed 导出

## R1 六 error 闭合确认（对照 R1 轮本文件归档）
| R1 issue | R1 修复（294c79ef5d） | R2 实测 |
|---|---|---|
| 1 缓存 append 顺序 | 先 materialize 后 appendToList | 查重/列表行为正常，未复现「list 1 行 vs DB N 行」 |
| 2 无 race 兜底 | unique(base_id,title) migration | 索引在位；×5 恰 1 成余 400（23505→400） |
| 3 dashboard-only 路由 500 | drop 该组路由 | GET/PATCH/DELETE 全 404 |
| 4 update desc 无类型校验 | 补 string\|null 校验 | desc 非串 ×4 全 400 |
| 5 store return 未定义 activeDashboard 崩 | 从 return 删除 | store 实例化正常，消费端 falsy 行为等价上游 |
| 6 openDashboard 2 段 URL | 拼 `/{ws}/{baseId}/dashboard/{id}` | diff 确认，route.params.baseId 取值 |

## 环境备注（非产品问题）
- 测试期间 dev server 因 rspack watch 多次自动重启（JWT secret 不持久 → 间歇 401/连接失败），用例均经重试至稳定结果；全程未重启/未杀任何进程
