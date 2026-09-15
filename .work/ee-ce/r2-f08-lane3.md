# F08 Private Base — R2 复审报告(lane3,收敛轮)

审查对象:6aea3db097(F08 实现)+ 2a86eb7d6c(R1 修复)。环境:nocodb-dev(qnap.elf-balance.ts.net:5432),后端 dev :8080(含修复,未重启),前端 :3000。

## 结论

issues:
- `packages/nocodb/src/meta/migrations/v0/nc_20260913_dashboard_title_unique.ts:29-37(up)/45-54(down)`:幂等守卫仅探测 pg(`knex.client.config.client` includes 'pg'),mysql2/sqlite3/mssql 安装若曾以 R1 前的 v2 注册部署过该迁移,升级后 v0 source 重放 up 时 `alterTable unique` 会因同名索引已存在抛错,整个 v0 批次 abort;down 同理。建议:比照 F08 迁移的 `knex.schema.hasColumn` 风格做跨方言安全探测(knex 无 hasIndex,可按 dialect 分支查 information_schema/pg_indexes/MYSQL information_schema.statistics/sqlite_master,或 try-catch 吞 duplicate-index 类错误)。现实暴露面:需「R1 前 fork 版本已部署 + 非 pg」,当前 fork 未发布,风险极低;F08 迁移自身无此问题。
- `packages/nc-gui/lang/en.json:6513` / `packages/nc-gui/lang/zh-Hans.json:4441`(minor):R1 commit 丢失文件末尾换行符(`\ No newline at end of file`),格式退化。
- 观察项(minor,非缺陷):F08 两个 commit 未新增专属 jest spec(extract-ids mask / strict-boolean 校验无回归测试);行为已由本轮 API 实测全覆盖。TASK 实现步骤含「补/改单测」,建议收敛后补。

无 E3。除上列外全部通过,主体验证矩阵零失败。

## 矩阵逐项结果

### 1. 迁移与 schema
| 项 | 结果 |
|---|---|
| xc_knex_migrationsv0 有 nc_20260913 两行(batch 2) | PASS(本库为纯 v0 安装,无 v1/v2 迁移表) |
| nc_bases_v2.is_private:boolean, default false | PASS;存量行全部回填 false(0 行 null);显式 null 行被 `IS NOT TRUE` 过滤(实测) |
| nc_dashboards_base_title_unique 索引 | PASS(实际表名 nc_dashboards_v2,MetaTable.DASHBOARDS 映射正确) |
| F08 up 幂等(已有列时) | PASS:nocodb-dev 实测重跑 up 走 hasColumn 守卫跳过,无 SQL |
| F08 down/up 对称 | PASS:down 删列→up 重建,default false 恢复(省略 is_private 插入 → false,实测) |
| F10 up 幂等 / down/up 对称 | PASS(pg):重跑被 pg_indexes probe 跳过;down 删索引→up 重建,均实测。跨方言缺口见 issues 第 1 条 |
| knex 3.1.0 `client.config.client` 探测 | PASS:实测返回 'pg',includes('pg') 成立 |

### 2. 旁路面(member = workspace-level-editor,无 base_users 行,普通用户非 super)
28 项全部 404,统一 `ERR_BASE_NOT_FOUND`(存在性不泄漏):

v1 meta get / v2 meta get / v3 meta get / v2 base PATCH / v2 base DELETE / v2 tables list / v3 tables list / v1+v2 users list / v1 api-tokens list / v2 duplicate(真实路由 /api/v2/meta/duplicate/:baseId)/ v2 snapshots list / v2 dashboards list / v2 variables / v1 shared meta / v2 meta-diff / v2 data(tableId 直连)/ v1 data list / v1 columns / v2 views / v2 fields / v2 table get / v2 webhooks(tableId 直连)/ csv export / base sources / share create。

控制组:member 对公开 base meta/tables/data 200;collab(显式 viewer)meta/tables/data/users 200、写操作 403。

首跑曾出现 member 经 meta get/PATCH/DELETE 读写删私有 base(且实际 soft-delete)——根因是**测试设置错误**(我把测试用户 psql 提权 super,mask 对 super-admin 按 设计 bypass);降回普通用户重跑后全部 404。非产品缺陷,但记录:super 对私有 base 全权是设计行为。

### 3. 回归
| 项 | 结果 |
|---|---|
| 公开 base 全 CRUD | PASS:member insert/delete records 200(v2 records delete 为数组 body 语义);owner rename 200 |
| 存量无 is_private base 行为不变 | PASS:53 行存量全部 false 回填,member 列表/访问正常 |
| base 重命名/复制/删除(owner 非 super) | PASS:rename 200、duplicate pub 200(job+base_id)、delete dup 200 |
| 工作区列表分页计数 | PASS:owner 建 2 个新 base,member totalRows +2、owner +2,list 长度与 totalRows 一致;member 列表恒不含 priv,collab/owner 含 |
| tsc --noEmit | PASS:exit 0,0 错误 |

### 4. R1 修复验证
| 修复 | 结果 |
|---|---|
| is_private 往返(sanitize one-way door) | PASS:PATCH false→200(GET 即时 false),PATCH true→200(GET 即时 true),缓存更新正常 |
| 非 boolean 400 | PASS:'true'/1/null 在 PATCH 与 create 均 400(ajv swagger 层拦截,service strict-boolean 为第二层) |
| duplicate 私有副本继承 | PASS:owner dup priv → 副本 is_private=t(psql 证);注入在 `...(body.base)` spread 之后,caller 无法降级 |
| shared-base 私 400/公 200 | PASS:create+update 对 priv base 均 400;pub create 200;匿名携 pub uuid 访问 base 200 |
| pre-existing link 封堵 | PASS:psql 给 priv base 注入 uuid 后,匿名携 xc-shared-base-id 访问 v1/v2 均 401(BaseViewStrategy is_private block) |
| legacy token(fk_user_id null) | PASS:psql 建 token,priv data 404 / pub data 200 |
| v3 members 映射 | PASS(带说明):`isPrivateBase: !!base.is_private` 传参正确;CE stub `base-member-helpers.ts` 的 getBaseMember 恒抛 "paid plans" 400,参数在 CE 不被消费,行为与上游 CE stub 一致,非缺陷 |

### 5. 交互面
| 项 | 结果 |
|---|---|
| F07 快照:priv base 建 snapshot | PASS:snapshot 200 status processing→completed;副本 base is_private=t(psql 证) |
| F07 restore 继承 | PASS:restore 200,产物 `f08r2l3-priv (restored)` is_private=t;member 对产物 404 |
| F07 删快照 | PASS:DELETE 200,副本 softDelete 进 trash(deleted=t),登记行删除 |
| F10 dashboard:priv base CRUD | PASS:owner create/list/get/patch/delete 全 200 |
| F10 dashboard:member 遮蔽 | PASS:list 404、dashboardId 直连 404 |

### 6. 代码复审(两 commit 全 diff + 调用方)
- extract-ids mask(`extract-ids.middleware.ts:1251-1278`):位于 acl 判定后;super-admin/组织 super bypass;`isPublicBase` 伪用户跳过由 BaseViewStrategy 的 is_private block 补位(实测 401);legacy token 判定 `is_api_token && !req.user.id` 与 auth strategy 的伪造 editor 对齐。逻辑与 BaseUser SQL 判定对称(NO_ACCESS/INHERIT 均不算 explicit)。
- BaseUser.getProjectsList 两分支 EXISTS 对称:workspace 分支 EXISTS 挂在 inheritance 子分支(explicit 子分支不需要);legacy 分支外层 where 漏排 'inherit' 由 EXISTS 补齐(实测 inherit 语义经 no-access 行为一致)。NULL roles 行被 `NOT IN` 自然排除,合理。
- duplicate.service 注入点:`is_private: !!base.is_private` 位于 body spread 后、fk_workspace_id 前,顺序正确;snapshot 复用同一 duplicateBase 路径,全链路继承已实测。
- bases.service baseCreate/Update:strict-boolean 校验在 validatePayload(已加 is_private 到 ProjectReq/ProjectUpdateReq)之后,双层拦截;`in` 判定对 JSON body 安全;更新路径 data.is_private 赋值绕过 DOMPurify whitelist,根因注释准确。
- 性能:mask 每请求 `Base.get(req.context, req.ncBaseId)` 走 NocoCache(PROJECT:id 对象缓存);User.getWithRoles 私有判定再查一次同 key 缓存,双查均为缓存命中,可接受。EXISTS 子查询命中 nc_base_users_v2 PK,列表查询无 N+1。
- UI:blockPrivateBases gate 翻转、store isPrivateBase 接真实 flag、acl `manageBaseType` 仅 creator+、Access.vue patch + toast i18n(en/zh 键齐全)、index.vue tab gating 一致。无 console.error/500 残留(全程无 500)。

## 覆盖统计
- API 实测请求 ~90 次;旁路面 28/28 通过;R1 修复 7 项全验证;交互面 F07/F10 全链路;迁移幂等 nocodb-dev 实测(up×2/down/up);tsc 0。
- 测试数据已清理(5 个 base 软删、legacy token 删除);测试用户 f08r2l3-*(owner/member/collab)及其 workspace_user/base_users 行保留于 nocodb-dev 供追溯,前缀隔离无冲突。
