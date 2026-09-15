# r3-f02-lane1 — F02 Edit field permissions R3 复审（收敛第 2 轮）

审查对象：4b26d7a23f（实现）+ e85a421d92（R1）+ 3b9dcbdbc6（R2，本轮重点）。
方法：独立集成测试（dev :8080 / nocodb-dev，测试邮箱前缀 f02r3l1-*）+ 代码复审（三 commit diff + 累计 diff）。测试资源已软删，`nc_permissions` 零残留。

## 结论

**PASS**（0 error）

Minor 观察项 2 条（均有实测证据，不构成权限提升/数据破坏，供 orchestrator 裁决）：

1. `packages/nocodb/src/models/Permission.ts:312-319`（update 的 validateGrantShape 调用）:PATCH `{granted_type:"role"}` 于既有 user grant（granted_role=null）时落 200，产生 granted_role=null 的 role grant——insert 有 "granted_role is required for role grants" 守卫（Permission.ts:202-209），update 无对称守卫（validateGrantShape 因 granted_role falsy 跳过角色校验）。建议：update 内 targetType===ROLE 且 resolved granted_role 为空时补 400。
2. `packages/nocodb/src/models/Permission.ts:368-394`:PATCH `{granted_type:"nobody","subjects":[...]}` 同发时，nobody 分支（368-377）先删 subjects，随后 data.subjects 分支（379-394）再删+插 → nobody grant 携带 subjects 行（DB 实证 1 行残留），破坏 R2 commit 声明的 "nobody grants carry no subjects" 不变量；后续转回 user 时 targetType 守卫因 existing.subjects 非空放行，旧 subject 复活。需 owner 显式自相矛盾输入（UI 不会发），nobody 期间 evaluate 仍 deny-all。建议：nobody 分支移至 subjects 分支之后，或 body 含 nobody 时拒 subjects。

两条均 fail-closed / 无提权路径，故不计 error。

## 逐项结果

### 1. R2 修复验证

| 项 | 结果 | 证据 |
|---|---|---|
| ① 探针零残留（源码） | ✓ | 全仓 grep `F02-Q/R/P/Z`（*.ts/*.vue/*.js，排除 node_modules/.git/.work/dist）0 命中（exit=1） |
| ① 探针零残留（日志） | ✓ | `.work/ee-ce/logs/backend.log` 1396 行 grep 0 命中；本轮 ~40 次 API 调用（含全部写请求）后日志无新增 F02 输出 |
| ② PATCH granted_role 枚举+minimumRole | ✓ | bogus→400 `Invalid granted_role bogusr`；viewer→400 `granted_role viewer is below the minimum role for RECORD_FIELD_EDIT`；editor→200；creator→200 |
| ③ user grant 无 subjects | ✓ | create 无 subjects→400 `subjects are required for user grants`；update role→user 无 subjects→400；带 subjects→200 |
| ④ nobody 转换删 subjects | ✓ | PATCH nobody 200 后 `nc_permission_subjects` 该 grant 行数 1→0；转回 user 仅新 subject（us7n3nac3ofnzy5d），旧 subject 无复活 |

### 2. 全矩阵（3 grants × editor/creator/owner × PATCH/insert/bulk/v1）

基线：field grant = RECORD_FIELD_EDIT on Title(c7bm5q6i6sbzzjb)，table TestT。

- fail-open：无 grant 时 editor/creator PATCH/insert 全 200；删 grant 后行为立即恢复 ✓
- user grant（subjects=creator）：
  - PATCH：editor 403 / creator 200 / owner 200；editor PATCH 未设限字段 Amount 200（字段粒度正确）✓
  - v2 insert 平铺：editor 403 / creator 200 ✓
  - bulk（v1 `/api/v1/db/data/bulk/noco/:baseId/:tableId`）：editor 带 Title 403 / editor 无 Title 仅 Amount 200 / creator 200 / owner 200 ✓
  - v1 insert（`/api/v1/db/data/noco/:baseId/:tableId`）：editor 403 / creator 200 / owner 200 ✓
- role/editor：editor 200 / creator 200 / v2 insert 200 ✓；role/creator：editor 403 / creator 200 ✓
- nobody：editor 403 / creator 403 / owner 200（直通）✓
- 缓存即时性：PATCH nobody→role/editor 后紧接一条 editor PATCH 立即 200，无延迟窗口 ✓
- 备注：v2 侧无 `/records/bulk` 路由（404，上游结构如此）；bulk 实际路由为 v1 bulk-data-alias（`bulk-data-alias.controller.ts:27`），已按正确路径测过

### 3. ACL 面

- permissionList：editor 200（grants 可读，subjects 随行返回）/ owner 200 / 匿名 401 / 坏 token 401 ✓
- permissionCreate/Update/Delete：editor 403 × 3 ✓
- 匿名 v2 data read：401 ✓

### 4. 回归

- F05：variables list 200；create 200（key 守卫正常：非 UPPER_SNAKE_CASE 400）✓
- F07：snapshot create 200（返回 snapshot_base_id）/ list 200 ✓
- F08：private base（is_private=true）create 200 ✓
- F10：dashboard create 200 / list 200 ✓
- jest：`npx jest` 2 suites / **26 passed** ✓
- tsc：`npx tsc --noEmit` **exit 0** ✓

### 5. 代码复审（重点项）

- **validateGrantShape 的 requireSubjectsForUser 语义**（Permission.ts:243-298）:create 传 `{requireSubjectsForUser:true}` → user grant 无 subjects 400（实测）；update 不传选项 → subjects 可留旧行，语义由 update 内独立 targetType 守卫（Permission.ts:343-352，`data.subjects ?? existing.subjects`）补齐，实测 role→user 无 subjects 400。两处一致，无双检冲突 ✓
- **update targetType 推导**（Permission.ts:343-344）:`updateObj.granted_type ?? existing.granted_type`，subjects 解析 `data.subjects ?? existing.subjects`——PATCH 部分 shape 时与 existing 合并正确；无效 granted_type 'bogus' 由显式枚举检查（328-339）拦截 ✓
- **permissionList 放宽信息暴露面**:editor 经 permissionList 可见 grants 含 subjects user id；但 `baseUserList` 位于 VIEWER 角色块（`acl.ts:524`），editor 实测 `GET /api/v2/meta/bases/:id/users` 200，本即可见全部协作者（含 email，信息量大于裸 user id）→ **无新增暴露面** ✓
- datas.service isPublicForm 语义：view-submit（`datas.service.ts:1214-1222`）不再置 isPublicForm；唯一置位点 `public-datas.service.ts:827`（匿名 public form），唯一消费点 `BaseModelSqlv2.ts:3065`（isFormContext）→ enforce_for_form opt-out 仅匿名 form 路径生效，方向 fail-closed ✓
- usePermissions.loadPermissions(force)（`usePermissions.ts:48-64`）:force 跳过 per-base guard；`!baseId.value` 独立拦截保留；catch 重置 loadedFor 供重试；base 切换 watch 清空 stale grants ✓
- Permissions.vue `getPermissionLabel` 引入实际使用（组件 :232）非残留 ✓

### 6. 信息性观察（非 issue）

- authenticated view-submit 路由（datas.controller POST `/data/:viewId/`）在 dev 实例实测 404，路由挂载形态未能定位（属上游路由结构，非 F02 diff 范围）；该 handler 体内 R1/R2 改动已在代码层审读正确。其 field-check hook 与 v1 insert 共用 `baseModel.insert` 路径，后者已全矩阵实测通过。

## 环境细节

- 认证：signup/signin + owner 号 psql 提权 `nc_users_v2.roles='super'`（表名为 `nc_users_v2`/`nc_permission_subjects`，非任务书示例的 `nc_users`）
- 测试资源：2 base（f02r3l1-base / f02r3l1-private）+ form view + grants 已软删；`nc_permissions` 零残留实证（count=0）
