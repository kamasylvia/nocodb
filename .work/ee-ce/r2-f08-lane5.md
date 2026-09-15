# R2 F08 lane5 — 安全审计 + 深度代码复审（收敛轮）

对象: 6aea3db097（F08 实现）+ 2a86eb7d6c（R1 修复）。隔离纪律遵守（未读他路报告 / r* / patrol-*）。
实测环境: dev server :8080（未重启）+ nocodb-dev（Tailscale qnap.elf-balance.ts.net:5432）。测试前缀 f08r2l5 / f08r2l5b，测毕已清零（bases/users/api_tokens 残留 0）。

## 结论

**PASS**（0 error）

观察项（OBS，均非阻断、有诊断依据，不构成 error）：

- OBS-1 `packages/nocodb/src/services/command-palette/helpers`（实际文件 `src/helpers/commandPaletteHelpers.ts:51`）: `getCommandPaletteForUserWorkspace` 查询 `andWhereNot(bu.roles,'no-access')` 排除 NO_ACCESS 但**不过滤 INHERIT**，且无 is_private 条件——若某成员对私有 base 持 inherit 行，palette 理论上会列出该 base 的 title/表名/视图名。实测入口不可达: `POST /api/v1/command_palette` @Acl scope=org，CE 用户无 org_roles → 401（实测 member/m2 均 401）。建议: 若未来解 palette gate，补 `AND bu.roles NOT IN ('no-access','inherit')`。
- OBS-2 `packages/nocodb/src/strategies/base-view.strategy/base-view.strategy.ts:21`: `sharedBase.default_role` 在 `!sharedBase` 判定之前裸访问，undefined 时 TypeError——上游遗留模式（6aea3db097 前即如此），被 GlobalGuard catch 吞掉后 fallback guest → 最终 401，fail-closed 无泄漏（实测假 uuid → 401，无 500）。fork 的 R1 检查 `sharedBase?.is_private`（:32）本身是安全访问。建议（可选）: 把 default_role 检查移到 null 检查之后。
- OBS-3 私有 base 上的 **public view link** 未禁: shared-**base** 链接已双向拦截（建/改 400 + 存量链接 401），但 owner 仍可对私有 base 的表创建 public view 分享（视图级分享语义，mask 对 isPublicBase 伪用户跳过属设计）。capability 在 owner 手中、且视图分享创建路由（tableId 反解 → mask）已挡住非协作者创建，风险低；EE 语义为私有 base 全禁分享。建议: 产品决策转私时是否级联禁用 public view links。
- OBS-4 TOCTOU: mask 的 `base.is_private` 判定（extract-ids.middleware.ts:1256 `Base.get`）与 handler 执行之间存在转私/转公开竞态窗口（单请求粒度，可能泄一个响应）。上游 ACL 普遍模式，低危。建议: 不修复；如需强一致可在 handler 层重查。
- OBS-5 workspace 成员（无 explicit base_users 行）对**公开** base 的 baseGet/dataList 在本 dev 实例实测 403 "Forbidden - Unauthorized access"，与「workspace 角色继承 base 角色」预期不符。源码等价性证明非 F08 引入: `git show 6aea3db097^:packages/nocodb/src/models/User.ts` 的继承分支与当前版本逐字一致（F08 仅在之前插入 isPrivateBase 分支，pub base 不进该分支）；且失败方向是拒绝而非放行，与 F08 判定链无安全耦合（mask 只认 explicit 角色，继承失效只会多拒不会多放）。建议: 独立排查（疑环境/缓存态），不阻断 F08。
- OBS-6 测试注意事项（后续 lane）: NocoCache 对 api token 行 / base_users 行 / canonical 用户对象有内存缓存，仅 API 路径会失效；SQL 直改/直删会制造伪影（本轮 legacy token 401、invite 422 均为此类伪影，已识别并排除）。DB 操作尽量走 API。

## R1 修复复检（全部验证通过）

1. **boolean 严格化**（bases.service.ts baseUpdate/baseCreate + swagger）: 双层验证。
   - swagger validatePayload 层: `PATCH is_private:"false"/1/null/"yes"` → 400 `Validation failed: 'is_private' must be a boolean`（实测 4 例）。
   - 服务层独立兜底: `'is_private' in param.base && typeof !== 'boolean'` → 400（源码 bases.service.ts:132-141, 266-273）；绕过 swagger 的路径（duplicate body.base）由 `is_private: !!base.is_private` 在 spread 之后强制覆盖（duplicate.service.ts:110-114），注入无效。
   - round-trip: PATCH false → 200（DB=f），true → 200（DB=t），单向门已修复。
2. **legacy api token**（extract-ids.middleware.ts:1261 `isLegacyApiToken = req.user.is_api_token && !req.user.id`）:
   - 无主 token（fk_user_id NULL）account 级: priv meta/records → **404/404**；pub meta/records → **200/200**（public 行为不变 ✓）。
   - base-scoped（base_id 指向私有）: priv → 404；指向 pub 的 scoped token 打 pub → 200、打 priv → 401（scope mismatch 先于 mask，auth 层语义正确）。
   - 伪造性分析: `!id` 不可伪造——authtoken.strategy.ts:51-59 无主分支不赋 id；有主分支 id 取自 `User.getWithRoles(dbUser.id)`（服务端 DB 查询），id+角色全部服务端派生，客户端不可控。现代 token 的角色来自 DB 实时查询，移除协作者即失去访问（getWithRoles 无该层缓存）。
   - 正向: owner 持现代 token → priv 200；member 持现代 token → priv 404。
3. **shared-base 拦截**:
   - 私有 base 建链/改链 → 400 `Shared links are not available for private bases`（create + update 双路，shared-bases.service.ts:47-54, 116-123，实测）。
   - **存量链**（先公开建链 → PATCH 转私 → 匿名带 xc-shared-base-id）: 转私前匿名 meta/records 200/200；转私后 **401/401**（BaseViewStrategy:32 `sharedBase?.is_private` 拦截，R1 修复生效）；匿名无 header → 401。
   - default_role 前置条件异常路径: 见 OBS-2（fail-closed）。
4. **duplicate 继承**（duplicate.service.ts:110 `is_private: !!base.is_private` 置于 `...(body.base||{})` spread 之后）:
   - owner duplicate 私有 base + body 降级尝试 `{"base":{"is_private":false,...}}` → 复制件 DB `is_private=t`（覆盖生效）。
   - 复制件访问: member 404 / m2 404 / owner 200。
   - 公开 base duplicate → 复制件 is_private=f（不误伤正常复制）。
   - external=true base: CE 下无 external 源可建（本地 PG 环境），duplicate 路径与 is_private 强制无类型耦合（boolean 直赋），不受影响；标记为源码结论。
5. **迁移 v0 化**: XcMigrationSourcev0.ts:101-102/212-213/423-426 注册齐全；v2 源已移除（XcMigrationSourcev2.ts 删 9 行 + v2/ 文件已删）；up/down 均 hasColumn 守卫（幂等）；DB xc_knex_migrationsv0 含两条 20260913 记录；8 个存量私有 base 读写正常（列表/掩码无 42703）。
6. **legacy EXISTS 列表分支**: BaseUser.ts getProjectsList 两分支（workspaceId 分支 EXISTS 嵌在 Priority-2 继承子句内；legacy 分支 andWhere EXISTS）都在；member 列表实测 0 hits（含 priv id grep）；owner 列表含 priv+pub。`starred`/`shared` 过滤为主 where 的 AND，不会放宽。
7. **v3 映射**: bases-v3.service.ts `isPrivateBase: !!base.is_private` ✓；v3 base 读 member 404、owner 200（实测）。
8. **UI**: blockPrivateBases=false（useEeConfig.ts:74）、store isPrivateBase 接真实 flag（store/base.ts:80）、acl.ts creator `manageBaseType: true`（owner/admin 经 '*' 合并继承）、Access.vue `canManage` gate + strict boolean PATCH + `val === isPrivate` 幂等短路——逻辑自洽，无 upgrade 弹窗路径。
9. **swagger**: ProjectReq/ProjectUpdateReq 均含 is_private boolean ✓。
10. **jest**: Fork 桶 26/26 PASS（本轮实跑）。

## 绕路面枚举（member = 工作区 editor、无 explicit base 角色；目标 = 私有 base）

| 面 | 路由 | 结论 | 依据（实测 / 源码） |
|---|---|---|---|
| v2 meta base 读改删 | `/api/v2/meta/bases/:baseId` | 已拦 404 | 实测；aclFn mask（extract-ids:1251-1278） |
| v2 meta base 列表 | `/api/v2/meta/bases/`（含 workspaceId 分支） | 已拦（不含私有） | 实测 0 hits；getProjectsList 两分支 EXISTS（BaseUser.ts:593-647） |
| v2 meta base tables | `/api/v2/meta/bases/:baseId/tables` | 已拦 404 | 实测 |
| v2 table meta | `/api/v2/meta/tables/:tableId` | 已拦 404 | 实测；legacyExtractIds `req.ncBaseId = model.base_id`（:586-599） |
| v2 data records | `/api/v2/tables/:tableId/records` | 已拦 404 | 实测；同上反解 + mask |
| v2 comments | `/api/v2/tables/:tableId/comments` | 已拦 404 | 实测 |
| v2 webhook | `/api/v2/tables/:tableId/hooks` | 已拦 404 | 实测；tableId 反解 |
| v2 columns | `/api/v2/meta/columns/:columnId` | 已拦 404 | 实测；columnId 反解（:766-777） |
| v2 export | `/api/v2/export/:viewId/:exportAs` | 已拦 404（ERR_BASE_NOT_FOUND） | 实测；viewId 反解（:600-616）+ @Acl dataList |
| v2 shared base 链接 | `bases/:id/shared` POST/PATCH | 已拦 400 | 实测（shared-bases.service） |
| v2 shared base 存量链匿名 | `xc-shared-base-id` header | 已拦 401 | 实测（BaseViewStrategy:32） |
| v2 duplicate | `/api/v2/meta/duplicate/:baseId` | 已拦 404 | 实测；@Acl duplicateBase + mask |
| v2 snapshots | `/api/v2/meta/bases/:baseId/snapshots` | 已拦 404 | 实测；快照复制经 duplicateBase 继承 is_private |
| v2 dashboards | `/api/v2/meta/bases/:baseId/dashboards` | 已拦 404 | 实测 |
| v2 variables | `/api/v2/meta/bases/:baseId/variables` | 已拦 404 | 实测 |
| v2 audit | `/api/v2/meta/bases/:baseId/audit` | 已拦 404 | 实测 |
| v2 base users/invite | `/api/v2/meta/bases/:baseId/users` | 已拦 404 | 实测 |
| v2 internal API | `/api/v2/internal/:wsId/:baseId?operation=...` | 已拦 404 | 实测 tableList/dataList；params.baseId → mask（internal checkAcl → 同一 aclFn，internal.controller.ts:229-237） |
| v1 meta/data | `/api/v1/db/meta/projects/...`、`/api/v1/db/data/v2/:baseId/...` | 已拦 404 | 实测；:baseId param → mask |
| v3 base/meta | `/api/v3/bases/:baseId`、`/api/v3/meta/...` | 已拦 404 | 实测 |
| v3 data | `/api/v3/data/...` | 拦（table not found 422） | owner 同 URL 亦 422（v3 以 title 寻址，非 F08 差异）；无存在性泄漏 |
| view 分享创建 | view 路由（viewId 反解） | 已拦 404 | mask；view 分享创建需先过 base 路由 |
| public view 链接 | publicDataUuid 匿名路由 | 见 OBS-3 | view 级分享语义；owner capability |
| jobs listen | `POST /jobs/listen` | 不适用 | assertJobReadable 按 fk_user_id 校验（jobs.controller.ts:65-74），job 由本人发起才可读，job id 不可猜 |
| notification | `/api/v1/notifications` 等 | 不适用 | org scope 个人通知，不涉 base 内容；member 实测 401（无 org 角色） |
| activity/command palette | `POST /api/v1/command_palette` | 入口不可达 401 | 实测；查询面残留见 OBS-1 |
| template import | 无独立 base 路由 | 不适用 | 经 baseCreate（@Acl baseCreate） |
| attachments 下载 | `/api/v2/downloadAttachment/:modelId/...` | 已拦（源码） | @Acl dataRead + modelId 反解（legacyExtractIds tableId 分支） |
| attachments 上传 | `/api/v2/storage/upload`（无 @Acl） | 不适用 | 仅写文件存储，非 base 读面；写 cell 另过 dataInsert ACL |
| mcp token 锚定 | mcpTokenId 分支 | 不适用 | extract-ids:203-215 反解 token 的 base 并填 ncBaseId → mask |
| 整体 ACL 缺口扫描 | 14 个 @Acl 覆盖 < 路由数的 controller | 逐一核查无 base 读面 | public-datas/public-metas（匿名公开视图语义）、internal（自带 checkAcl→aclFn）、utils/api-docs/auth/oauth/users（非 base 面）、integrations 2 路由（内置集成列表，非 base 数据）、attachments 上传、jobs listen |

## 判定链同源（五处）

1. **extract-ids mask**（:1251-1278）: 非 super admin（roles/org_roles）+ 私有 base + 无 explicit base_roles（真实角色才算，排除 NO_ACCESS/INHERIT，legacy token 一律不算）→ 404。isPublicBase 伪用户跳过（由 BaseViewStrategy 前置拦截补偿）。
2. **jwt.strategy**（:41-45）: baseId 取 `req.ncBaseId`——ExtractIdsMiddleware 注册为 APP_GUARD（app.module.ts:46-48）先于 controller 级 GlobalGuard 执行，ncBaseId 已由 params（主分支）或 tableId/viewId/hookId/columnId 等反解（legacyExtractIds :586-840）填充，**全路由族覆盖**，getWithRoles 与 mask 看到同一 baseId（同源）。
3. **getWithRoles**（User.ts:602-709）: super→全部 owner；explicit row 真实角色（'inherit' 字符串→null）；私有+无 explicit→NO_ACCESS；公共+无 explicit→workspace 继承（该继承分支 F08 前后逐字一致）。与 mask 的 explicit 判定同源一致：显式角色唯一授权源。
4. **getProjectsList**（BaseUser.ts:507-647）: workspaceId 分支 EXISTS 过滤嵌在继承子句内（Priority-1 explicit 行天然放行）、legacy 分支 AND EXISTS；两分支对 inherit/no-access 一致排除——与 mask 判定同构。
5. **BaseViewStrategy**（:21-38）: default_role（EE sentinel）+ is_private（fork）双拦，伪用户 base_roles=sharedBase.roles 仅在非私有 base 上产生。

**TOCTOU**: 见 OBS-4。

## 注入面

- create: `is_private` 非严格 boolean（"true"/1/null）全部 400（swagger 层拦，服务层兜底）——实测。
- update: 同上 4 例 400 + round-trip 200×2——实测。
- duplicate body.base: spread 后强制覆盖 `!!base.is_private`，字符串/boolean 注入均无效——实测 + 源码。
- import/share body: share 请求体无 is_private 字段（SharedBaseReq 不含）；import 走 baseCreate 同校验。
- PG boolean 列: 无 22P02 通路（非 boolean 在服务层前置 400）。

## 信息泄漏

- 404 语义统一: 不存在 base 与私有 base 返回**完全相同**的 `{"error":"ERR_BASE_NOT_FOUND","message":"Base '<id>' not found"}`（实测对照），无 403/404 区分泄漏。
- member base 列表/搜索/最近访问: 列表 0 hits；palette 入口 401；internal baseGet 404。
- 错误消息不含 is_private/shared 状态字样；v3 data 422 "Table not found" 不确认 base 存在性。
- base 响应体 is_private 字段仅对可读者返回（能读即有权）；sanitizeBase 不新增泄漏面。

## E3 / 环境限制

无外部网络限制。两条测试限制（非产品缺陷，均已有诊断并绕行）:
1. dev 实例 NocoCache 内存缓存对 SQL 直改不失效——伪影来源，已按 API 路径重测（见 OBS-6）。
2. 私有 base「邀请后可访问」的正向验证以 m4 + explicit viewer row 完成（200/200）；经 invite API 的完整往返因测试库缓存污染（直删用户悬空 canonical 缓存）未能干净复测，invite→BaseUser.insert→mask 放行源码路径明确（base-users.service.ts:129-260 + extract-ids mask explicit 分支），R1 已实测该往返。
