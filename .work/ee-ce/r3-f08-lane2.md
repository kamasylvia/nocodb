# F08 Private Base — R3 复审报告（lane2，收敛第 2 轮）

审查对象：6aea3db097（实现）+ 2a86eb7d6c（R1 修复 7 项）+ b1d3ec3c5b（R2 小项）
方法：五处判定链源码终审 + nocodb-dev（qnap.elf-balance.ts.net:5432/nocodb-dev）API 逐格实测。
测试用户前缀 `f08r3l2-*`；测试 base 已软删、api token 行已清、合成行已删。

## 结论

**PASS**（0 实际 error；3 项非阻塞观察项，均不可经 API 触达，见末节）。

## 1. 角色×私有权限矩阵（逐格实测）

私有 base `pha0db8m2qjxi9q`（is_private=t，含表 t1）；公开对照 `ppsbkv2ta7mw7q0`。
LIST=GET /api/v2/meta/bases/ 中是否出现该 id；GET=base 读；DATA=records 列表；USERS=base users 列表；PATCH=base 更新（空体）。

| 角色 | 私有 LIST | 私有 GET/DATA/USERS/PATCH | 公开 GET | 公开 PATCH |
|---|---|---|---|---|
| 超管（org super） | 列出 | 200/200/200/200 | 200 | 200 |
| ws creator（无 base 行，wscr2） | 不列 | 404/404/404/404 | 200 | 403 |
| ws editor | 不列 | 404/404/404/404 | 200 | 403 |
| ws viewer | 不列 | 404/404/404/404 | 200 | 403 |
| ws no-access | 不列 | 404/404/404/404 | 403 | 403 |
| 无行用户（psql 造，无 ws/base 行） | 403（workspace 无角色，拒绝列表调用本身） | 404/404/404/404 | 403 | 403 |
| base owner | 列出 | 200/200/200/200 | 403* | — |
| base creator | 列出 | 200/200/200/200 | 403* | — |
| base editor | 列出 | 200/200/200/403 | 403* | — |
| base viewer | 列出 | 200/200/200/403 | 403* | — |
| base commenter | 列出 | 200/200/200/403 | 403* | — |
| explicit no-access | 不列 | 404/404/404/404 | 403* | — |
| explicit inherit | 不列 | 404/404/404/404 | 403* | — |

\* 公开列 403：这些用户 ws=no-access、仅在私有 base 有行——公开 base 无行时 ws 继承得 no-access，ACL 正确拒绝。符合语义。
关键语义全部正确：私有 base 对「无显式真实角色者」整体消失（列表不出现 + 单点 404 掩盖存在性）；显式真实角色（owner/creator/editor/viewer/commenter）全部可见；no-access/inherit 行不产生可见性；PATCH（baseUpdate）creator+ 专属，editor 及以下 403。

## 2. PATCH is_private 权限链 + boolean 校验

- base editor 对私有 base PATCH `{is_private:false}` → 403（掩码放行、baseUpdate 拒）✓
- ws editor / ws viewer 对公开 base PATCH `{is_private:true}` → 403（非该 base creator，不能翻转）✓
- base creator PATCH `{is_private:false}` → 200，再 `{is_private:true}` → 200（双向闸门正常）✓
- 非 boolean（update 入口）：`"true"` / `"false"` / `1` / `null` → 全部 400 `is_private must be a boolean` ✓
- 非 boolean（create 入口）：`is_private:"yes"` / `"false"` → 400（swagger validatePayload + service 双层）✓；`is_private:true` → 200 建出即私有（DB 复核 t）✓

## 3. R1/R2 修复复核（逐项）

| 修复项 | 实测结果 |
|---|---|
| legacy api token（psql 插无 fk_user_id 行） | 私 GET=404 DATA=404；公 GET=200 DATA=200 ✓（掩码将无主 token 视为非协作者） |
| 现代 token（ws editor 持有） | 私 404 / 公 200 ✓（authtoken→getWithRoles F08 分支生效） |
| 现代 token（base editor 持有） | 私 200 / 公 403（公 base 无行）✓ |
| inherit 行（ws no-access） | 列表不出现 + GET 404 ✓ |
| inherit 行 × ws editor 叠加 | GET 仍 404、列表不出现 ✓（私有跳过 ws 继承，不因 ws 角色升高而泄漏） |
| v3 members 映射 | `include=members` → CE 付费墙 400「only available on paid plans」（协作者与 owner 同）；非协作者 ws editor → 404。按任务口径记录 CE 付费墙行为 ✓；`isPrivateBase: !!base.is_private` 映射正确 |
| duplicate 继承 | 复制 `f08r3l2-priv copy` DB is_private=t ✓ |
| shared-base 三态 | 公建链 200 → 私建链 400 → 转 私 后旧链匿名 GET 401（BaseViewStrategy 拦截）→ 私上 update 链 400 ✓ |
| 迁移 v0 注册 + 守卫 | xc_knex_migrationsv0 两行在；v2 目录无残留；up/down hasColumn 守卫对称；indexExists 方言无关（pg/mysql/sqlite/mssql/未知五分支）✓ |
| lang 尾换行 | en.json / zh-Hans.json `\n}` 结尾 ✓ |
| acl 注释 | manageBaseType 注释已改为「OWNER reaches it through role-scope include merging」✓ |

## 4. 即时性（全部旧 JWT，signin 后未刷新）

- 邀请：pre-invite GET 404 → invite editor 200 → 同 token 立即 GET 200 + 列表出现 ✓
- 移除：DELETE base user 200 → 同 token 立即 GET 404 ✓
- 转私：公开 base PATCH is_private=true → ws editor 旧 token 立即 GET 404 + 列表消失 → 改回 200 恢复 ✓
（模型层写入均经 API，NocoCache 失效正确；无陈旧窗口）

## 5. 代码复审（五处判定链语义同源终审）

1. **extract-ids.middleware.ts:1247-1274**：`req.ncBaseId && req.user && !isPublicBase` → 非 super → `Base.get` → `is_private` → 无显式真实角色（排除 NO_ACCESS/INHERIT）→ `baseNotFound`（404）。`isLegacyApiToken = is_api_token && !id` 对齐 authtoken.strategy:56-59 的无主 token 伪 user。位置在 ACL 判定前 → 404 优先于 403，无存在性泄漏。
2. **jwt.strategy.ts:31-41**：`getWithRoles(baseId=req.ncBaseId)`；api_token/oauth_token 载荷提前返回，api token 走 authtoken.strategy（同样调 getWithRoles）→ 两条 auth 路同源。
3. **User.ts getWithRoles:694-719**：`BaseUser.get` INHERIT 行→null；'' 行→falsy→null；无行→null。`!effectiveBaseRoles && isPrivateBase` → NO_ACCESS，跳过 ws 继承；有真实角色行不受影响。super 提前返回 OWNER 不经过此路径 ✓。
4. **BaseUser.ts getProjectsList**：workspace 分支 Priority 1（显式真实角色）天然排除 no-access/inherit；Priority 2 加 `is_private IS NOT TRUE OR EXISTS(bu2 ... NOT IN ('no-access','inherit'))` 掩码；legacy 分支同款 EXISTS（R1 补）。`NULL NOT IN (..)` 求值为 NULL → null 角色行不满足 EXISTS → 正确隐藏。两分支语义一致。
5. **base-view.strategy.ts:29-40**：先挡 fork `is_private`（401），再保留上游 `default_role` 挡（EE 形状兼容），伪 user 不再产生 → extract-ids 的 `!isPublicBase` 跳过不会成为旁路。`default_role` 与 `is_private` 双挡冗余但同向。

辅助面：后端 acl.ts 为闭世界 include 模型，creator/owner 走 exclude 兜底 → `baseUpdate` 仅 creator+（无新增白名单项，符合「is_private 搭 baseUpdate 便车」设计）；sanitizeBase 不剥 is_private；Base.update 更新缓存对象（PATCH 后即时生效，实测印证）；BaseUser.insert/bulkInsert 走 NocoCache 深删（邀请/移除即时性实测印证）；duplicate.service `is_private: !!base.is_private` 置于 spread 之后，调用方无法降级 ✓；swagger ProjectReq/ProjectUpdateReq 已文档化。

## 6. 观察项（非 error，均不可经 API 触达）

1. `BaseUser.ts` getProjectsList 两处 raw SQL `is_private IS NOT TRUE`：pg/mysql(≥支持 IS NOT TRUE)/sqlite(3.23+) 均支持；mssql(T-SQL) 不支持。mssql 并非上游官方 meta db 支持面（NC_DB 文档仅 sqlite/mysql/pg），dev 仅 pg → 不可达。R2 已对 index 守卫做方言无关化，同类防御此处可后补（按 clientType 分支或 knex 原生谓词）。
2. `nc_base_users_v2.roles=''`（空串）合成行（DB 直插）：列表 Priority 1 把 '' 当真实角色 → 私有 base 被列出；GET 路径 ''→falsy→null→F08→404。列表可见但单点 404 的不一致。invite API 严格校验角色枚举（`Invalid role`），无造出路径；仅直插 DB 可复现。建议 hardening：Priority 1 / legacy 分支谓词追加 `roles <> ''`。
3. v3 base read 响应体不含 `is_private` 字段（v3 类型形状；swagger 仅 v2 ProjectReq/ProjectUpdateReq 文档化）。v3 非协作者 404 掩码生效，隐私语义不受影响；如需 UI/v3 消费可后续补 v3 类型。

## 7. 测试痕迹清理

- 测试 base（priv/pub/pub3/priv copy/priv2）API 软删 5/5
- nc_api_tokens 测试行（legacy + 2 modern）删除 3/3
- 合成 '' 角色行删除
- 测试用户（f08r3l2-*，14 个）保留于 nocodb-dev（ws no-access 角色，无 base 行残留；可后续统一清理）
