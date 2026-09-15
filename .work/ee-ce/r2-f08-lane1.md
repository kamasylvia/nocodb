# F08 Private Base — R2 复审 lane1（收敛轮）

结论：**PASS（0 error）**；附 1 个低危非阻断项（迁移守卫方言不对称，不可达路径）+ 3 个观察项。

审查对象：`6aea3db097`（F08 实现）+ `2a86eb7d6c`（R1 修复，7 error）。后端 http://localhost:8080（含全部修复）+ nocodb-dev（qnap.elf-balance.ts.net:5432）实测；凭证经 Infisical 运行时拉取；测试号前缀 `f08r2l1-*`（owner=ws creator / member=ws editor 无 base 行 / collab=ws viewer / super=super），测毕 base 均已 soft-delete、token 行删除。

## 一、R1 修复验证（重点，全部实测）

| # | 项 | 结果 | 证据 |
|---|---|---|---|
| 1a | is_private 往返 | PASS | PATCH `true`→200 回读 `true`；PATCH `false`→200 回读 `false`；`"true"`/`1`/`null`→400 |
| 1a' | create 路径严格化 | PASS | POST bases `is_private:true`→200；`is_private:"true"`→400（swagger validatePayload 先拦 + service 守卫双保险） |
| 1b | 私有 shared link | PASS | 私有：POST shared→400、PATCH shared→400（同一文案）；转公开：POST→200 签发 uuid |
| 1b' | 预存 link 鉴权层拦截（BaseViewStrategy） | PASS | 匿名 + `xc-shared-base-id`：公开 base tables/records→200；PATCH 私有后同请求→401 `ERR_AUTHENTICATION_REQUIRED`；转回公开→200 恢复。证实 `getByUuid→metaGet2 select *` 携带 is_private，非漏拦 |
| 1c | duplicate 继承 | PASS | POST `/api/v2/meta/duplicate/:baseId`→200（job+base_id）；psql 副本行 `is_private=t` |
| 1d | legacy api token | PASS | 账号级 token（`fk_user_id` NULL）：私有 base→404、公开 base→200、公开表 records→200（上游行为保留）；base-scoped token 打非授权 base→401（上游 scope 强制，非 fork 范围）。测后删除行 |
| 1e | v0 迁移 | PASS | `xc_knex_migrationsv0` 含 `nc_20260913_add_is_private_to_bases` + `nc_20260913_dashboard_title_unique` 两行；本库为 fresh install（无 `xc_knex_migrationsv2` 表）→ 实证走 v0 路径；幂等守卫 `schema.hasColumn` 方言无关（代码复审） |

## 二、全矩阵复测（R1 基线）

- owner 建 base+table：200；PATCH 私有→200。
- member（仅 ws editor，无 base 行）：v2 列表不见、GET base/tables 404、records 404、audits 404、hooks 404、v1 legacy 列表不见——**全部 404（遮蔽而非 403）**。
- collab（ws viewer，无 base 行）：列表不见 + GET 404（工作区继承对私有不生效）。
- 显式协作者：base user invite（editor）→ GET 200 + 列表见；DELETE 协作行后**立即** 404 + 列表消失。
- super：GET 200 + 列表见（`Base.list` 不过滤，超管全通语义一致）。
- `is_private:false` 恢复：member 列表见 + GET 200；公开 CRUD 回归（records PATCH/GET/DELETE、owner insert 200）。
- 三方判定一致：extract-ids（404）/ getWithRoles（NO_ACCESS）/ getProjectsList（EXISTS 过滤）实测吻合；v3 baseGet owner 200、member 404；v3 list owner 200 含私有 base。
- 分页计数不失真：member totalRows 50=list 50；owner 52=52；v1 list 47=47。

## 三、后端 jest / tsc

- `npx jest`：**26/26 passed**（2 suites）。
- `npx tsc --noEmit`：**exit 0**。

## 四、代码复审（两 commit 合并看）

- **严格化与 duplicate 注入兼容**：`duplicateBase` 走 `basesService.baseCreate`，注入 `is_private: !!base.is_private`（boolean）→ 守卫放行；置于 `...(body.base||{})` spread 之后，caller 无法降级。✓
- **BaseViewStrategy 拦截顺序**：`sharedBase?.is_private` 对 undefined 短路 → 落到既有 `!sharedBase` 拒绝，无误拦/漏拦；运行时已实测生效（1b'）。✓
- **404 遮蔽覆盖**：AclMiddleware 全局注册（noco.module），`req.ncBaseId` 可解析的路由全遮蔽（meta/tables/records/audits/hooks 实测 404）；匿名 share 缺口由 GlobalGuard base-view 分支 + strategy 私有拦截补齐。✓
- **缓存一致性**：`Base.update` 以 `{...o,...updateObj}` 回写 PROJECT cache → PATCH 私有后 mask 即时翻转（实测无陈旧窗口）。✓
- **getProjectsList 守卫 SQL**：两条 raw EXISTS（workspace 继承分支 + legacy 分支）`?? .id` 引用 FROM 主表（未别名）正确；`IS NOT TRUE` pg/sqlite/mysql 通用。✓
- **UI**：`blockPrivateBases=false`、acl `manageBaseType` creator+（OWNER 经 include 继承）、Access.vue 面板 + 6 个 i18n key（en/zh 双语在位）、store `isPrivateBase` wired。代码级验证通过（运行时 UI 点击不在本 lane 范围）。✓

## 五、非阻断发现（不计 error）

1. **低危（不可达路径，未实测——本机无 sqlite 环境）**：`packages/nocodb/src/meta/migrations/v0/nc_20260913_dashboard_title_unique.ts:26`（F10 迁移，随 R1 commit 一并移入 v0）重跑守卫仅覆盖 pg（`pg_indexes` 查询）；sqlite/mysql 下，「曾执行过前 v2 注册」的 install 再跑 v0 batch 会因 index 已存在而中止。可达条件：fork 两 commit 间隔内升级 + 非 pg——fork 未发布，窗口仅本机 dev（全 pg），当前无真实暴露。建议：与 is_private 迁移同款做方言无关守卫（如 try/catch 或 sqlite `sqlite_master`/mysql `information_schema.statistics` 检查）。同文件 is_private 迁移守卫已是方言无关，两文件风格不一致。
2. **观察项（性能）**：extract-ids mask 与 `User.getWithRoles` 各对每 baseId 请求增加一次 `Base.get`；NocoCache 命中后 O(1)，非逐行 N+1，可接受。
3. **观察项（类型）**：nocodb-sdk `BaseType`（Api.ts:6829）无 `is_private` 字段；与 fork 既有 `is_snapshot` 处理同款（前端 `as any` cast），一致，建议后续补 SDK 类型。
4. **外部限制（E3 类，不计 error）**：v3 `?include=members` 被上游付费墙拦截（upstream commit `f384e0e62c` "base member operation now ee-specific and paid plans only"，返回 400 plan 提示）→ E8 的 `isPrivateBase: !!base.is_private` 映射修复位于该门后，运行时不可达；代码复审确认映射正确（原用 `default_role==='no-access'` 哨兵）。member 访问 v3 list 403 亦为 upstream baseList ACL（仅 org creator+），非 F08 引入。

## 覆盖统计

- API 实测请求 ~60 次，覆盖 v1/v2/v3 meta、records、audit、webhook、shared-base、duplicate、base users、api token 路径；4 角色矩阵；9 个 base/test fixture 全部清理。
- 代码：两 commit 全 diff + 调用方（bases.service / BaseUser / User / Base / ApiToken / authtoken.strategy / base-view.strategy / global.guard / duplicate.service / bases-v3 / meta.service 迁移 runner / sanitizeBase / acl.ts / Access.vue / useEeConfig / store/base / swagger）。
- 隔离纪律遵守：未读其它 lane 报告与 r*/patrol-* 归档。
