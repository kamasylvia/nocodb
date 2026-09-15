# F08 Private Base — R2 复审报告(lane2,收敛轮)

- 审查对象: `6aea3db097`(F08 实现) + `2a86eb7d6c`(R1 修复),合并看 HEAD 工作树。
- 方法: 全量 diff 复审 + dev 后端(localhost:8080,含 R1 修复)API 实测 + nocodb-dev DB 直查(psql)。
- 环境: 后端未重启;测试账号前缀 `f08r2l2-*`(12 个);legacy token 行经 psql 插入后已 `enabled=false`。

## 结论

**PASS** — 0 error。R1 全部 7 项修复经 API 实测确认;角色×私有状态矩阵 12 格全符合预期;状态转换即时性成立;未发现新 error。观察项 O1-O4 见文末(均非 error,含上游语义说明)。

## 角色矩阵实测(私有 base `p4tvcsl4bbyc758` | 公开对照 `pmwmeakfjnt7264`)

列格式: `list可见/GET meta/数据API(users表直连)/base users列表`。数据 API = `GET /api/v2/tables/:tableId/records`。

| 角色(行构成) | 私有 base | 公开 base | 判定 |
|---|---|---|---|
| super(`roles='super'`,psql 提权) | 可见/200/200/200 | 可见/200/200/200 | ✓ 超管全见,响应含 `is_private:true` |
| base owner(=ws creator,建 base 者) | 可见/200/200/200 | 可见/200/200/200 | ✓;PATCH is_private 200 |
| ws creator(无 base 行) | 不可见/404/404/404 | 可见/200/200/200 | ✓ 404 隐藏存在性 |
| ws editor(无 base 行) | 不可见/404/404/404 | 可见/200/200/200 | ✓ |
| ws viewer(无 base 行) | 不可见/404/404/404 | 可见/200/200/200 | ✓ |
| ws no-access | 不可见/404/404/404 | 不可见/403/403/403 | ✓ 私有 404(隐藏),公开 403(存在性本就可见) |
| base editor(ws no-access + explicit editor 行) | 可见/200/200/200 | 不可见/403/403/403 | ✓ explicit 行穿透私有;公开侧无 ws 继承故 403(正确) |
| base viewer(同上,viewer 行) | 可见/200/200/200 | 不可见/403/403/403 | ✓ |
| base commenter(同上,commenter 行) | 可见/200/200/200 | 不可见/403/403/403 | ✓ |
| explicit no-access 行 | 不可见/404/404/404 | 不可见/403/403/403 | ✓ 降权行一致 |
| explicit inherit 行 | 不可见/404/404/404 | 不可见/403/403/403 | ✓ **E7 修复确认**:列表与 GET 两处一致 |
| 无任何行用户(org-level-viewer) | 不可见/404/404/404 | 不可见/403/403/403 | ✓ |

补充格: **ws editor + explicit no-access 行**(邀请后)→ 404 + 列表不可见(显式降权覆盖 ws 继承)✓;移除该行后仍 404 ✓。

## PATCH is_private 权限链(结论: creator+ only,与上游 default_role 语义一致)

- owner PATCH → 200;`base editor` PATCH → 403;`base viewer` → 403;ws editor/viewer → 403 `baseUpdate`(include 集无此权限);无角色 → 403。
- 后端 acl(`packages/nocodb/src/utils/acl.ts`):`baseUpdate` 不在 viewer/editor include 集,creator/owner 走 exclude(全量减 `baseDelete/migrateBase`)→ 仅 base creator+ 可改。前端 `manageBaseType` 只加在 `ProjectRoles.CREATOR` include(`packages/nc-gui/lib/acl.ts:156`),OWNER 继承。**判定:editor 不能翻 privacy,前后端 ACL 一致,符合上游「base 元数据修改 creator+」语义,非 error。**
- 非布尔拒绝: `is_private:"true"` / `is_private:1` → 400(swagger ProjectUpdateReq 校验先拦,service 层严格布尔兜底);create 同样 400。

## R1 修复逐项验证(重点)

| R1 项 | 实测 | 结果 |
|---|---|---|
| a. is_private 双向门 | priv/public 各自 true→false→true PATCH 往返均 200;期间 ws editor GET 私有化后立即 404、解除后立即 200 | ✓ 修复确认 |
| b. legacy api token | psql 插 `nc_api_tokens`(fk_user_id=NULL,enabled=true)→ 私有 base meta/data/users 全 404、列表不含;公开 base meta 200/data 200(行为不变) | ✓ 修复确认 |
| c. inherit 行一致性 | 列表不可见 + GET 404 两处一致(binherit 格) | ✓ 修复确认 |
| d. v3 映射 | `GET /api/v3/meta/bases/:id` 私有+无角色 → 404(extract-ids mask 覆盖 v3 路由);公开 → 403;`?include=members` → 400 paid-plan 桩(CE 下 getBaseMember 无条件抛错,R1 的 `isPrivateBase: !!base.is_private` 映射代码正确但行为不可达,见 O3) | ✓ |
| shared-base 400+拦截 | 私有 base 建链接 → 400 "Shared links are not available for private bases";公开建链接 200 → base 转私后同一 uuid 访问 → 401(BaseViewStrategy `sharedBase?.is_private` 拦截);解除私有后 shared 伪用户读 meta 200;uuid 打到其它 base → 401 | ✓ |
| duplicate 继承(E6) | `POST /api/v2/meta/duplicate/:baseId` → 副本 `is_private=true`("f08r2l2-priv copy") | ✓ |
| snapshot 继承(E6 同路径) | 私有 base 建 snapshot → 快照副本 base `is_private=true`("Snapshot … of f08r2l2-priv") | ✓ |
| baseUpdate 白名单 | service 层把 `is_private` 移出 sanitize 白名单单独严格布尔提取(`bases.service.ts:133-141`);`Base.update` extractProps 含 `is_private`(`Base.ts:512`)— 双白名单一致,无漂移 | ✓(代码) |
| 迁移 v0 | `xc_knex_migrationsv0` 含 `nc_20260913_add_is_private_to_bases` 行;`nc_bases_v2.is_private` 列在;v0 up/down 均有 hasColumn 守卫(重跑安全);v2 source 已移除注册 | ✓ |

## 状态转换即时性(无重启、旧 JWT)

- 邀请 norole 为 viewer → 下一请求(未重新登录)GET 200;DELETE 协作者行 → 下一请求 404 且列表移除。getWithRoles 每请求走 DB(BaseUser/Base/WorkspaceUser),无角色缓存,即时性成立。
- wseditor JWT 签发于 flip 之前 → 私有化后下一请求 404(矩阵格),解除后 200。

## 代码复审重点结论

1. **getWithRoles ↔ extract-ids 判定一致性**:三处判定口径统一——①getWithRoles:explicit 行 inherit→null→私有则 NO_ACCESS,no-access→保持;②extract-ids mask:`base_roles` 含 no-access/inherit 之外真角色才算协作者,`is_api_token && !id`(legacy token)强制非协作者,super 豁免,`isPublicBase` 伪用户豁免(由 base-view strategy 的私有拦截兜底);③getProjectsList 两分支 `NOT IN ('no-access','inherit')` EXISTS。mask 位于 isAllowed 之前 → 无角色用户对私有 base 得 404 而非 403(隐藏语义正确,矩阵证实)。OAuth strategy 亦走 getWithRoles(oauth-token.strategy.ts:62)+ OAuth 限 v3/mcp 路径,v3 已被 mask 覆盖。
2. **baseUpdate 权限链**:swagger `ProjectUpdateReq.is_private:boolean` → service 严格布尔(非布尔 400)→ `Base.update` extractProps。create 路径同有布尔守卫(`bases.service.ts:269-274`)。前端 `manageBaseType` creator+。链条闭合。
3. **nc_base_users_v2 继承/降权语义**:inherit 行在私有 base 上等价无行(NO_ACCESS/404/列表不可见);no-access 行显式降权同 404;两条 list 分支(workspace 继承分支 F08 commit、legacy 分支 R1 补)均带 `IS NOT TRUE OR EXISTS` 过滤。注:`baseList` service 恒传 workspaceId(`bases.service.ts:71-73`),legacy 分支实际由 `User.clearCache` 等无 ws 调用者触发,R1 补丁仍属正确防御。

## 观察项(非 error)

- **O1** 私有 base 的 users 列表向协作者返回**全部 ws 成员**(roles:null,含 email;`BaseUser.getUsersList` inner join workspace_user、left join base_users)——上游 CE 邀请对话框语义,非 F08 引入;mask 保证非协作者 404 不可达该端点。EE 收紧属另一话题。
- **O2** F08 无新增单测(后端 spec/前端 vitest 均无 is_private 覆盖);本轮以 114+ 次 API 实测覆盖,建议后续补(F07/F05 同现状)。
- **O3** v3 `?include=members` 的 `isPrivateBase: !!base.is_private` 映射(R1)在 CE 行为不可达(getBaseMember 恒抛 paid-plan 错误);代码正确、行为中性,升 EE 时生效。
- **O4** 理论漂移:`nc_base_users_v2.roles=''`(空串)行会因 `!= no-access && != inherit` 通过列表 Priority-1 但被 extract-ids/getWithRoles 判 404。API 邀请路径枚举校验不可达('' 只能直插 DB),上游同构,记观察不修。
- 附:legacy token 调 base 列表返回空(`param.user.id` undefined)为上游既有行为,与 F08 无关。

## 覆盖统计

- 12 角色 × (list/GET/data/users) × 2 状态(私有/公开)≈ 96 检查点;R1 专项 8 组;边界(ws editor+no-access 行、editor 邀请权、v1 路由 mask、swagger.json/sources 404)8 项。全部符合预期,0 error,0 外部限制(E3 无)。
- 测试脚本: `.work/ee-ce/f08r2-lane2-{setup,setup2,setup3,matrix,r1verify,r1verify2,r1verify3,edge}.mjs`(无凭证)。
