# F08 Private Base — R3 轮 lane1 报告（收敛第 2 轮）

审查对象：6aea3db097（F08 实现）、2a86eb7d6c（R1 修复 7 项）、b1d3ec3c5b（R2 小项）。HEAD = b1d3ec3c5b，工作树干净。

## 结论

**issues（1 项）**

- `packages/nocodb/src/services/public-metas.service.ts:380 publicSharedBaseGet`（`checkBaseType`:395 空实现）：base 转私后，**预存 share 链的匿名 meta 端点仍 200** 并返回 `base_id` + `base_title`，与 R1 commit 声称的 "pre-existing links stop resolving" 不符。实测：`PATCH is_private:true` 后 `GET /api/v2/public/shared-base/:uuid/meta`（带 `xc-shared-base-id`）→ 200 `{"base_id":"pfi5icznvqb1k1k","base_title":"f08r3l1-public"}`。根因：该路由仅挂 `PublicApiLimiterGuard`（public-metas.controller.ts:16），不经过 GlobalGuard/base-view strategy，R1 的 `base-view.strategy.ts` 拦截盖不到它；`checkBaseType` 是留白钩子却未填 `is_private` 检查。数据端点（records/tables meta）已正确 401（见 E4），故泄露面仅存在性（base_id/title），非数据泄露。建议：`checkBaseType` 内加 `if (base?.is_private) NcError.unauthorized(...)`（或 baseNotFound 保持遮蔽语义），同型处理 `checkViewBaseType`。

严重性：低-中（存在性泄露，无数据泄露）。单路属实、已实测复现。

## R1/R2 修复逐项实测复核（全部通过，除上述 E4 meta 残口）

| 修复点 | 实测 | 结果 |
|---|---|---|
| E1 is_private 往返 + 严格 boolean | PATCH false→200（终态 false 经 GET 确认）、PATCH true→200；字符串 `'true'`/数字 `1`/`null` PATCH→400 `must be a boolean`；create `is_private:"yes"`→400 | PASS |
| E2 迁移 v0 化 + 幂等 | `xc_knex_migrationsv0` 有 id=101 `nc_20260913_dashboard_title_unique`、id=102 `nc_20260913_add_is_private_to_bases`；v2 表不存在（fresh install 语义成立）；`nc_bases_v2.is_private boolean default false` 存在；unique index `nc_dashboards_base_title_unique` 存在；v0 up 带 `hasColumn` 守卫 | PASS |
| E3 legacy api token 404 | 真 legacy token（account-wide：`fk_user_id NULL` + `base_id NULL`，psql 插入）：GET 私有 base→**404 ERR_BASE_NOT_FOUND**、GET 公开 base→200、私有表 records→404、公开表 records→200、私有 base tables→404、无 ws 列表→[] | PASS |
| E4 shared-base | 私有建链→400 "Shared links are not available for private bases"；私有改链→400；公开建链→200+uuid；**转私后预存链**：records/tables meta（GlobalGuard 路径）→401（base-view strategy 拦截生效）✓，但 `/public/shared-base/:uuid/meta`→200（见 issue）；转回公开→链恢复 200 | PASS（含 1 issue） |
| E6 duplicate 继承 | 私有 base 副本 `is_private=t`；caller 传 `{"base":{"is_private":false}}` 降级尝试→副本仍 `t`（spread 后强制覆盖生效）；公开 base 副本→`f` | PASS |
| getProjectsList 双分支 | 带 workspaceId / 不带：owner 双见私有，wsmember 双不见；总数精确（见回归） | PASS |
| v3 映射 | v3 GET base：owner 200 / wsmember 404（extract-ids 遮蔽覆盖 v3 路由）/ collab 200 / super 200。注：R1 的 `isPrivateBase` 参数在 CE 传给 `base-member-helpers.getBaseMember`（stub，直接报付费墙），无可观察行为差异，映射正确性为代码级确认 | PASS |

### E3 复核过程中的归因说明（非代码问题）

最初两次反常（base-scoped legacy token 对 scope 内私有 base 200、scope 外公开 base 401）根因是 **psql 直改 `nc_api_tokens` 绕过应用层**，`ApiToken.getByToken`（ApiToken.ts:154）有 `NocoCache`（`API_TOKEN:token`）对象缓存，返回改前快照（旧 `fk_user_id` / 旧 `base_id`）。改用插入新行/应用层路径后全部符合预期。属运维陷阱，非 F08 缺陷；同理提示 F08 的 `Base.get` NocoCache 依赖「is_private 变更必须走应用层 baseUpdate」——E1/矩阵已实测 PATCH 后遮蔽即时生效，缓存更新路径正确。

## 全矩阵（终态：私有 base + collab 显式 editor）

| 角色 | 列表(带ws) | 列表(无ws) | GET base | tables | records | users | audit(internal recordAuditList) |
|---|---|---|---|---|---|---|---|
| owner | 200 见 | 200 见 | 200 | 200 | 200 | 200 | 200 |
| wsmember（ws editor 继承） | 200 不见 | 200 不见 | 404 | 404 | 404 | 404 | 404 |
| collab（显式邀请） | 200 见 | 200 见 | 200 | 200 | 200 | 200 | 200 |
| super（psql 提权，roles='super'） | 200 见 | 200 见 | 200 | 200 | 200 | 200 | 200 |

遮蔽语义统一 404（ERR_BASE_NOT_FOUND），无 403/200 泄露；audit 走 `/api/v2/internal/:wsId/:baseId?operation=recordAuditList` 同样被遮蔽。

### 即时性

- 移除协作者（DELETE base-users）→ 该用户 GET 立即 404、列表立即消失
- 重新邀请（editor）→ 立即 200 + records 200
- `is_private true→false`：wsmember 立即恢复 200；`false→true`：wsmember 立即 404、显式协作者不受影响 200
- 显式 `no-access` 行为负例：邀请 wsmember roles='no-access' 后 GET 仍 404、列表不见（EXISTS 与 extract-ids 双排除生效，已清理）

### 判定链一致性（代码确认）

`User.getWithRoles`（User.ts:668-684：inherit 行→resolve(null)→私有时强制 NO_ACCESS；no-access 行→保留非继承）、`BaseUser.getProjectsList` 双分支 EXISTS（`roles NOT IN ('no-access','inherit')`，ProjectRoles.INHERIT='inherit'/NO_ACCESS='no-access' 值匹配 DB 存储）、`extract-ids` 遮蔽（排除 NO_ACCESS/INHERIT + `is_api_token && !id` legacy token）三处语义对齐；super admin 三处一致放行（getWithRoles 提前返回 owner / extract-ids isSuperAdmin 跳过）。

## 回归

- 公开 base CRUD（wsmember 以 ws editor 身份）：GET/insert/PATCH/DELETE records 全 200（首次 PATCH/DELETE 404 系测试用错 URL——单行更新正确路由是 `PATCH /api/v2/tables/:id/records` body 带 Id，非 `/records/:rowId`，非产品问题）
- 列表计数精确：owner 53 条 = `pageInfo.totalRows` = list 长度；wsmember 50 条，差集恰为 3 个私有组 base（private + private copy + priv-dup2），无私有 base 泄入
- 存量 base：历史 53 条（Getting Started、F01/F05/F07/F10 遗留、R1/R2 legacy）双方可见性符合各自角色，无 42703/500
- 重命名私有 base 往返（title 改/改回）200×2；副本 base 软删 3 个全 200
- 前端 :3000 服务正常（UI 组件行为以代码审读为准：Access.vue 无逻辑缺陷、8 个 i18n key en/zh 全在、base/index.vue 无 stale import、store/acl/useEeConfig 接线正确）

## 测试与类型

- 后端 jest：**2 suites / 26 tests passed**（uniqueConstraintHelpers.Fork + baseVariableValidators.Fork）
- `npx tsc --noEmit`：**exit 0**

## 代码复审终审（b1d3ec3c5b 重点 + 扫尾）

- `indexExists` 方言分支：pg `pg_indexes.indexname` ✓；mysql `information_schema.statistics WHERE table_schema=DATABASE()`（DATABASE()=连接默认库，语义正确）✓；sqlite `sqlite_master type='index'` ✓；mssql `sys.indexes` ✓；未知方言 fallback=返回 false 继续尝试创建（旧行为，fail-loudly）合理。pg/mssql 的库名过滤缺失仅在跨 schema 同名索引时误报，单 schema 部署无碍（观察项，非 error）
- `rowsFromRaw`：pg `{rows}`、mysql2 `[rows,fields]`（Array.isArray(res[0]) 分支）、sqlite `[obj]`（直接返回）、mssql `{recordset}` 四驱动形态全覆盖 ✓
- dashboard 去重 DELETE 的 derived table 带 alias `d`，MySQL 8 合法 ✓
- `bases.service`：update 路径 is_private 移出 sanitize 白名单 + 严格 boolean；create 路径同校验；service 白名单与 model extractProps 白名单一致 ✓
- `duplicate.service`：`is_private: !!base.is_private` 置于 `...(body.base||{})` spread 之后，防降级 ✓；F07 snapshot 复用同一代码路径自动继承 ✓
- 性能：extract-ids 对每个带 baseId 的非超管请求多一次 `Base.get`（NocoCache 对象命中，无 DB 放大）——可接受
- F08 无新增后端 jest spec（遮蔽/过滤逻辑无直接单测，26/26 为既有 Fork 桶）——R1/R2 亦未加，TASK.md「补/改单测」留有缺口，观察项提请裁决

## 外部限制（E3 类）

无。后端/前端/DB/Infisical 全程可用。
