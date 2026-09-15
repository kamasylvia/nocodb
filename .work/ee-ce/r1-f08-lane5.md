# F08 Private Base — R1 lane5 安全审计 + 深度复审报告

- 审查对象: commit `6aea3db097`
- lane: 5 (安全审计 + API 边界实测)
- 日期: 2026-09-13
- 环境: localhost:8080 dev server (nocodb-dev), fixture 前缀 `f08r1l5`

## 结论

**FAIL — 4 issues**

- `packages/nocodb/src/services/bases.service.ts:126-137 (baseUpdate / extractPropsAndSanitize): is_private:false 经 DOMPurify.sanitize 变空串致 PG boolean 拒绝, 私有 base 无法经 API 转回公有, 400 ERR_DATABASE_OP_FAILED: 服务层对 is_private 做布尔规范化(ncIsBoolean 校验+Boolean 归一), 或 is_private 改走 extractProps 不经 sanitize`
- `packages/nocodb/src/services/shared-bases.service.ts:31-76 (createSharedBaseLink/updateSharedBaseLink): 私有 base 可创建共享 base 链接, 匿名者经 xc-shared-base-id 获 viewer 级全量访问, 绕过"仅显式协作者"语义 (实测 200 + base_title 泄漏): 对 is_private base 直接 400 (对齐既有 is_sandbox 守卫), 并修正 strategies/base-view.strategy 的私有判定 (现查 default_role, 应查 is_private)`
- `packages/nocodb/src/strategies/authtoken.strategy/authtoken.strategy.ts:63-66: 无 fk_user_id 的 legacy token 被捏造 base_roles={editor:true}, extract-ids F08 检查信任该字段即放行, legacy 账号级 token 可访问任意私有 base: F08 检查对 is_api_token 且无 base 绑定 (user.id 缺失) 一律 baseNotFound`
- `packages/nocodb/src/services/v3/bases-v3.service.ts:102: v3 isPrivateBase 映射 default_role==='no-access', 与本 fork is_private flag 错位, v3 消费者读不到真实私有状态: v3 层改读 is_private (members 端点现为 paywall stub, 无直接泄漏, 可随 F08 收尾统一)`

另 1 条不计 error 的一致性观察见「观察」节 (快照/副本不继承 is_private)。

E3: 无。

## 一、绕路面枚举 (每条: 结论 + 依据)

判定入口: `extract-ids.middleware.ts:1251-1272` — `@Acl` 装饰器拦截器内, `req.ncBaseId` 非空 + 已认证 + 非 isPublicBase + 非超管 → 私有 base 无显式协作者角色 → `baseNotFound` (404 隐存在)。无 `@Acl` 的控制器枚举: `api-version-not-found` / `internal` / `public-datas` / `public-metas` / `users` / `v3/not-found` (internal 与 public-* 单列如下)。

| # | 面 | 结论 | 依据 |
|---|---|---|---|
| 1 | v1/v2 meta base 路由 (baseGet/baseUpdate/baseDelete/baseInfoGet) | 已拦 | `bases.controller.ts` 全部 @Acl; 实测 member 全 404 `ERR_BASE_NOT_FOUND` |
| 2 | tableId 直打 (tables/records/hooks) | 已拦 | extract-ids tableId→ncBaseId; 实测 404 (含 `/api/v2/meta/tables/:id` 与 `/records`) |
| 3 | viewId/视图列/filter/sort/widget/column 同理 | 已拦 | extract-ids 各分支均设 ncBaseId, @Acl 覆盖 (静态) |
| 4 | audit/comments (`fk_model_id` query/body, commentId) | 已拦 | `legacyExtractIds` 专设分支解析 base; 实测 comments 列表 404 |
| 5 | internal API `/api/v2/internal/:ws/:baseId` | 已拦 | 无 @Acl 但走 `checkAcl`→同一 `aclFn` (`internal.controller.ts:222`); 实测 `operation=tableList` 404 |
| 6 | v3 meta (`/api/v3/meta/bases/:baseId`) | 已拦 | @Acl 同 F08 检查; 实测 404 |
| 7 | baseList (workspace 继承可见性) | 已拦 | `BaseUser.getProjectsList` SQL `is_private IS NOT TRUE OR EXISTS(显式行)` (`BaseUser.ts:596-616`); 实测 member 列表 0 命中 |
| 8 | baseList (超管路径) | 一致 | `bases.service.ts:76-80` 超管走 `Base.list` 全量; 实测超管 GET/list/data 均 200, 与"超管不受限"规格一致 |
| 9 | shared view / public data (`/api/v2/public/shared-view/:uuid`) | 豁免(设计) | 无 @Acl, 由 view UUID 鉴权; 实测 owner 分享后匿名 200。仅 owner 可铸造链接 (member 试建 share 被拦 404) |
| 10 | shared base (xc-shared-base-id) | **未拦 (I2)** | extract-ids 显式豁免 `isPublicBase` (注释声明 by-design); `createSharedBaseLink` 仅拦 `is_sandbox` 不拦 `is_private`; 实测匿名 200 + base_title |
| 11 | websocket | 不适用 | `gateways/socket.gateway.ts` 无 base room、无特权订阅注册 |
| 12 | command-palette (org scope, 全员可调) | 已拦 | `commandPaletteHelpers` innerJoin `nc_base_users_v2` 显式行, 无行者不出现 (静态) |
| 13 | notification | 不适用 | 通知仅发显式被邀请人; 列表路由用户自作用域 |
| 14 | api-docs swagger/redoc | 不适用 | swagger.json @Acl(`swaggerJson`); swagger/redoc HTML 无鉴权但仅返回静态壳, 对任意 id 同响应, 无存在性泄漏 |
| 15 | meta diff/recover, integrations, snapshots(F07), variables(F05), dashboards(F10) | 已拦 | 各 controller 均 @Acl + 路由携带 baseId/可解析 id; 实测 snapshots/variables/dashboards 列表 404 |
| 16 | export/import/duplicate | 已拦 | `duplicate.controller` @Acl, baseId 路由; 实测 member duplicate 404 (副本 is_private 不继承见观察) |
| 17 | template/import base 创建 | 不适用 | 创建面= `baseCreate` (workspace scope), 创建者即 owner, 无既有 base 暴露 |
| 18 | MCP (`mcpTokenId`→ncBaseId 重锚) | 已拦 | extract-ids:203-215 重锚后仍过同一 aclFn; MCP 操作经 internal controller checkAcl |
| 19 | extract-ids 之外直接吃 baseId 的路由 | 未发现 | 全库无 @Acl 控制器枚举仅上列 6 处, 其中数据面仅 public-* (UUID 鉴权) |

## 二、TOCTOU / 判定一致性

三处判定同源同语义, 无漂移:

1. `JwtStrategy.validate` → `User.getWithRoles` 每请求现查 DB (`jwt.strategy.ts:33-40`), token_version 校验, 无 JWT 内嵌陈旧角色。超管提前返回 `base_roles={owner}` (`User.ts:584-596`)。
2. `User.getWithRoles` F08 分支: 显式行 > INHERIT→null; 私有+无显式 → 强制 NO_ACCESS (`User.ts:668-692`)。
3. `extract-ids` F08 检查读同一 `req.user.base_roles`, 排除 NO_ACCESS/INHERIT 后判显式 (`extract-ids.middleware.ts:1258-1268`) — 与 2 语义严格互补。
4. `getProjectsList` SQL 与 2/3 同语义 (显式行且非 no-access/inherit)。

时序: middleware (解析 id) → guard (解析角色, 此时 ncBaseId 已就位) → interceptor (aclFn 判定) — 判定基于目标 base 的即时角色, 无 check-then-act 窗口。缓存: `Base.update` 原地同步 cache 对象 (`o={...o,...updateObj}`, `Base.ts:580`), 实测转私有即时生效 (member GET 立即 404); 转公有方向因 I1 无法经 API 达成 (SQL 直置 false 后 API PATCH true 立即 404, 反向即时性成立)。

## 三、注入 / 类型强制

- `BaseUser.getProjectsList` 的 knex.raw 全 `??`/`?` 参数化, 无注入面。
- `is_private` 服务层**无类型校验**: PATCH `"true"`(string)→落库 t, PATCH `1`(number)→落库 t (node-pg 文本 coerce), PATCH `null`→400。全参数化无注入, 但类型放行归入 I1 建议一并修。
- `baseCreate` payload 注入 `is_private:true`: 生效 (实测建成即 t), 且 `baseCreate` 建后立即插 creator owner 行 (`bases.service.ts` baseCreate 尾部) — **无自我锁死**。
- 迁移: boolean default false, nullable; down 对称; 已注册 `XcMigrationSourcev2` 列表+case, 与 F10 迁移同批次风格一致。

## 四、信息泄漏 (404 vs 403)

- 私有 base 对无权者全路由 404 `ERR_BASE_NOT_FOUND` (实测 15 条路由一致), 存在性不泄露。
- baseList 对无权者不含该 base (v2 实测 grep 0 命中)。
- 错误消息统一 "Base '<id>' not found", 无存在性差异。
- 命中 F08 404 前无 403 泄漏 (检查位于角色判定之前、认证之后, 匿名仍 401)。

## 五、越权变更

- `is_private` 变更面: `@Acl('baseUpdate')` — 该权限名未注册于 `utils/acl.ts` 任何 include/exclude → 隐式仅 owner (exclude 语义兜底)+超管 (`*`)。实测 editor PATCH is_private 403; editor 自提权 owner 403; member PATCH 404。当前紧闭, 但依赖"权限名漏注册"的偶然性 — 建议补注册 (明示 owner-only) 防未来扩权 (观察, 不计 error)。
- base 软删/快照/副本: 删除走 `Base.softDelete` 不改 is_private; 副本与 snapshot restore 产物为公有 (见观察)。

## 六、API 边界实测记录 (f08r1l5)

fixture: base `plm1k1c94hdt44z` (is_private=t), table `mmv3kd72cspbmyn`, source `bkqkwx89js2rszs`; 4 账号: owner(workspace creator) / member(workspace editor, 无 base 行) / editor(显式 editor) / super(super)。

member 拒绝矩阵 (预期全 404, 全部符合):

| 路由 | 结果 |
|---|---|
| GET /api/v2/meta/bases/:id | 404 ERR_BASE_NOT_FOUND |
| GET /api/v2/meta/bases/ (list) | 200, 不含私有 base (0 命中) |
| GET /api/v2/meta/tables/:tid | 404 |
| GET /api/v2/tables/:tid/records | 404 |
| GET /api/v2/meta/bases/:id/users | 404 |
| GET /api/v2/meta/tables/:tid/hooks | 404 |
| GET /api/v2/meta/bases/:id/snapshots | 404 |
| GET /api/v2/meta/bases/:id/variables | 404 |
| GET /api/v2/meta/bases/:id/dashboards | 404 |
| GET /api/v2/meta/bases/:id/info | 404 |
| GET /api/v2/meta/comments?fk_model_id | 404 |
| GET /api/v2/internal/:ws/:id?operation=tableList | 404 |
| GET /api/v3/meta/bases/:id | 404 |
| PATCH /api/v2/meta/bases/:id {is_private:false} | 404 (F08 先于权限) |
| DELETE /api/v2/meta/bases/:id | 404 |
| POST .../shared (建共享链接) | 404 |
| POST /api/v2/meta/duplicate/:id/base | 404 |

owner 合法面:

| 操作 | 结果 |
|---|---|
| POST bases {is_private:true} 建 base | 200, DB t, owner 行在 (无自锁) |
| PATCH {is_private:true} | 200 (DB t) |
| PATCH {is_private:"true"} | 200 (DB t — 字符串被接受) |
| PATCH {is_private:1} | 200 (DB t — 数字被接受) |
| **PATCH {is_private:false}** | **400 ERR_DATABASE_OP_FAILED (DB 不变) — I1** |
| **PATCH {is_private:null}** | **400 (同 I1 根因)** |
| 邀请 editor | 200; editor GET 200 / list 含 / PATCH is_private 403 / 自提权 403 |

超管: GET base 200; list 含; records 200 — 与"超管不受限"一致。

共享链路: owner 建共享 base 链接 → 匿名 `xc-shared-base-id` GET `/api/v2/public/shared-base/:uuid/meta` → **200, 响应含 base_id+base_title (I2)**; 共享 view 链接匿名 meta 200 (设计豁免, 链接仅 owner 可铸)。测试链接已禁用。

## 观察 (不计 error)

1. **副本/快照 restore 不继承 is_private**: `duplicate.service.duplicateBase`→`baseCreate` 仅传 title/status; F07 restore 产物 `<orig> (restored)` 为公有, 源私有数据经副本对全体 workspace 成员可见 (操作者需 owner/editor, 非提权, 但与私有语义不连续)。建议 F08/F07 收尾时定夺。
2. **`baseUpdate` 权限名未注册于 acl.ts**: 现靠 exclude-兜底语义达成 owner-only, 脆弱; 建议显式注册。
3. `getProjectsList` SQL 的 EXISTS 子查询与 Priority-1 分支在外层条件约束下近死码 (仅多行脏数据时生效), 保守正确, 无需改。

## 覆盖统计

- 静态: 7 个 commit 涉及文件全读; 26 个控制器 @Acl 覆盖枚举; 19 类绕路面逐条判定; 判定链 4 处 (jwt/extract-ids/getWithRoles/getProjectsList) 同源核验; 注入面 2 处。
- 实测: 17 条 member 拒绝路由 + 11 条 owner 合法操作 + 3 条超管 + 2 条匿名共享链路; DB 落值逐项 psql 直查 (nocodb-dev)。
- E3: 0。
