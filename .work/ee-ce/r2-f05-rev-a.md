# r2-f05-rev-a — F05 第 2 轮后端代码复审（第 3 路）

issues:

1. `packages/nocodb/src/services/base-variables.service.ts:98`（配合 152-164）: 问题：`update` 里 `ensureEncryptionAvailable(type ?? existing.type, value)` 在**只改 description** 的 SECRET 变量上也会执行 `type === SECRET && !getCredentialEncryptSecret()` 判断——NC_CONNECTION_ENCRYPT_KEY 运行中被移除后，PATCH `{description:"x"}` 误报 400 "NC_CONNECTION_ENCRYPT_KEY is not configured"（description 更新与加密无关）。且函数签名 `value` 参数从未被读取（死参数），证明实现与"仅在写入 secret 值时才要求 key"的意图不符。: 建议：拦截条件收窄为「实际要持久化 secret 值」：`(type === SECRET && value !== undefined && value !== '')` 或 `(type === SECRET && value === undefined && existing.type !== SECRET)`（即 type 新翻转为 SECRET），删除或使用 value 参数。

2. `packages/nocodb/src/services/base-variables.service.ts:88`（validateValue 127-138）: 问题：update 传 `{value: null}` 时 `validateValue` 把 null 归并成 undefined，与"字段未提供"不可区分——单独 `{value:null}` 触发 400 'Nothing to update'，与其它字段同 PATCH 时 value 被静默忽略。REST PATCH 语义 null = 清除，DB value 列 nullable、model updateObj 原生支持，行为应清空。API 直连可达（前端不发 null，但 API 消费者会）。: 建议：update 路径区分 `body.value === null`（写入空串或 NULL）与 `undefined`（跳过）；或至少在 null 时 400 明示"value must be a string"，与 validateValue 对非 string 的报错一致。

3. `packages/nocodb/src/services/base-variables.service.ts:143-149`（validateType）: 问题：type 传非 string（如 `123`、`{}`）时 `normalized = undefined` 静默放行，行以 DB default 'text' 落库——非法输入被静默降级而非 400。与同文件 validateKey（非 string → 400）、validateValue（非 string → 400）行为不一致，也偏离 R1 type 白名单意图（白名单只拦"string 且不在名单"，漏掉"非 string"）。: 建议：`typeof type !== 'string'` 时直接 `NcError.badRequest('Variable type must be one of: text, secret')`（type 缺省仍允许走 DB default）。

## 已验证无问题项（证据）

- `npx tsc --noEmit`（packages/nocodb）exit 0，0 error（实测）。
- Base.delete 集成：`BaseVariable.deleteByBaseId(context, baseId, ncMeta)`（Base.ts:694-696）在 `metaDelete(PROJECT)` 前、ncMeta 透传；与 `Extension.deleteByBaseId`（Extension.ts:251-271）完全同构——metaDelete 条件删 + `deepDel BASE_VARIABLE:${baseId}:list` PARENT_TO_CHILD；单变量缓存键经 insert 的 `appendToList` 保证在 list 子键集内，清理无泄漏路径。
- secret→text 回退：model `BaseVariable.update`（BaseVariable.ts:265-295）typeFlipped 分支从 `BaseVariable.get`（prepareForRead 已解密）取 current.value/default_value 回写，text→secret 反向重加密；缓存行（NocoCache.update merge）与 DB 加密态一致（缓存存密文、读时解密，两条路径均过 prepareForRead）。
- 掩码 vs 单条 get：list 掩码 value+default_value（R1 修复在位），单条 get/update/create 返回明文为有意设计（creator-gated；前端 openEditModal 对 secret 单条 GET 回填依赖此语义，Variables/index.vue:44-56）——两端语义自洽。
- controller：`@UseGuards(MetaApiLimiterGuard, GlobalGuard)` 与 api-tokens/base-users.controller 同款；4 个 `@Acl` 名与 `permissionScopes.base`（utils/acl.ts:268-271）逐字一致；无路由冲突（controllers 内 'variables' 路由唯一）；v1/v2 双路径，前端 UI 全走 `/api/v2/meta/bases/:baseId/variables` 与注册匹配。
- 权限语义：CREATOR/OWNER exclude 模式（extract-ids.middleware.ts:1253-1268）→ baseVariable* 默认放行，EDITOR/VIEWER include 模式拒绝——creator-only 后端生效；前端 lib/acl.ts CREATOR.include 同 4 op 一致。前端 OWNER-only 用户菜单不可见系上游 extensionCreate 同款既有模式，非 F05 引入。
- create 竞态：migration `nc_base_variables_ws_base_unique(fk_workspace_id, base_id, key)`（nc_202604290000_base_variables_and_sandbox_changelog.ts:22-27）存在 → `isUniqueViolation` → 400 兜底可达。
- IDOR：extract-ids 对 :baseId 做 Base.get 校验并设 context.base_id；getVariableWithBaseCheck 比对 `variable.base_id !== baseId` → 404；update payload 不含 base_id/key，无法跨 base 搬迁或改键。
- payload 白名单：显式构造 {base_id,key,value,description,type}，extractProps 二次过滤，注入 order/inheritance/is_overridden/default_value 均被剔除；type 缺省经 extractProps 跳过 undefined → DB default 'text'，无 NULL type 落库路径。
