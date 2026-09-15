# r1-f08-lane3 — F08 Private Base R1 复审（回归面 + 旁路 + 代码）

对象：commit 6aea3db097（feat(nocodb): add Private Base (F08)）
环境：localhost:8080 dev server（PID 24645, dist/main.js 含 F08 代码，`grep -c is_private dist/main.js`=34）＋ nocodb-dev（qnap.elf-balance.ts.net:5432）。lane3 专属账号前缀 `f08r1l3`。

## 结论

issues（3，其中 1 必修）：

1. `packages/nocodb/src/meta/migrations/XcMigrationSourcev2.ts:186-188,374-375` + `packages/nocodb/src/meta/meta.service.ts:1126,1141`:F08 迁移注册在 v2 source，而 v2 source 仅当库中存在 `xc_knex_migrations`（v1 表）才执行（meta.service.init 的 `hasTable('xc_knex_migrations')` gate）；nocodb-dev 无该表 → **迁移在本库永不执行，is_private 列缺失**。实测复现：GET /api/v2/meta/bases 对所有用户返 `{"error":"ERR_DATABASE_OP_FAILED","message":"The column does not exist.","code":"42703"}`（运行中的新代码 getProjectsList raw SQL 引用 `nc_bases_v2.is_private`）——F08 使整个 base 列表 API 全员不可用，非仅 F08 功能面。证据链：`SELECT ... FROM xc_knex_migrationsv0` 最新记录 nc_202609031200_agents（2026-09-12）；`\d nc_bases_v2` 无 is_private（23:1x 实测）；fork 近期迁移（admin_suspend/agents 等）全部落在 XcMigrationSourcev0。**建议**：迁移文件移至 `src/meta/migrations/v0/nc_20260913_add_is_private_to_bases.ts` 并注册进 XcMigrationSourcev0（import + getMigrations 数组 + case）。同病提示：F10 的 `nc_20260913_dashboard_title_unique` 亦在 v2 source，dev 库现有 unique index 是前轮手工 DDL 产物（xc_knex_migrationsv2 表不存在佐证），应一并迁 v0。
2. `packages/nocodb/src/modules/jobs/jobs/export-import/duplicate.service.ts:81-92`:duplicateBase→baseCreate 只传 title/status/...(body.base)/fk_workspace_id，**不继承 is_private** → 私有 base 的 duplicate 副本与 F07 snapshot 副本均 is_private=false，成为普通 base。实测：member（无私有 base 任何角色）可列出并**读取** `f08r1l3-priv2 copy` 全部数据（row1 命中）；快照副本 "Snapshot 2026-09-13T15-35-51 of f08r1l3-priv2" member GET 200。owner 对私有 base 执行快照/复制 = 全库结构+数据向 workspace 继承成员开放，且无任何提示。若判定「副本脱密」为目标语义，需 UI 标注 + 文档记录豁免；否则副本应继承 is_private（并考虑复制 explicit 协作者行）。判 error 待裁决/修复。
3. `packages/nocodb/src/models/BaseUser.ts:617-640`（getProjectsList legacy 分支，无 workspaceId 时）+ `packages/nocodb/src/modules/oauth/services/oauth-authorization.service.ts:151`:OAuth base 授权校验走 `getProjectsList(userId,{})` → legacy 分支无 is_private 守卫，且接受显式 `roles='inherit'` 行（`orWhereNot(roles,'no-access')` 对 'inherit' 为真）→ 持有私有 base inherit 行的用户能过 OAuth 资源校验，而其余全部面（list/GET/中间件/getWithRoles）均拒绝。低危（需 explicit inherit 行 + OAuth 流），一致性缺口。建议 legacy 分支补 `is_private IS NOT TRUE OR EXISTS(...)` 同款守卫。

## 迁移文件本身（无 issue）

`nc_20260913_add_is_private_to_bases.ts`:up 加列 boolean default false / down dropColumn，完整；knex 无 IF NOT EXISTS 与仓内迁移惯例一致（F10 先例同款）；XcMigrationSourcev2 内 import/数组/case 三处对齐。问题仅在上文 issue1 的 source 归属。

## 集成测试矩阵（API 实测，全部 lane3 自建数据）

准备：注册 owner/member/super/out 4 账号；owner 入 default workspace（w9qi3ljd）为 workspace-level-owner，member 为 workspace-level-editor（继承角色、无 base 行）；建 base `f08r1l3-priv` + 表 tbl_priv（tableId ms11w4z6anzzcdq）+ 记录 row1；建 `f08r1l3-pub`。

| # | 场景 | 结果 |
|---|---|---|
| 1 | PATCH is_private=true（owner） | 200；GET 回显 is_private=True |
| 2 | owner 自见（有 explicit owner 行） | GET base 200、records 200（建库即插 nc_base_users_v2 roles='owner'，bases.service.ts:399——owner 不会被自己 404） |
| 3 | member base 列表 | 私有化后排除（totalRows 42→41，计数正确） |
| 4 | member GET 私有 base | 404 ERR_BASE_NOT_FOUND（存在性隐藏，非 403） |
| 5 | 旁路 v2（member，已知 tableId/viewId） | base tables list / table meta / records GET+POST / views list / hooks（tableId）/ base users / dashboards / snapshots / shared / api-tokens / PATCH base → **全 404** |
| 6 | 旁路 v1（member） | project meta / tables / table meta / users / shared / snapshots / hooks(tableId) → **全 404** |
| 7 | 旁路 v3（member） | base meta / base tables → **全 404** |
| 8 | /me?base_id=私有 | base_roles={no-access:true}（User.getWithRoles 私有分支生效，workspace editor 未被继承） |
| 9 | 超管 | GET base 200、records 200（完整可见） |
| 10 | 协作者转换 | invite editor→GET 200+入列；role=inherit→404+出列；no-access→404；remove→404 |
| 11 | share base | owner 可对私有 base 建 share（uuid 返回）；匿名 shared-base meta 暴露 base_id+base_title（链接持有者语义，上游 shared-base 行为）；DELETE share 后匿名 404；member 直连 API 仍 404 |
| 12 | API token | member 对私有 base 建 token→404；super 建 token 后 xc-token 读 records→200（token 属主 super 合理） |
| 13 | workspace-no-access 用户（out） | 对他方现存私有 base（lane2 f08r1l2-priv p68be76pyfjpy3x）GET→404（getWithRoles 注入 NO_ACCESS 使其进 F08 分支，无 403 泄漏通道）；不存在 base 对照亦 404，无判别通道 |
| 14 | 回归-公开 base | table 建/删、record insert/read/update/delete（正确 body `[{"Id":n}]`）全 200；私有化操作对 pub base 零扰动 |
| 15 | 回归-存量 base | 迁移默认 is_private=false；40 个存量 base 行为不变；lane2 私有 base 对 member 隐藏（跨 lane 一致） |
| 16 | 回归-owner 操作私有 base | rename（PATCH title）200 持久化；duplicate 正常出副本；DELETE base 200（软删进 trash），删后 owner/member 双 404 |
| 17 | 分页 | totalRows owner=42 / member=41，私有排除计数正确；limit/offset query 被忽略 = 上游既有行为（bases.controller `limit: bases.length`，F08 前 getProjectsList 即无分页，非回归） |
| 18 | 迁移 DB 实证 | 补列后 `\d nc_bases_v2`:`is_private boolean DEFAULT false`；`xc_knex_migrationsv2` 表不存在（issue1 根因）；v0 追踪表最新 nc_202609031200_agents |
| 19 | type-check | `npx tsc --noEmit` exit=0，无错误（基线一致） |

## 性能复审

- F08 判定点在 AclMiddleware.aclFn（每请求单次）＋ User.getWithRoles（每认证解析单次），各新增一次 `Base.get`——走 NocoCache（PROJECT 对象缓存），常态缓存命中无新增 DB 查询；实测 PATCH 后立即可见（缓存同步无滞后）。
- is_private 无索引：boolean 无选择性，workspace 过滤为主选择器，不加索引合理。
- 无 base_roles 的请求在 F08 检查前的 scope-role gate 即被拒，F08 判定不放大查询面。

## 关键交互复核（代码）

- F10 dashboards：extract-ids 对 dashboard 参数解析 ncBaseId（middleware :416）→ 私有 base 的 dashboards 路由被 F08 拦截（实测 #5 404）。
- F07 snapshots：base-snapshots.service.ts:60/169 均经 duplicateBase → 副本 is_private=false（issue2）。
- owner explicit 行：bases.service.ts:399 建 base 即插 roles='owner'，owner 永不被自己 404（实测 #2）。
- Base.getWithRoles 对 superadmin 短路（base_roles=OWNER），与中间件 `roles/org_roles` 双检一致。

## E3

无外部限制。备注：is_private 列在测试窗口内被并行 actor/修复者补列（我方 ALTER 报 "already exists"，前序 `\d` 与 42703 证据在案），后续测试基于补列后的 server 运行态；issue1 为代码修复项，不因手工补列而消解——新装/既有安装的迁移路径仍会缺失该列。
