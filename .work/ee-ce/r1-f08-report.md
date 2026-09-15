# F08「Base Type - Private」R1 实现报告

- 日期：2026-09-12
- 执行：会审子代理（实现轮）
- 目标：base 可标记私有（`is_private`），仅显式协作者可见，对 workspace 继承成员完全隐藏（404 掩蔽）

## 改动清单

### a. 新迁移
- **新增** `packages/nocodb/src/meta/migrations/v2/nc_20260913_add_is_private_to_bases.ts`
  - `MetaTable.PROJECT`（nc_bases_v2）加 `is_private boolean DEFAULT false`；down 删列
- **注册** `packages/nocodb/src/meta/migrations/XcMigrationSourcev2.ts`
  - import（`// [CE-EE] F08`）+ `getMigrations()` 数组尾部 + `getMigration()` switch case
  - 追加在 `nc_20260913_dashboard_title_unique`（F10）之后，顺序安全

### b. `packages/nocodb/src/models/Base.ts`
- Base class 加 `public is_private?: boolean`（带 `// [CE-EE] F08` 注释）
- `createProject` extractProps 白名单加 `'is_private'`
- `update` extractProps 白名单加 `'is_private'`

### c. `packages/nocodb/src/models/BaseUser.ts`（`getProjectsList` ~L565-615）
- workspace 继承分支（Priority 2：无显式 base role / INHERIT → 看 workspace role）追加：

  ```sql
  AND (nc_bases_v2.is_private IS NOT TRUE OR EXISTS (
    SELECT 1 FROM nc_base_users_v2 bu2
    WHERE bu2.base_id = nc_bases_v2.id
      AND bu2.fk_user_id = :userId
      AND bu2.roles NOT IN ('no-access','inherit')
  ))
  ```

  - knex raw 实现，表名/角色值全部走绑定参数（`MetaTable.PROJECT_USERS` / `ProjectRoles.NO_ACCESS` / `ProjectRoles.INHERIT`）
  - `IS NOT TRUE` 覆盖 NULL（迁移前存量行）；roles 为 NULL 的 bu2 行 `NOT IN` 判 NULL → 不算协作者
  - Priority 1（显式非 no-access/inherit 角色）分支不变 → 显式协作者照常列出

### d. `packages/nocodb/src/models/User.ts`（`getWithRoles` ~L668+）
- `args.baseId` 存在时先 `Base.get` 取 `is_private`
- 私有 base 且 `baseRoles` 为空（无行 / 行 roles 空 / INHERIT）→ `effectiveBaseRoles = extractRolesObj(ProjectRoles.NO_ACCESS)`，跳过 workspace 角色继承
- super admin 早返回（base_roles=OWNER）不受影响

### e. `packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts`（`aclFn`，L1245 `// todo : verify user have access to base or not` 处）
- 门逻辑：`req.ncBaseId && req.user && !req.user.isPublicBase` 时：
  - super admin（`roles`/`org_roles` 含 `OrgUserRoles.SUPER_ADMIN`）放行
  - `Base.get(req.context, req.ncBaseId)` → `is_private` 为真时：
    - `base_roles` 无显式协作角色（null 或仅 NO_ACCESS/INHERIT）→ `NcError.baseNotFound`（**404 掩蔽**，非 403，不泄露存在性）
- 依赖链：extractIds middleware 先置 `req.ncBaseId` → GlobalGuard/jwt validate 调 `getWithRoles`（吃到 d 的逻辑）→ AclMiddleware 拦截器跑本门（吃到 d 写入的 NO_ACCESS base_roles）→ 顺序成立

### f. 补充（任务书外，必要写通道）
- `packages/nocodb/src/services/bases.service.ts` `baseUpdate`：`extractPropsAndSanitize` 白名单加 `'is_private'`。**原因**：service 层白名单先于 `Base.update` 剥字段，不加则 PATCH 永远改不了 is_private（先例：同列表已有 `default_role`）。create 路径 `baseBody` 直通 `Base.createProject`（b 的白名单已放行），无需改

所有改动均带 `// [CE-EE] F08` 标记。

## 验证结果

| 项 | 结果 |
|---|---|
| `npx tsc --noEmit`（packages/nocodb） | **0 错误**（改动后复跑两次均 0） |
| `npx jest baseVariableValidators --runInBand --forceExit` | **12/12 pass**（1 suite passed） |
| owner 自锁风险核查 | base 创建即插 `nc_base_users_v2 roles='owner'` 行（bases.service.ts L398-406）→ owner 恒过三道门 |
| duplicate/快照传播核查 | `duplicate.service.ts` target base 走 `basesService.baseCreate({title,status,...})`，不透传 is_private → 复制件默认公开、复制者 owner，无锁死 |

DB 迁移未手动执行（红线：不碰生产库；迁移会在 dev server 下次启动时对 nocodb-dev 自动应用）。

## 已知限制 / 待后续轮确认

1. **无 UI**：本轮仅后端。is_private 读写通道：`POST /api/v2/meta/bases`（create body）与 `PATCH /api/v2/meta/bases/:baseId`（update body）。UI 开关属后续工作。
2. **共享链接（shared view/base）不受私有门拦截**：aclFn 门跳过 `req.user.isPublicBase` 伪用户 → 私有 base 的已建共享 UUID 仍可用（capability URL 语义，与 EE 预期一致与否待会审判定）。
3. **API token**：带 `fk_user_id` 的新 token 走 `getWithRoles` → 门生效；**旧格式 token**（无 fk_user_id）硬编码 `base_roles=EDITOR` → 可访问私有 base（CE 既有行为，非本轮引入）。
4. **swagger schema 未加 `is_private` 字段**：`validatePayload` 非严格模式不剥未知字段（create 通道实测依赖此），若后续开启严格校验需同步 `ProjectReqType`/`ProjectUpdateReq`。
5. **缓存**：`Base.get` 走 NocoCache PROJECT scope；迁移后旧缓存对象无 is_private 字段 → 视为 false，重启/缓存过期自愈。
6. **快照 restore 产物**（F07 交叉）：restore 建新 base 走 duplicate 链 → 产物不继承 is_private；快照副本（Snapshot base）对 workspace 成员可见性 = 公开，若要求快照继承私有待产品判定。
7. 本轮未对 nocodb-dev 做端到端 API 实测（任务书测试项仅 tsc + jest）；建议 R2 集成测试轮覆盖：create 私有 base → 非协作者 workspace 成员列表不可见 / 直连 404 / 协作者可见 / owner 可见。
