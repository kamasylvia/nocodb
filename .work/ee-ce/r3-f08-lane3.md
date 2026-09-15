# F08 Private Base — R3 复审 lane3 报告(收敛第 2 轮)

日期:2026-09-14
审查对象:6aea3db097(F08 实现)+ 2a86eb7d6c(R1 修复 7 项)+ b1d3ec3c5b(R2 indexExists 方言无关化)
环境:dev server :8080(uptime 实测存活,未重启),nocodb-dev(qnap.elf-balance.ts.net:5432,PG 18.2)
测试账号:f08r3l3-owner / f08r3l3-member / f08r3l3-t3(@x.com)

## 结论

**PASS** — 0 error。R1/R2 修复全部验证稳定;迁移/旁路/回归/防降级终审无新发现。无 E3。

---

## 1. 迁移终审(本轮重点)

### 1.1 b1d3ec3c5b indexExists 方言无关化(R2 我提项,重点复核)

代码走查 `packages/nocodb/src/meta/migrations/v0/nc_20260913_dashboard_title_unique.ts`:

- **pg 分支行为不变**:`indexExists` pg 分支仍查 `pg_indexes WHERE indexname = ?`,up 里命中即 return、down 里不命中即 return——与 R2 前 pg-only guard 逐语义等价。
- **knex 3.x clientType 形态实证**(本机 node + knex 3.1.x):
  - `Knex({client:'pg'})` → `client.config.client === 'pg'` ✓
  - `'mysql2'` → `'mysql2'` ✓(includes('mysql') 命中)
  - `'sqlite3'` → `'sqlite3'` ✓
  - `client` 传 **dialect class** 时 `client.config.client === undefined` → 走 unknown fallback(尝试创建)= 保留 pre-guard 行为,可接受。
  - nocodb 实际构造链:`meta.service.ts:59 XKnex({...config.meta.db})`,client 值来自 `nc-config/constants.ts:1 driverClientMapping`(mysql/mariadb→'mysql2',postgres/postgresql→'pg',sqlite→'sqlite3')或 driver 透传('mssql')——**恒为字符串**,class 形态在本仓不可达。upstream 自身同款探测(`meta.service.ts:437 client.config.client === 'sqlite3'`)佐证形态稳定。
- **rowsFromRaw 形态兼容**:dev DB node+knex 实测 pg raw resolve 值 keys 含 `rows`(实测 `['command','rowCount','oid','rows','fields',…]`),`rowsFromRaw` 命中 `res.rows` 分支;嵌套数组(mysql2 raw=`[rows,fields]` → `Array.isArray(res)&&Array.isArray(res[0])` → 取 `res[0]`)、平数组(sqlite)、`recordset`(mssql)三形态走查逻辑正确。实测:index 存在 → rows=1 → true;不存在 → rows=0 → false。
- **方言 SQL 正确性走查**:mysql `information_schema.statistics WHERE index_name=? AND table_schema=DATABASE() LIMIT 1`(限当前库);sqlite `sqlite_master WHERE type='index' AND name=?`;mssql `sys.indexes WHERE name=?`(sys.indexes 为 db 级,无需 schema 过滤)。均参数化绑定。
- **up/down 对称**:up = dedupe DELETE → indexExists?return : createUnique;down = !indexExists?return : dropUnique。守卫条件互为对偶 ✓。
- **dedupe 前置无副作用**:index 已存在时 DELETE 子查询 rn>1 无行可删(唯一索引保证),注释声明的 no-op 成立。

### 1.2 F08 迁移(v0/is_private)

- 现登记:`XcMigrationSourcev0.ts:212-213` 两条 20260913 注册 + `:423-426` getter;v2 source 已完全摘除(import/数组/getter 三处无残留;`v2/` 目录下两文件已删除,`ls v2/ | grep 20260913` 为空)。
- `v0/nc_20260913_add_is_private_to_bases.ts`:up/down 均有 `hasColumn` 守卫,对称 ✓。
- dev DB 实证:`xc_knex_migrationsv0` 含 `nc_20260913_dashboard_title_unique` + `nc_20260913_add_is_private_to_bases` 两行;`nc_bases_v2.is_private boolean default false` 存在;`pg_indexes` 含 `nc_dashboards_base_title_unique`。dev 属「旧安装(v1 表存在)+ v0 重放」场景,server 正常启动且 base list 全功能——v0 重放幂等已实战通过。

---

## 2. 旁路面(member 对私有 base 全 404)

member 配置:org-level-viewer(后测 org-level-creator)+ workspace-level-viewer(后测 workspace-level-creator)+ 0 条 `nc_base_users_v2` 行。

| 面 | 端点 | 结果 |
|---|---|---|
| v2 meta | GET /api/v2/meta/bases/:priv | 404 ERR_BASE_NOT_FOUND |
| v1 meta | GET /api/v1/db/meta/projects/:priv | 404 |
| v3 meta | GET /api/v3/meta/bases/:priv | 404 |
| sources | GET …/priv/sources(v2) | 404 |
| users | GET …/priv/users | 404 |
| api-token | GET …/priv/api-tokens | 404 |
| shared | GET/POST/PATCH …/priv/shared | 404 |
| dashboard | GET …/priv/dashboards | 404 |
| variable | GET …/priv/variables | 404 |
| snapshot | GET/POST …/priv/snapshots | 404 |
| duplicate | POST /api/v2/meta/duplicate/:priv | 404 |
| meta-diff | GET /api/v1/db/meta/projects/:priv/meta-diff | 404 |
| data | GET /api/v2/tables/:t/records、/count、/aggregate、csv exportType | 404 |
| v1 data | GET /api/v1/db/meta/tables/:t | 404 |
| hooks | GET /api/v2/meta/tables/:t/hooks | 404 |
| views | GET /api/v2/meta/tables/:t/views | 404 |
| v1 alias | GET /api/v1/db/data/noco/:priv/:tbl(owner 同 URL 同 404 ERR_TABLE_NOT_FOUND,行为一致无泄漏差异) | 404 |
| list | v2 legacy(v2/meta/bases/)、v2 workspace-scoped、v1 legacy、v3 scoped:owner/member 对照,member 各形态均不含 priv | ✓ |
| ws role 升级复测 | member 升 workspace-level-creator / org-level-creator 后重测:GET priv 仍 404,两种 list 形态仍不含 priv | ✓ |
| 匿名 | 无头无 shared-id 请求 | 401/404 正常 |

统计:23 个非「路由不存在」端点全部 404 mask;错误体只回显请求的 baseId,无额外信息泄漏。

## 3. 回归

- **公开 base CRUD**:member GET base/tables/records 全 200;owner 建表建行 200。
- **存量 base**:member legacy list totalRows=51(与 ws-scoped 一致),owner 63 含 priv——分页计数精确排除私有 ✓。
- **is_private 往返+类型**:create 带 is_private:true → 读取 true;PATCH true→false→true 双向 200 且 DB 落 boolean(1);PATCH `"true"`(字符串)→ 400(swagger validatePayload 层,service 层 strict-boolean 为第二道防线)。
- **duplicate 继承+防降级**:POST /api/v2/meta/duplicate/:priv → 副本 is_private=t;body `{"base":{"is_private":false,"title":"…-dl"}}` 降级尝试 → 副本仍 is_private=t(`duplicate.service.ts` spread 后强制覆盖生效)。
- **shared 三态**:私有 base create share → 400、update share → 400;公开 base create share → 200 得 uuid;匿名 `xc-shared-base-id` resolve(v3 meta / v2 records)公开 200 → 私有化后 401(`base-view.strategy` R1 拦截生效)→ revert 后 200 恢复。
- **legacy token**(真实无 fk_user_id 行):GET priv base / records → 404;GET pub base / tables → 200。fine-grained token(owner 用户)GET priv → 200(用户上下文继承)。
- **邀请链**:POST …/priv/users {editor} → member GET base/records 200、list 含 priv;DELETE base-user → member 立即回到 404、list 不含 ✓。
- **非 super 显式协作者正路**:t3(org-level-creator + base_users owner 行,非 super)GET base/records 200、PATCH is_private 往返 200——mask 不误伤显式协作者 ✓。
- **F07 快照继承链**:priv base 快照 status processing→completed;快照副本 base is_private=t;member 对副本 404;restore 产物「f08r3l3-priv (restored)」is_private=t ✓。
- **F10 dashboard**:owner 在 priv base 建 dashboard 200;member GET priv dashboards 404;owner 在 pub 建 200,member GET pub dashboards 403(CE viewer 无 dashboardList 的原生 ACL,非 F08 泄漏)。
- **tsc --noEmit**:exit 0。**jest**:2 suites / 26 tests 全过(Fork 桶)。

## 4. R1/R2 修复复核(代码走查)

- `extract-ids.middleware.ts:1255-1278`:mask 条件 `req.ncBaseId && req.user && !req.user.isPublicBase`,super-admin 短路,`isLegacyApiToken = is_api_token && !id`(与 `authtoken.strategy.ts:52-58` 的 fabricate 行为精确对位),hasExplicitBaseRole 排除 NO_ACCESS/INHERIT——与 `User.getWithRoles` 的 F08 分支(无显式角色→NO_ACCESS 跳过继承)语义一致。
- `BaseUser.getProjectsList`:workspaceId 分支的 filter 嵌在「无显式角色→工作区继承」Priority-2 内(显式协作者走 Priority-1 不受影响);legacy 分支 andWhere 同款 EXISTS。两处 `??`/`?` 全参数化,`bu2` 别名与外层无冲突,相关子查询非 N+1。
- `bases.service.ts`:update 路径 is_private 移出 sanitize 白名单 + strict boolean;create 路径同款 strict boolean——双向闭合。
- `shared-bases.service.ts` create/update 双入口 400;`base-view.strategy` auth 层拦截存量链接(且保留上游 `default_role` 拦截,双层)。
- `bases-v3.service.ts:102` isPrivateBase 映射 `!!base.is_private` ✓。
- nc-gui:`useEeConfig.blockPrivateBases=false`;`Access.vue` Base Type 面板(PATCH meta/bases/:id,本地乐观更新 + i18n toast);`acl.ts` creator 级 `manageBaseType`(member 实测 403 印证);`store/base.isPrivateBase` 接真值;swagger.json ProjectReq/ProjectUpdateReq is_private(3 处)✓;lang 两文件行尾换行已恢复(b1d3ec3c5b)。
- 缓存面:`getWithRoles` 的私有探测经 `Base.get`(NocoCache),实测 privatize 后下一个请求立即 401/404,无陈旧窗口。

## 5. 终审扫尾

- SQL 对称性:两迁移 up/down 互逆 ✓;EXISTS 过滤两分支同构 ✓。
- 错误消息:404 只回请求 id;401/400 消息 generic,无内部信息泄漏。
- 测试残留:f08r3l3-* 三个用户、4 个 base(2 主 + 1 副本 + 1 restore)、1 快照、token/uuid 各一,留 dev 库与前轮一致;token 临时文件已清理。

**最终结论:PASS**
