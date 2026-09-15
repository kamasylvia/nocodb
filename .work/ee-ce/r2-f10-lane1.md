# r2-f10-lane1 — F10 Create Dashboard R2（第 1 路：集成测试 + 代码复审）

## 裁决：PASS

---

## int（全实测，后端 127.0.0.1:8080，nocodb-dev，专用账号 f10r2a@ce-ee.local）

### 1. CRUD 全链路 — PASS

| 步骤 | 结果 |
|---|---|
| POST `/api/v2/meta/bases/{baseA}/dashboards` `{"title":"D1","description":"x"}` | 200，id `dash70yxk8sbvv0qei`（dash 前缀 ✓），order=1 |
| POST D2 / D3 | 200，order=2 / order=3（递增 ✓） |
| GET list | 200，[D1,D2,D3] 按 order 排序 |
| GET 单条 | 200，字段完整（base_id/fk_workspace_id/created_by/owned_by 正确） |
| PATCH `{"description":"y"}` | 200 |
| PATCH 后 GET 即时读 | description="y"（缓存一致 ✓） |
| DELETE D3 | 200 `true` |
| 删后 GET D3 | 404 `ERR_GENERIC_NOT_FOUND` |
| 删后 list | 即时 [D1,D2]（deepDel CHILD_TO_PARENT 从 list cache 移除 ✓） |

### 2. 校验边界 — PASS

| 输入 | 结果 |
|---|---|
| POST title=123（非串） | 400 "must be a string" |
| POST title="" / "   " / 缺失 | 400 "is required" |
| POST title 256 字符 | 400 "exceeds 255" |
| POST title 255 字符（边界） | 200 |
| POST 重名 D1 | 400 "already exists" |
| POST description=123 | 400 "must be a string" |
| PATCH title=42 / "" / 256 / 改成 D2（重名） | 全 400 |
| PATCH title=自己当前名 | 200 |
| PATCH description=123 | 400 |
| PATCH description=null（清空） | 200，落库 NULL |
| GET/PATCH/DELETE 不存在 id | 全 404 |

### 3. 跨 base 隔离 — PASS

- A base 的 dashboardId 走 B base 路由：GET / PATCH / DELETE 全 404。
- A 侧数据完好（GET 复核未破坏）；B base 独立建同名 "D1" 成功（unique 约束按 base_id 分区 ✓）。
- 404 链路双层防线确认：extract-ids 将 context.base_id 改写为 dashboard 实际 base → service 比较 URL baseId ≠ row.base_id → notFound。

### 4. 权限 — PASS

- editor（base 内邀请成员）对 list / GET / POST / PATCH / DELETE 全 403（`dashboardList/... with the roles: Editor`）。
- 无 token GET / POST / DELETE 全 401；坏 token 401。
- 403 无写入泄漏：DB 查 "EdHack"（editor 尝试创建的 title）0 行。

### 5. DB 核验（pg8000 → qnap.elf-balance.ts.net:5432/nocodb-dev） — PASS

- 行落库正确：base_id/order/created_by/owned_by 与 API 响应一致。
- 删除即物理消失（D3、255-title 测试行均无残留）。
- PATCH description=null → 列值 NULL；PATCH title → API 即时新值，server 重启后 DB 复核为新值（真实落库非仅缓存）。
- unique 索引 `nc_dashboards_base_title_unique` 已建（migration 生效）。
- base delete 级联：DELETE baseA/baseB 后 `nc_dashboards_v2` 0 行残留（deleteByBaseId 链实测）。
- 无孤儿 schema（本功能为 meta 表行级数据，无动态 schema）。

### 环境备注

- 测试中后端一次重启窗口（8080 断连约 3 分钟，非本路操作），恢复后重登录全部复测通过；旧 token 401 系重启后 JWT secret 轮换，非缺陷。
- 测试资源已清理：baseA/baseB 已删（dashboard 行级联清零），临时凭证/token 文件已删。账号 f10r2a@ce-ee.local 与其邀请成员 f10r2a_ed@ce-ee.local 保留（base 已删，成员关系随之消失）。

---

## rev（全文复审：model / service / controller / migration / extract-ids / noco.module / 前端 store+menu+页面）

### 后端

- `models/Dashboard.ts:111-130`：insert 先 materialize（this.get）再 appendToList —— R1 修复在位，实测 create 后 list 立即完整。
- `services/dashboards.service.ts:71-78`：update desc 非串 400、null 清空放行 —— 实测 ✓。
- `controllers/dashboards.controller.ts`：仅 base-scoped 路由（dashboard-only 变体已移除）；POST @HttpCode(200)；4 个 @Acl op 齐全。
- ACL：`utils/acl.ts:280-283` 4 op 注册于 creator+ 段；实测 editor 403 / owner 全通。`command-registry/op-names.ts:101-103` 有对应注册。
- `noco.module.ts:241,335`：DashboardsController + DashboardsService 已注册。
- `XcMigrationSourcev2.ts:80,185`：migration 已注册且顺序在既有 dashboards migrations 之后；DB 索引实测存在。
- `extract-ids.middleware.ts:408-417`：dashboardId → Dashboard.get → base context 填充，缺行 genericNotFound（404）。
- `models/Base.ts:461,714`：base delete 两条路径均级联 `Dashboard.deleteByBaseId`；deleteByBaseId 的 deepDel key（`${scope}:${baseId}:list` PARENT_TO_CHILD）与 setList key 一致。
- service.update 仅透传 title/description（order/meta 不可经 API 改，收紧正确）；model 层 extractProps 二次过滤，无 id/base_id 注入面。
- 并发重名：service check-then-insert 由 DB unique 索引兜底（migration 注释明示该意图）。

### 前端

- `store/dashboard.ts:5`：`$api` 经 `useNuxtApp()` —— 修复在位。
- `openDashboard` / `openNewDashboardModal` 均导航全路由 `/{wsId}/{baseId}/dashboard/{id}`，与 `pages/index/[typeOrId]/[baseId]/dashboard/[dashboardId].vue` 匹配。
- 默认标题取首个非碰撞 "Dashboard N"（titles Set），无双 count 类缺陷。
- `CreateNewActionMenu.vue:501`：菜单 gate 仅 `!blockAddNewDashboard`（isEEFeatureBlocked 条件已移除）；`:529` 项内 `hasDashboardCreateAccess = isUIAllowed('dashboardCreate')` 控制 disabled —— editor 前端不可点。
- `useEeConfig.ts:77`：`blockAddNewDashboard = computed(() => false)` 已解锁。
- i18n key `msg.info.dashboardEmpty` 存在（lang/en.json:5803）。
- `CreateNewActionMenu.vue:529` 残留 `LazyPaymentUpgradeBadge :feature-enabled-callback="() => !isEEFeatureBlocked"`：CE 下 Badge 组件渲染 `<NcSpanHidden />`（payment/upgrade/Badge.vue:42），空壳无 UI 效果、无点击弹窗链 —— 不构成 error。

### 实跑门

- `cd packages/nocodb && npx tsc --noEmit` → exit 0，无输出。
- `npx jest baseVariableValidators --runInBand --forceExit` → 12/12 passed。

### 观察项（不构成 error，不计 issue）

- `services/dashboards.service.ts:89` update 的 title 长度检查用 trim 前长度（create 用 trim 后）：不对称，但 trim 只缩短，无 DB 溢出可能。
- FE store `loadDashboards` 增量 set 不清 Map：`activeBaseDashboards` 按 base_id 过滤，显示与权限无泄漏，仅长会话微小内存驻留。

---

## issues

（无）

## 总裁决

int PASS + rev PASS + 实跑门双过 → **本路 PASS**。
