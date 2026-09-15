# F08 R3 lane5 — 安全审计复审(R3,收敛第 2 轮)

审查对象:6aea3db097(实现)+ 2a86eb7d6c(R1 修复 7 项)+ b1d3ec3c5b(R2 小项)。
环境:nocodb-dev 后端 :8080 实测 + PG 18.2 nocodb-dev(qnap.elf-balance.ts.net)。测试前缀 `f08r3l5-*`。

## 结论

**issues(1)**

- `packages/nocodb/src/helpers/commandPaletteHelpers.ts:55:command palette 对私有 base 只排除 no-access 行,未排除 inherit 行 — 持 inherit 角色行(非显式协作者,meta 全 404)的用户经 POST /api/v1/command_palette 拿到私有 base 标题、表名、视图名,违反「palette 不泄漏」:补 is_private 分支 — `(b.is_private IS NOT TRUE OR bu.roles NOT IN (no-access, inherit))`,与 BaseUser.ts:602/636 列表过滤同构;公共 base 的 inherit 行保持现行为(继承可打开,列出不回退)`

实测证据(同一 member 用户、同一私有 base pvydzrbg76fnfow):
- member 持 `inherit` 行:GET /api/v2/meta/bases/:id → 404;POST /api/v1/command_palette `{"query":"f08r3l5"}` → 200 返回 `p-pvydzrbg76fnfow "f08r3l5 base"` + `tbl-mjauqq4wvhkketh "f08r3l5_tbl"` + `vw-vwdlaunpkwt73tmb` 视图条目
- no-access 行:palette → `[]` ✓(55 行 andWhereNot NO_ACCESS 已覆盖)
- 根因:palette 查询 innerJoin base_users 仅 `.andWhereNot('bu.roles', NO_ACCESS)`,不看 `b.is_private`,inherit 漏网;与 R1 修复的「base list legacy branch」(BaseUser.ts)同族缺口

## 逐项结果

### 1. 新改动面 b1d3ec3c5b(indexExists 方言无关化)— PASS

- 四方言 raw 查询全部 `?` 参数化绑定,index 名为硬编码字面量,无注入面;unknown dialect 回落 attempt-creation 行为,不异常
- `clientType` 源自 `knex.client.config.client`(服务端 knex 实例配置),无外部输入通道,不可被请求影响
- `rowsFromRaw` 对 pg(`{rows}`)/mysql(`[rows,fields]`)/sqlite(行数组)/mssql(`{recordset}`)四种返回形态归一正确
- 迁移 DELETE 窗口子查询(派生表 `AS dup WHERE rn>1` + `LIMIT ??`)为标准自引用 DELETE 包装,pg/mysql8/sqlite 兼容;`LIMIT ??` 数字绑定;该 DELETE 非 b1d3ec3c5b 新增(R2 已审),本次仅核方言兼容性
- down 侧 indexExists 守卫与 up 对称;knex dropIndex 前置存在性检查防重复删除报错

### 2. 修复稳定复检(2a86eb7d6c)— 全 PASS(实测)

| 项 | 实测 | 结果 |
|---|---|---|
| legacy api token 私 404 | psql 插 2 行(fk_user_id NULL):base-scoped + account-wide,GET /api/v2/meta/bases/:privId | 均 404 ERR_BASE_NOT_FOUND ✓ |
| legacy token 公 200 | 对照公共 base GET | 200 ✓ |
| legacy token 写拦截 | PATCH 私有 base title | 404 ✓ |
| shared-base 私 400 | 私有 base POST/PATCH /shared | 均 400「Shared links are not available for private bases」✓ |
| 预存链转私即 401 | public 时预存 uuid → 转私 → 匿名 `xc-shared-base-id` 访问 | 401 ERR_AUTHENTICATION_REQUIRED ✓ |
| boolean create | body `is_private:"yes"` | 400(schema 层先拦,service 层 strict boolean 双保险)✓ |
| boolean update | PATCH `is_private:"false"` | 400 ✓ |
| boolean 往返 | PATCH `is_private:false` → 200 → `true` → 200 | 200/200 ✓ |
| duplicate 防降级 | POST /api/v2/meta/duplicate/:baseId body `{base:{is_private:false}}` | 副本 `is_private=true`(duplicate.service.ts:113 spread 后强制覆盖)✓ |

### 3. 绕路面抽测(member/outsider 对私有 base)— 七类全 PASS

member 场景覆盖三档:显式 editor(200 基线)→ inherit → 无行;outsider 无 workspace 行;member 另有 workspace-level-viewer(继承)档。私有化后:

| 面 | 端点 | member(继承/无行) | outsider |
|---|---|---|---|
| v2 meta | GET /api/v2/meta/bases/:id | 404 | 404 |
| v2 data | GET /api/v2/tables/:tblId/records | 404 | 404 |
| v1 | GET /api/v1/db/meta/projects/:id | 404 | 404 |
| v1 data | GET /api/v1/db/data/:viewId | 404 | — |
| v3 | GET /api/v3/meta/bases/:id | 404 | 404 |
| shared | GET /api/v2/meta/bases/:id/shared | 404 | 404 |
| shared 匿名 | `xc-shared-base-id` 头 | 401(预存链) | 401 |
| snapshot | GET /api/v2/meta/bases/:id/snapshots | 404 | — |
| dashboard | GET /api/v2/meta/bases/:id/dashboards | 404 | — |
| export | GET /api/v2/tables/:tblId/records/export | 404(owner 对照 422 — mask 先于校验,无泄漏) | — |

显式协作者基线:editor 行在时 v2 meta/data、v1、v3 全 200 ✓(mask 不误伤);API 降级 no-access/inherit/删行后立即回 404 ✓。
公共链回归:公共 base share uuid 匿名访问 200,无过度拦截 ✓。

### 4. 判定链五处同源终审 — PASS(静态)

1. `extract-ids.middleware.ts:1257-1275` — 终审 mask:`req.ncBaseId && req.user && !isPublicBase` → 非 super → `base?.is_private` → `isLegacyApiToken = is_api_token && !id` 时 baseRoles 置空 → 非显式协作者 `baseNotFound` 404。特判不可伪造:`req.user` 由 passport strategy 服务端构造 — authtoken.strategy:52 `is_api_token:true` 服务端置位,`id` 仅在 `fk_user_id` 命中时取自 `User.getWithRoles`(DB);JWT 由服务端签名,客户端无法注入 `id`/`is_api_token` 组合绕过
2. `base-view.strategy.ts:32` — 私有 shared 链 auth 层 401;uuid 有效私有/uuid 无效均 401,存在性不可探测(仅 401 消息文本可区分,uuidv4 不可枚举,忽略)
3. `BaseUser.ts:602/636` — workspace-inherited 与 legacy 两分支列表过滤 `(is_private IS NOT TRUE OR EXISTS 显式角色 NOT IN (no-access,inherit))`,raw 全参数化
4. `duplicate.service.ts:113` — 副本隐私强制继承
5. `bases.service.ts:136-141/269-274` + `v3/bases-v3.service.ts:104` — create/update strict boolean;v3 is_private 映射真实列

来源语义核查:`sources.service.ts:220` / `bases.service.ts:375` 的 `is_private` 为 Integration.is_private(上游连接私有语义),与 Base 隐私判定链无交集,无污染。
ACL 语义:前端 `manageBaseType` creator+ only(acl.ts:156);后端 EDITOR include 无 baseUpdate → 实测 editor PATCH is_private 403、PATCH title 403 ✓。
TOCTOU:mask(extract-ids)与 handler service 层再查之间角色行可并发变更 — 单请求粒度,任务已知,低危记录不判 error。

### 5. 信息泄漏 — 1 error(palette,见结论)+ 其余 PASS

- base 列表:member(51 条)不含私有 base,owner 对照(60 条)含 → EXISTS 过滤真实生效 ✓
- 列表搜索:`?q=` / `?search=` 均不泄漏(结果集已被过滤)✓
- palette:inherit 行泄漏(**上唯一 error**);no-access/无行均 `[]` ✓
- 404 vs 403 统一:所有 meta/snapshot/dashboard/share/export 面统一 ERR_BASE_NOT_FOUND 404,与不存在 base 同响应,存在性不可探测 ✓

## 测试伪影注记(非缺陷,供其他 lane 参照)

psql 直改/直删 `nc_base_users_v2` 角色行后 mask 短暂不生效(仍 200)— `NocoCache` BASE_USER 角色缓存未失效,getWithRoles 读旧值;经 API(PATCH/DELETE base users)变更则立即生效。**绕过应用层写 DB 不保证缓存一致性,复测权限变更必须走 API。** psql 插**新**行(cache miss 先查 DB)无此问题,legacy token 插行法有效。

## E3

无。后端 :8080 全程存活,无连续失败,无外部限制。

## 复现数据(已清理)

测试 base ×3(soft delete)、legacy token 行 ×2、workspace_user 行 ×1 均已删;测试用户 `f08r3l5-{owner,member,out}@t.io` 保留(遵循前轮 f08r1* 先例)。
