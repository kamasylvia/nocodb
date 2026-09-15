# F02 Edit field permissions — R2 会审 lane1 报告(收敛轮,2026-09-13)

审查对象:4b26d7a23f(实现)+ e85a421d92(R1 修复)。方法:独立集成测试(nocodb-dev 实测,自建脚本 `.work/ee-ce/r2-lane1-setup.sh` + `r2-lane1-tests.sh`,全新 base/3 账号矩阵)+ 全量 diff 代码走读。实现者自测 f02-e2e.sh 复验 22/22;jest 26/26;tsc --noEmit 0。

## 结论:issues(3)

1. `packages/nocodb/src/db/BaseModelSqlv2.ts:10575,10613,3057` + `packages/nocodb/src/services/permissions.service.ts:83`:4 处 console.log 调试探针(`[F02-R]`/`[F02-P]`/`[F02-Q]`/`[F02-Z]`)残留:R1 commit message 声称 "Debug probes removed" 但均由 e85a421d92 引入且未删。每次数据写请求打印 user 有无/projectRole/权限行数/列 id 前缀(信息泄露 + 全站写路径日志洪水),违反 TASK 验收「无 console 残留」。建议:删 4 处 console.log 及配套 eslint-disable。
2. `packages/nocodb/src/models/Permission.ts:274-349`(update)+ `packages/nocodb/src/services/permissions.service.ts:110-132`:PATCH 未校验 granted_role——R1 的 granted_role 枚举 + minimumRole 校验只加在 insert(Permission.ts:212-235),update 路径完全缺失。实测:PATCH `{granted_type:"role",granted_role:"viewer"}` → 200;`granted_role:"NotARole"` → 200 且 DB 落库。后果:未映射角色使 evaluatePermission 恒 false → 该字段对除 owner 外所有人拒(fail-closed 副作用,实测 editor 写 403),list 原样返回垃圾值,前端 getPermissionSummary 回落 EDITORS_AND_UP 显示「可编辑」与实际 403 相反。实现者自测(f02-e2e.sh:124,127)只测 POST,系盲区。建议:把 insert 的枚举+minimumRole 校验抽公共函数,update 的 targetType=role 时同样执行。
3. `packages/nc-gui/composables/usePermissions.ts:48-60` + `packages/nc-gui/components/dlg/Field/Permissions.vue:72,160,178`:loadPermissions 的 guard(`loadedFor===baseId` 即 return)使弹窗打开/保存/重置后的 `await loadPermissions()` 在同 base 下全部 no-op——Permissions.vue:159 注释声称 "refresh the shared grant list so grid/form react immediately" 从未生效。后果:creator 保存 grant 后本端 permissions 陈旧:a) creator 自己写该字段 UI 显示可编辑但后端 403;b) 重开弹窗 loadCurrentGrant 读旧列表显示「默认」,再次保存 POST 触发后端 dedup 400(用户可见错误链)。建议:loadPermissions 加 force 参数供弹窗 save/reset 使用,或保存后用响应直接 mutate permissions.value。

## 观察项(非 error)

- O-1 multi-grant 规则前后端不一致:后端 any-deny(BaseModelSqlv2.ts:10642-10657),前端 usePermissions.isAllowed:159 只评 grants[0]。service 的 (entity,entity_id,permission) 去重使正常路径单 grant,仅存量脏数据时 UI 与后端可能漂移。
- O-2 nobody 转换清 granted_role 不清 subjects(Permission.update:319-321);实测 nobody→user 无 subjects → 200 且静默复用残留 subjects。R1 message 声称 "clears granted_role/subjects" 的 subjects 部分未实现,清理不对称。
- O-3 datas.service.ts:1216-1219 置 `req.isPublicForm=true`,但该路径走 baseModel.insert → insert.ts single 挂点(69-75)不传 `options.isFormContext`,enforce_for_form=false 豁免对认证视图级插入(POST /data/:viewId/)无效。保守方向(多拦)偏差。
- O-4 Permission.list 对每行 grant 单独查 subjects(N+1),且 checkPermission 每写请求全量 list(R1 为正确性主动去缓存);grant 数大时放大,建议后续用单条 join 查询。
- O-5 快照创建期间观察到并发请求 body 截断(ERR_INVALID_JSON 瞬态,复测 4 次全部消失),疑似复制 job 阻塞事件循环,F07 范畴记录。
- O-6 public form 匿名提交经 NOCO_SERVICE_USERS[ANONYMOUS_USER] 注入(public-datas.service.ts),checkPermission 的 user=null 匿名分支实际不可达,拒绝经「未映射角色 → evaluatePermission false」达成;行为正确但代码注释描述的机制与实际路径不符。

## R1 修复逐项实测(集成,独立数据)

| 项 | 结果 | 证据 |
|---|---|---|
| nestedInsert v1 路由 nobody 拦截 | PASS | editor POST /api/v1/db/data/noco/:base/:tid 带 Secret → 403;不带 → 200;v2 同 403 |
| 匿名公共表单 enforce_for_form | PASS | anon w/ Secret:enforce=true → 403;=false → 200;role-enforce=true → 403;不带 Secret → 200 |
| 重复 grant 拒绝 | PASS | 同 (field,col,RECORD_FIELD_EDIT) 二次 POST → 400(v1+v2 双路径) |
| multi-grant any-deny | PASS | psql 植入存量 nobody+role-editor 双行 → editor 写 403 |
| granted_role 校验 | 部分 | POST bogus/viewer → 400(✓);PATCH bogus/viewer → 200+落库(✗→Issue 2) |
| user grant subjects 校验 | PASS | PATCH→user 无 subjects → 400;user grant 矩阵:非主体 403 / 主体 200 |
| nobody 清脏态 | 部分 | granted_role→NULL(✓);subjects 残留(→O-2) |
| table-entity 拒绝 | PASS | entity=table POST → 400 |
| form 提交传 req+isPublicForm | PASS | 上行匿名表单 4 例全符合预期 |
| owner 直通 | PASS | nobody 下 owner PATCH/insert Secret → 200 |
| skip 通道 | PASS | 含 nobody-grant 字段的 base 创建快照 → 200;import/duplicate 走 raw=true+skipPermissionCheck=true 双保险(import.service.ts:2494) |
| 缓存即时性 | PASS | delete grant → editor 即刻 200;create nobody → editor 即刻 403 |
| fail-open | PASS | 无 grant 表 editor 全 CRUD 200(v2 bulk/v1 单条/v1 bulk/删除) |
| ACL creator+ | PASS | editor GET/POST permissions → 403;creator → 200 |
| 校验面 | PASS | bogus permission key/bogus column/team subject/未知 permissionId(404)/越权 id 归属全 400/404 |

## 回归与门禁

- F05 variables / F07 snapshots / F10 dashboards list → 200;F08 base.is_private=false 正常返回
- jest:`pnpm test` 2 suites 26/26 PASS;tsc `--noEmit` exit 0
- 实现者自测 f02-e2e.sh 复验 22/22(其 granted_role 用例仅覆盖 POST,PATCH 缺口未被其发现)

## 环境瞬态说明(非 error)

测试首轮出现 4 次 ERR_INVALID_JSON/JSON position 错误,同 payload 手工复现全部正常,时间窗与快照复制 job 重合(→O-5),不计 error。
