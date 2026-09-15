# r3-f10-lane1 — F10 Dashboard R3 会审（int + rev）

## 裁决: issues

---

## issues

### issue 1 — update 路径 title 非串 → 500（API 实测实锤）

- **位置**: `packages/nocodb/src/services/dashboards.service.ts:85-90`（update 方法 title 分支）
- **问题**: R2 重构（`const trimmedTitle = (body.title as string).trim()`）删除了原先的 `typeof body.title !== 'string'` 守卫。PATCH body `title` 为非串类型时直接对非 string 调 `.trim()` 抛 TypeError，返回 HTTP 500。create 路径（L28-30）保留了 typeof 守卫，同输入返回 400——两路径行为不一致。
- **实测证据**（dev server, 2026-09-12）:
  - `PATCH /api/v2/meta/bases/{baseId}/dashboards/{dashId}` body `{"title":123}` → HTTP 500 `TypeError: body.title.trim is not a function`（stack 指向 dashboards.service.ts:87）
  - 同路由 body `{"title":null}` → HTTP 500 `Cannot read properties of null (reading 'trim')`
- **违反**: 验收清单「无服务端 500 残留」；非法输入应 400。
- **建议**: update 分支恢复类型守卫：`if (body?.title !== undefined && (typeof body.title !== 'string' || body.title === null)) NcError.badRequest('Dashboard title must be a non-empty string')`，后续用 `trimmedTitle` 参与长度/重名检查与落库（消除 L99/L103/L109 的重复 `.trim()` 调用，一并规避同类 500）。

---

## int 集成测试（全实测）

环境: dev server :8080（未重启），nocodb-dev。主账号 f10r3a@ce-ee.local 不存在（nc_users_v2 无此行，登录 401）→ 回落 f01e2e@ce-ee.local；因多路并行共用回落账号导致 `token_version` 被他路 workspace invite 流旋转互踩（token 10-15s 失效，实测复现），改建本路专属账号 f10r3a_l1(creator)/f10r3a_ed(editor) 完成测试。资源前缀 f10r3a_，测完已清理。

1. **CRUD 全链路** — PASS
   - POST base A `{"title":"D1","description":"x"}` → 200，id `dash8f8yhur1tgn70c`（dash 前缀），order=1
   - POST D2 → 200，order=2（递增）
   - GET list → 200 两行；GET 单条 → 200
   - PATCH `{"description":"y"}` → 200 且 GET 立即反映
   - DELETE → 200 true；删后 GET → 404 `ERR_GENERIC_NOT_FOUND`；list 不再含 D1
2. **校验（create）** — PASS
   - title=123 / 缺失 / `""` / `"   "` / null → 全 400；256 字符 → 400；255 边界 → 200
   - 重名 D2 → 400 `already exists in this base`
   - description=123 / [1,2] → 400
   - trim: `"  Pad  "` 落库为 `Pad` → 200
3. **校验（PATCH）** — 除 issue 1 外 PASS
   - title `""` / `"   "` → 400；256 → 400；改名为已存在 title → 400；改回自身 title → 200 no-op
   - description=123 → 400；description=null 清空 → 200
4. **跨 base 隔离** — PASS
   - A base 的 dashboardId 走 B base 路由：GET/PATCH/DELETE 全 404，原行经 A 路由仍 200 完好
   - 不存在 dashboardId → 404；不存在 baseId POST → 404 `ERR_BASE_NOT_FOUND`
5. **权限** — PASS
   - workspace-level-editor：list/create/patch/delete 全 403（`dashboardList/Create/Update/Delete` with roles: Editor）；editor 尝试创建的行确未落库
   - 无 token list/create → 401；伪造 token → 401
6. **DB 核验**（uv + pg8000 → qnap.elf-balance.ts.net:5432 nocodb-dev，未触碰 nocodb 生产库）— PASS
   - 行落库字段正确（base_id/order/created_by/owned_by）
   - 删除后 nc_dashboards_v2 行消失；API list 与 DB 行集一致
   - 唯一索引 `nc_dashboards_base_title_unique (base_id,title)` 已建（迁移已跑）；全表 (base_id,title) 重复对 = 0
   - 缓存一致性：patch 后立即 get、删后立即 list 均返回新态

## rev 代码复审

- `models/Dashboard.ts` insert 缓存顺序：`this.get(context, id)` 先物化对象，再 `appendToList`（L121-128）——顺序正确（R1 修复在位）
- update desc 校验（string 或 null）在位；title trim 前置长度/重名检查逻辑达意（R2 意图正确，唯类型守卫缺失见 issue 1）
- controller 5 条路由全部 base-scoped（`/api/v2/meta/bases/:baseId/dashboards[/:dashboardId]`）；service `getDashboardWithBaseCheck` 强制 `dashboard.base_id === baseId` 否则 404
- 注册闭合：`modules/noco.module.ts` controller(L241)+service(L335)；`utils/acl.ts` L280-283 四权限；`XcMigrationSourcev2.ts` 三处（import L80 / 数组 L185 / case L368）+ 迁移文件 `v2/nc_20260913_dashboard_title_unique.ts` 在盘（先去重后建唯一索引，up/down 对称）
- `getWidgets` R1 修复（实例属性赋值替代字面量返回）在位
- ACL 语义：dashboard* 仅 creator+（acl.ts creator 段），与 editor 403 实测一致

## rev 实跑门

- `cd packages/nocodb && npx tsc --noEmit` → exit 0
- `npx jest baseVariableValidators --runInBand --forceExit` → 12/12 passed（Test Suites 1 passed），exit 0

## 清理

- base f10r3a_A / f10r3a_B 已删（软删 deleted=true 进 trash，平台统一语义）；关联 dashboard 行 0；测试账号 f10r3a_l1 / f10r3a_ed 已删（nc_users_v2 计 0）；无孤儿 schema（本功能仅 meta 表行）。临时凭证文件已删。
