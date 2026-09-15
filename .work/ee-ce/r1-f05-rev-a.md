# r1-f05-rev-a（第 3 路：后端代码复审）

## issues

### I1 [medium][validation/security-adjacent] `type` 全链路无枚举校验，非法值落库致 secret 明文暴露
- `packages/nocodb/src/services/base-variables.service.ts:44` — create 仅 `type: body.type || BaseVariableValueType.TEXT`，任意真值字符串（`"weird"` / 大小写笔误 `"Secret"`）直接透传
- `packages/nocodb/src/services/base-variables.service.ts:79` — update 将原始 body 直传 `BaseVariable.update`，同样不校验 type
- `packages/nocodb/src/models/BaseVariable.ts:190-201` — `insert` 的 extractProps 白名单含 `'type'`，无值域校验
- `packages/nocodb/src/meta/migrations/v0/nc_202604290000_base_variables_and_sandbox_changelog.ts:13` — DB 列 `string('type', 20).defaultTo('text')`，无 enum/check 约束
- 后果链：`type="weird"` → `isSecretType()` false（BaseVariable.ts:43-45）→ `prepareForDb` 跳过加密（:67-76）明文落库 → service `maskSecret` 的 `variable.isSecret` false（base-variables.service.ts:110）→ **用户本意 secret 的 value 在 list 响应中明文返回**。update 更糟：secret→"weird" 翻转触发 `typeFlipped` 分支（BaseVariable.ts:272-284），把已解密 value 以明文写回
- 建议：service create/update 入口校验 `Object.values(BaseVariableValueType).includes(body.type)`，非法值 400

### I2 [low-medium][consistency] AuthGuard('jwt') 偏离全库 meta controller 惯例，API token / OAuth token 被 401 拒于 ACL 之前
- `packages/nocodb/src/controllers/base-variables.controller.ts:22` — `@UseGuards(AuthGuard('jwt'))`
- 全库 92 个 controller 中 44 个用 `@UseGuards(MetaApiLimiterGuard, GlobalGuard)`（如 `src/controllers/api-tokens.controller.ts:20`、`hooks/bases/tables` 等）；仅 org-tokens / workspace-users 两处（均为鉴权管理面）用 `AuthGuard('jwt')`
- 后果：'jwt' 策略 extractor 仅认 `xc-auth` 头 + `nc_token` cookie（`src/providers/jwt-strategy.provider.ts:17-19`）。`xc-token` API token / OAuth Bearer 在 guard 层即 401；guards 先于 interceptors 执行，`AclMiddleware` 内的 GlobalGuard 兜底（`src/middlewares/extract-ids/extract-ids.middleware.ts:1128-1135`）永远不可达
- 影响：API token 自动化可读 hooks 等其它 meta 资源却无法读写 variables（401），与其余 meta API 行为不一致
- 建议：改 `@UseGuards(MetaApiLimiterGuard, GlobalGuard)`

### I3 [low][consistency] update 空 body / 仅 key 字段行为不一致
- `packages/nocodb/src/services/base-variables.service.ts:66-73` — 判空条件 `body.key !== undefined && !body.key && !('value' in body) && !('description' in body)`：
  - `{}`（真空 body）→ 条件不触发（`body.key === undefined`）→ `BaseVariable.update` 收到空 patch，metaUpdate 空更新，静默 200
  - `{ key: <与现值相同> }` → 通过 immutable 检查（:62），model extractProps 滤掉 key（BaseVariable.ts:250-259）→ 空 patch 静默 200
  - 仅 `{ key: "" }` 或 `{ key: null }` → 400 'Nothing to update'
- 三种"无有效变更"输入两种返回 200、一种 400。建议统一：extractProps 后无字段即 400

### I4 [info][robustness] create 唯一键检查为 check-then-insert，并发下 500 而非 400
- `packages/nocodb/src/services/base-variables.service.ts:37`（先 list+some 查重）与 `:39`（后 insert）之间无事务/锁；并发同 key 命中 DB 唯一约束 `nc_base_variables_ws_base_key_unique`（migration :23-26）→ 原始 DB 错误 500
- 数据完整性由约束兜底，仅错误形态问题。可在 insert 处捕获唯一冲突转 400

## 判定为非问题（任务指定核查项）
- **secret 无值不掩码**：无值即无可泄内容，`maskSecret` 的 `variable.value` 真值判断（service:110）无泄漏面
- **伪造 body.base_id 注入他 base**：不可能。service create 显式构造字面量（service:39-46），`body.base_id` 不进入 insert 入参；model extractProps 仅从该字面量取 `base_id`
- **delete 幂等性**：重复 delete 返回 404（`getVariableWithBaseCheck`，service:96-98），与库内 REST 惯例一致，非缺陷
- **service key 锁定重复防御**：model update 白名单已滤 `key`（BaseVariable.ts:250-259），service 层检查（service:62-64）属纵深防御且提供更明确错误文案，保留合理
- **context.base_id ≡ 路由 baseId**：恒等。`legacyExtractIds` 以 `Base.get(params.baseId)` 取 base 并置 `req.context.base_id = base.id`（extract-ids.middleware.ts:526, 144-152, 658），base 不存在即 404，故 `validateUniqueKey`（service:103）用 context.base_id 与 insert 用路由 baseId 同域
- **路由冲突**：全 controller 目录 grep `variables` 仅本 controller 命中；`src/Noco.ts` 无 legacy variables 路由；v1/v2 双路径写法与库内其它 meta controller 一致
- **@Acl 权限面**：`baseVariable*` 未注册进后端 `src/utils/acl.ts` include 列表 → editor/viewer/commenter（include 模式）被拒，creator/owner（exclude 模式）放行，与 controller 注释 "creator+ only" 及前端 `packages/nc-gui/lib/acl.ts`（creator include 新增 4 项）一致；未注册 `permissionScopes` 不触发启动校验错误（该校验仅覆盖 include 列表已有项，acl.ts:700-728）
- **Nest DI**：`noco.module.ts` controllers 数组与 providers 数组均已注册（diff @@ -228 +231、@@ -317 +320），service 无构造依赖，注入合法
- **编译**：`npx tsc --noEmit -p packages/nocodb/tsconfig.json` 实跑 exit 0，0 error
