# F08 Private Base — R1 lane2 报告（集成测试 + 代码复审）

对象 commit: 6aea3db097。lane2 侧重权限矩阵与角色组合。测试数据前缀 `f08r1l2`（私有 base `p68be76pyfjpy3x` / 公开 `peryzu46iqw9cgu` / T1 `m8ocur7z504nj4n`，保留在库供复核）。

## 结论

issues 列表（2 error，1 观察不计数）：

1. `packages/nocodb/src/services/bases.service.ts:129`（baseUpdate extractPropsAndSanitize 白名单含 `is_private`）: `is_private:false` PATCH 必失败 400 `ERR_DATABASE_OP_FAILED "Invalid data type or value for column 'is_private'"`（PG 22P02），根因 `helpers/extractProps.ts` 的 `extractPropsAndSanitize` 对非空串值走 `DOMPurify.sanitize(body[key])`，实测 `sanitize(false)===""`（`sanitize(true)==="true"` 合法通过），空串写入 boolean 列即 22P02。后果：**私有 base 一旦设为私有无法经 API 转回公开（单向门）**，owner PATCH title+is_private=false 组合同样整体失败。建议：service 层对 boolean prop 直通（`typeof body[key]==='boolean' ? body[key] : DOMPurify.sanitize(...)`），或 Base.update 内 `updateObj.is_private = !!updateObj.is_private` 归一。
2. `packages/nocodb/src/strategies/authtoken.strategy/authtoken.strategy.ts:55-61`（legacy api-token 无 `fk_user_id` 分支硬编码 `base_roles={editor:true}`）: legacy token（`fk_user_id` 与 `base_id` 均 null）绕过 F08 遮蔽。实测（DB 造 legacy token 行）：`GET /api/v2/meta/bases/<私有base>` **200**（泄漏存在性与全量元数据）、`GET /api/v2/tables/<私有表>/records` **200**（数据可读）。机制：extract-ids 的 `hasExplicitBaseRole` 看到 editor 即放行。建议：该分支不再发放 base_roles（走 NO_ACCESS），或 F08 中间件对 `req.user.is_api_token && 无显式协作者判定源` 的 legacy token 一律 baseNotFound；最低限度在中间件排除 `is_api_token` 用户的 legacy 分支。
   - 备注：该行为先于 F08 commit 存在，但直接击穿 F08 语义，判 error。

观察项（不计 error，实测/复核依据）：
- create payload 注入 `is_private:true` 生效（createProject 用 nocodb-sdk `extractProps`，不经 DOMPurify）。创建者自动成为 base owner，语义自洽；无 plan gate（与 F01/F05/F07 同模式，fork 无 paywall）。
- 超管判定双轨不完全同形：extract-ids 看 `roles[super]||org_roles[super]`，getWithRoles 只看 `roles[super]`。方向安全（中间件放行更多只会落到 ACL 403），实测无影响。
- baseUserList（owner full mode）返回 190+ 用户含大量历史 `roles:null` 行（CE 既有行为）；F08 EXISTS 条件正确排除 `null/inherit/no-access`，不构成可见性缺口。

## 集成测试矩阵（API 实测，未重启后端）

| # | 场景 | 结果 |
|---|---|---|
| 1a | owner 建公开+私有 base（私有经 create payload `is_private:true`） | PASS（注入生效，DB `is_private=t`） |
| 1b | editor explicit 邀为私有 base editor → GET meta 200 / records 200 / 列表含私有 base | PASS（C1-C4） |
| 1b' | editor PATCH `is_private:false` | 403 `baseUpdate` Forbidden（editor 无权翻 privacy，符合上游 baseUpdate=creator/owner 语义）；但见 error#1：owner 翻 false 亦失败 |
| 1c | viewer：公开 base 列表可见+GET 200；私有 base 列表缺席+GET 404 `ERR_BASE_NOT_FOUND` | PASS（B1-B3） |
| 1c' | viewer 被显式邀为 base viewer → GET 200、列表恢复 | PASS（D3-D5） |
| 1d | member（无 base 角色）GET 私有 base users 列表 | 404（B5） |
| 1e | owner GET 私有 base 200；PATCH `{"title","is_private":true}` 组合 200 且落库 | PASS（D1/D2）；`is_private:false` 见 error#1 |
| 1f | 超管视角：GET meta 200 / records 200 / 列表含私有 / users 列表 200 | PASS（E1-E4；超管凭证经 DB 提权 f08r1l2-admin roles='super'，token 每请求回读 DB，路径真实） |
| 1g | 数据 API `/api/v2/tables/:tableId/records`：member 404（v2 数据路由经 tableId→ncBaseId 也走 F08 检查）；baseEditor 200 + 可写（insert 200） | PASS（B4/C3/J1） |
| 1h | API token：base 级 token（绑 owner）读私有 base meta/records | 200，与 UI token 一致（I1-I3） |
| 1i | legacy token（无 fk_user_id/base_id） | **FAIL** — meta 200 + records 200，见 error#2（K1/K2） |
| 3a | 协作者移除即时性：DELETE base user → viewer 立即 GET 404、列表缺席、editor 不受影响 | PASS（G1-G4，无重启） |
| 3b | is_private 切换即时性：true→false 后 Base.update 原地更新 PROJECT 缓存，行为一致（false 落库本身受 error#1 阻塞，切换后 GET 链路语义经 true 路径验证） | 部分（受 error#1 限制） |
| 3c | INHERIT 行 / no-access 行语义：DB 直插 `roles='inherit'` 与 `'no-access'` 行，均 404（getWithRoles INHERIT→null→F08 NO_ACCESS；EXISTS 排除二者），与 getProjectsList 双轨一致 | PASS（H3/H4） |

## 代码复审要点核对

- **User.getWithRoles NO_ACCESS**（`packages/nocodb/src/models/User.ts:668-686`）：explicit 判定 `roles === INHERIT`（'inherit' 恰为枚举值）→ null → 私有 base 直接 `NO_ACCESS`，涵盖 missing/null/inherit 行；viewer/editor/owner/commenter 等 explicit 值经 `extractRolesObj` 保留，继承跳过只影响无 explicit 角色者。org_roles 来源不受影响（`base_roles` 单独字段）。
- **双轨一致性**：getWithRoles（auth strategy 每请求调用）产出 base_roles；extract-ids 消费同一 `req.user.base_roles`，判定集合（非 NO_ACCESS/INHERIT 的 true 角色）与 getProjectsList EXISTS 子查询（`roles NOT IN ('no-access','inherit')`）三方一致；实测 INHERIT/no-access/缺行三态 GET 全 404、列表全缺席。
- **getProjectsList**（`packages/nocodb/src/models/BaseUser.ts:596-604`）：EXISTS 参数绑定正确（PROJECT_USERS 表名、PROJECT.id、userId、两个排除值）；workspaceId 缺席的 legacy 分支要求 explicit 行且非 NO_ACCESS，天然不含私有泄漏。分页：函数无 limit/offset（调用方 bases.service baseList 透传 query 亦被忽略），整表过滤无 count 失真问题。
- **白名单冗余**：Base.update extractProps 与 service baseUpdate 白名单均含 `is_private`，两层一致非冲突；但 service 层 sanitize 链路损坏 false 值（error#1）。audit：baseUpdate emit `PROJECT_UPDATE`（updateObj 含 is_private）+ socket `base_update`，无独立 is_private 审计字段（与 CE 同类更新一致，观察）。
- **create 注入**：baseCreate swagger ProjectReq 无 `is_private`（additionalProperties 未设，AJV 不拒）→ 透传生效；owner-only 建私有语义合理，无越权面（创建者即 owner）。
- **bulk 路径**：无 base 级 bulk 更新接口（bulk 仅 records 域，经 tableId 亦被 F08 覆盖）。
- **缓存**：Base.update 原地 merge PROJECT 缓存（is_private 即时生效）；BaseUser.get 缓存键为角色行非 base 行，baseUserDelete 即时清缓存实测通过；getWithRoles 新增每请求一次 `Base.get`（缓存命中，开销可忽略）。

## 环境说明

- 实例已有 6 个历史 super 用户（无凭证）→ 超管实测经注册 f08r1l2-admin + DB `roles='super'` 提权（authtoken strategy 每请求回读 DB，路径真实）。
- 测试用户 workspace 行曾因 signup 预建 `workspace-level-no-access` 行导致 API 邀请冲突，经 DB 修正为规范角色值后走 API 验证（不涉 F08 代码路径）。
- 临时探针（legacy token 行、INHERIT/no-access 行）已清理；`f08r1l2-*` base/用户保留供复核。
