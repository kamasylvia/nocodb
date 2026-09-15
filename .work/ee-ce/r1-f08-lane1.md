# F08 Private Base 复审 R1 — lane1(集成测试 + 代码复审)

对象 commit:`6aea3db097`(feat(nocodb): add Private Base (F08))
环境:后端 dev :8080(nocodb-dev 库,qnap.elf-balance.ts.net:5432),API 实测。

## 结论

issues(2 error + 3 非阻塞):

1. `packages/nocodb/src/services/bases.service.ts:132`(baseUpdate 的 extractPropsAndSanitize 白名单含 'is_private'):is_private=true→false 必失败(实测 400,`22P02 Invalid data type or value for column 'is_private'`)。根因:`src/helpers/extractProps.ts:12` `extractPropsAndSanitize` 对每个 prop 执行 `DOMPurify.sanitize(value)`,实测 `DOMPurify.sanitize(false)` 返回空串 `''`(`sanitize(true)` 返回 `'true'` 故 true→true 幂等成功),PG boolean 列拒绝空串。私有 base 一旦开启无法经 API 关闭,功能不可逆。建议:is_private 移出 sanitize 白名单,单独取 boolean(如 `data.is_private = (param.base as any).is_private === true`),或改 extractPropsAndSanitize 对 boolean 类型跳过 sanitize。
2. `packages/nocodb/src/meta/migrations/XcMigrationSourcev2.ts:187`:F08 迁移仅注册于 XcMigrationSourcev2,该源只在「存在 xc_knex_migrations(v1 表)的极老存量安装」上执行(`src/meta/meta.service.ts:1130-1151`:hasTable('xc_knex_migrations') 为 false 时跳过 v1+v2)。fresh install 仅跑 XcMigrationSourcev0,而 `v0/nc_001_init.ts:62` 的 PROJECT 表定义**不含 is_private**(v0 目录全文 grep 仅 INTEGRATIONS 表有同名列)→ 全新安装缺列,而 `BaseUser.getProjectsList` 的 raw SQL 与 extract-ids 均引用 `nc_bases_v2.is_private` → base 列表等核心 API 42703 全挂。实证:dev 库 xc_knex_migrationsv0 记录止于 nc_202609031200_agents,无 xc_knex_migrations/v2 表,F08/F10 迁移从未执行,dev 库的 is_private 列系手工 DDL(g 项「迁移生效」实为「列存在」)。建议:迁移按 upstream 惯例(2026-09 迁移全在 v0)注册/移入 XcMigrationSourcev0;注意勿双注册(v0+v2 都跑的存量安装会 duplicate column,up 需 hasColumn 幂等守卫)。F10 的 dashboard_title_unique 同样注册在 v2,同病(本次不展开,提请复核)。
3. (非阻塞)`src/schema/swagger.json` ProjectUpdateReq 无 is_private 属性 — API 文档缺口;ajv 非严格模式放行,功能不受阻。建议补 schema。
4. (非阻塞)nocodb-sdk Base/Project 类型无 is_private 声明(nc-gui `utils/baseCreateUtils.ts:22` 的 ProjectCreateForm 已有)。前端后续做 UI 时缺强类型,建议同步 SDK interface。
5. (非阻塞)无 F08 相关后端 spec(src 下 spec 无 is_private 覆盖;jest 默认集 `(Integration|Source|Fork)` 仅 2 套 26 tests 全过,无回归)。建议补 baseUpdate is_private 布尔透传与 getProjectsList 私有过滤的单测。

## 测试矩阵(全部 API 实测,lane1 资产前缀 f08r1l1)

| # | 场景 | 结果 | 证据 |
|---|---|---|---|
| a | owner 建 base + PATCH is_private=true + 回读 | PASS | PATCH 返回 1;GET is_private=True |
| b | member(仅工作区继承,editor):列表 41 base 无私有 base;GET 私有 base | PASS | 列表不含 padjm38bndw05ht;GET → HTTP 404 `ERR_BASE_NOT_FOUND`(非 403) |
| c | collab 经 owner 邀请(base_users roles=editor) | PASS | 邀请成功后列表可见(is_private=True)+ GET 200 |
| d | is_private=false 恢复可见 | **FAIL(Error 1)** | PATCH false → 400 22P02;member 仍 404/列表不见 |
| d' | 幂等 PATCH true→true | PASS | 两次均返回 1,回读 True |
| e | 超管 GET/列表私有 base | PASS | 合法 super('super' 角色串)用户 GET 200、列表可见。注:角色串必须为 'super'(OrgUserRoles.SUPER_ADMIN 枚举),'super-admin' 无效(测试数据教训,非代码缺陷) |
| f | member 直连私有 base 的 table meta / record 写 / record 读 | PASS | 三者均 404 ERR_BASE_NOT_FOUND(extract-ids 经 tableId→base_id 解析拦截) |
| f' | member 访问私有 base 的 audits / users 列表 | PASS | 均 404 |
| g | 迁移生效 | PARTIAL | 列存在(boolean default false)但见 Error 2:迁移从未执行,列系手工 DDL |
| h | member PATCH is_private | PASS(更优) | 404 而非 403 — F08 检查先于 ACL,不泄露可写性 |
| h' | collab(editor)PATCH is_private | PASS | 403 `baseUpdate with roles: Editor`(baseUpdate 仅 creator/owner:CREATOR/OWNER 走 exclude 模式放行,EDITOR include 模式不含,符合上游权限语义) |
| h'' | GET 不存在 baseId | PASS | 404 |
| i | 回归:非私有 base member(工作区继承)可见 | PASS | GET 200、列表可见;owner/collab 正常;collab 降级 base_users no-access → 404 + 列表消失,恢复 editor → 200(explicit NO_ACCESS row 与 extract-ids/getWithRoles/getProjectsList 三处判定一致) |

## 代码复审要点核验

- 404 覆盖面:req.ncBaseId 由 ExtractIdsMiddleware(express middleware,先于 passport guard)统一赋值,覆盖 base/table/view/hook/dashboard/column/filter/widget/MCP token 等全部分支;实测 meta/data/audit/users 多路径 404。AclMiddleware F08 检查对 `isPublicBase` 伪用户(share view)跳过,语义正确。
- 判定一致性:getWithRoles F08 分支(缺行/INHERIT/NO_ACCESS → NO_ACCESS)与 extract-ids `hasExplicitBaseRole`(排除 NO_ACCESS/INHERIT)、getProjectsList(Priority1 explicit 非 no-access/inherit;Priority2 加 EXISTS 守卫)三处同源一致;h5 实测 NO_ACCESS row 三处行为一致。执行顺序安全:middleware 赋 ncBaseId → jwt.strategy getWithRoles(baseId 已可解析)→ interceptor 检查。
- 存在性泄露审查:`getUserRoleForScope` 空值时的 403 检查位于 F08 检查之前,但 getWithRoles 的 F08 分支保证私有 base 对任何登录用户(含完全无关者)base_roles 至少为 NO_ACCESS(非空),403 前置分支不触发 → 404 生效。未发现泄露路径。
- 缓存一致性:Base.update 内 `o={...o,...updateObj}` 回写 PROJECT 缓存 → extract-ids/auth 的 Base.get 即读到新 is_private(b2/d4 实测即时生效)。User/BaseUser 缓存不涉及 is_private。
- 性能:extract-ids 每请求 +1 次 Base.get(缓存热,无 DB);getWithRoles 每 auth +1 次 Base.get(同缓存);getProjectsList 单 SQL 增加 EXISTS 子查询(PK 索引),无 N+1。
- 分页/计数:getProjectsList 无分页参数、无独立 count,单查询过滤,无失真。
- 权限:baseUpdate ACL(editor 403 / creator-owner 放行)符合上游;createProject 白名单含 is_private 允许创建即私有,无害。
- 迁移规范:up/down 成对、knex 惯例正确;注册三件套齐(import/数组/getConfig),数组序在末尾无被后续迁移破坏风险——但见 Error 2(注册源错误)。
- 附:member 等继承用户首建 base 后自动获 base_users owner 行(`bases.service.ts:399`),owner 不会被自己私有 base 锁外。

## 测试资产(nocodb-dev,保留)

- 用户:f08r1l1-{owner,member,collab}-13130@t.io(org-level-viewer + workspace owner/editor/editor)、f08r1l1-super@t.io(roles='super-admin',无效串,等效无特权)、f08r1l1-sup2@t.io(roles='super',有效超管)
- base:padjm38bndw05ht(f08r1l1-priv-base,is_private=true,含 table mldokt6x5op0ocn;collab 已恢复 editor)、pr4in3ohbywbdoz(f08r1l1-open-base 对照)
- 说明:测试中曾将 owner 角色临时改为 'super-admin',已回滚 org-level-viewer;'super-admin' 串在代码中不触发任何 super 逻辑(OrgUserRoles.SUPER_ADMIN='super'),无权限残留
