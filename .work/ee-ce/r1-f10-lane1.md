# r1-f10-lane1（F10 Create Dashboard — 第 1 路集成测试 + 代码复审）

对象：commit 6eb3b80c1d 中 F10 部分（models/Dashboard.ts、services/dashboards.service.ts、controllers/dashboards.controller.ts、noco.module、utils/acl.ts + nc-gui/lib/acl.ts、store/dashboard.ts、dashboard 页面、extract-ids）。实测环境 http://127.0.0.1:8080 / nocodb-dev（pg8000 直查核验）。

## issues

- **E1 [error] `packages/nocodb/src/models/Dashboard.ts:118-125` — insert 的 appendToList 先于 this.get 执行，list 缓存永久陈旧 + 重名校验失效**
  - 机制：appendToList 时新行缓存 key `dashboard:<id>` 尚未写入（this.get 在其后）→ CacheMgr.appendToList 内 `getRaw(key)` 为 null → FALLBACK `return false`（`src/cache/CacheMgr.ts:521-543`）→ 新行永不进入 list 数组。
  - 实测：首次 GET list 将 `[D1key]` 固化后，POST D3/D4/D5（order 4/5/6）全部 200 落库，但 GET list 反复请求始终缺新行；dev server 重启清缓存后 GET list 立即回源 5 行全量 → DB 查询无罪（pg8000 直查确认行全在），纯缓存链 bug。
  - 连带 1：service.create/update 重名检查走 Dashboard.list（缓存）→ 缓存陈旧窗口内重名漏判（实测同名 D2×2 均插入成功）；缓存新鲜（重启后）时重名 400 正常。
  - 连带 2：每次 insert 触发 FALLBACK 分支 deepDel 现有行 parents + error 日志（CacheMgr.ts:527-542）。
  - 对照：F05 BaseVariable.insert 先 this.get 后 appendToList（.then 链，BaseVariable.ts insert 尾部）——同 base 同进程实测 F05 POST 后 list 即时可见。修复 = 对齐 F05 的 get→append 顺序。

- **E2 [error] `packages/nc-gui/store/dashboard.ts:72` — `activeDashboard` 未定义即在 store return 中导出**
  - 文件内无任何 `activeDashboard` 定义，仅 return 处引用 → 首次 `useDashboardStore()` 实例化抛 ReferenceError，hook 该 store 的组件（CreateNewActionMenu 等）全崩。实跑门 tsc 只覆盖 nocodb 包，nc-gui 无 type-check 闸门故未拦。

- **E3 [error] `packages/nc-gui/store/dashboard.ts:48-51` — openDashboard 导航 URL 断链**
  - `navigateTo('/${wsId}/${dashboardId}')`；实际页面路由 `/{typeOrId}/{baseId}/dashboard/{dashboardId}`（pages/index/[typeOrId]/[baseId]/dashboard/[dashboardId].vue）。缺 `/dashboard/` 段与 baseId → 新建 dashboard 后跳转落 404/错页。

- **E4 [error] `packages/nocodb/src/services/dashboards.service.ts:98-103` — update 缺 description 类型校验**
  - create 有校验（40-46 行），update 直接透传。实测 `PATCH {"description":123}` → 200，pg8000 直查 DB `description='123'`（非串静默串化落库）。校验口径「description 非串 → 400」update 侧不成立。

- **E5 [error] `packages/nocodb/src/controllers/dashboards.controller.ts:38-41,64-67,83-87` — dashboard-only 路由（GET/PATCH/DELETE `/api/v2/meta/dashboards/:dashboardId`）不可达死路由**
  - extract-ids 的 dashboardId 解析分支在 `if (baseId)` 块内（extract-ids.middleware.ts:132 块内 408-417 行）；无 baseId 请求走 legacyExtractIds（无 dashboardId 分支）→ context.base_id 空 → base-scope ACL 无角色 403（super admin 实测 403）。即使 ACL 放行，metaGet2(ws, undefined) 亦将 metaError（meta.service.ts:694-699）。三条路由为本次 commit 新增公开 API 面，无任何消费者可用，实测 403。修复：删这三条路径，或 legacyExtractIds 补 dashboardId 分支。

## PASS 项（实测通过）

- create 200；id `dash` 前缀；order DB 侧连续递增（1→6）；created_by/owned_by 落库；GET 单条 200 对象；PATCH 200 且 GET 即读新值（单 key 缓存一致）；DELETE 200 后 GET 404；DB 行物理删除（D1/D5 count=0）。
- 校验（缓存新鲜时）：POST title 缺失/空串/纯空白/非串/256 字符全 400；POST+PATCH 重名 400；POST 非串 description 400。
- 跨 base 隔离：B base 路由打 A 的 dashboardId，GET/PATCH/DELETE 全 404（extract-ids 层 + service getDashboardWithBaseCheck 双防线），无副作用落库。
- 权限：editor（新注册 + 邀请入 base）对 list/get/create/update/delete 全 403（creator+ only 符合声明，与 acl.ts include 白名单链静态分析一致）；无 token 401。
- base delete 钩子清理：删 baseA/B 后 nc_dashboards_v2 相关行 0、nc_base_variables 0（deleteByBaseId 生效）。
- rev 实跑门：`npx tsc --noEmit` 0 错误；`npx jest baseVariableValidators --runInBand --forceExit` 12/12。
- 复审通过点：noco.module 注册齐全；无双 count；ACL 四 op 注册于 permissionScopes.base；title 255 上限与 nc_dashboards_v2 `title varchar(255) notNullable` 一致；metaGetNextOrder 按 base 条件取 max+1；跨 base update 的 metaUpdate 有 contextCondition 兜底；cache getList/setList 语义（list key 存 child key 数组 + mget）确认。

## 观察项（不计 error）

- O1：重名检查为 list 后 insert 的非原子校验，无 DB unique 兜底——E1 修复后仅剩并发窗口。
- O2：model 中 softDelete 与 delete 逻辑完全重复；deleteByBaseId 未清单个 `dashboard:<id>` key（残留脏 key，无害）。
- O3：update 的 title 长度校验用未 trim 原始 length，create 用 trim 后——口径不一致（均保守，非缺陷）。
- O4：dataHelpers.ts 的 F07 修复混入 F10 同 commit（归属混淆）。
- 环境备注：共享回落账号 f01e2e token_version 被各 lane 并发登录反复互踩（多次 401，建议每 lane 独立账号）；发现两个 rspack dev 实例并存（AGENTS §3.2 已知互抢）；期间 8080 短暂重启。均已绕过，不影响结论。
- 清理：baseA/baseB 已删、孤儿 schema `pfeht4stedwly9y`/`p9b23cudsepj2go` 已 DROP、f10r1a_ed 用户及成员关系已删、dashboards/variables 残留 0。
