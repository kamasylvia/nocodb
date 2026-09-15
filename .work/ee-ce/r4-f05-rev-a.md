# r4-f05-rev-a — 第 4 路后端代码复审（收敛终审）

## issues

1. `packages/nocodb/src/services/base-variables.service.ts:60`（create 路径）：`description` 未做类型校验，与 update 路径 R3 修复不对称。
   - 可达链：`POST /api/v2/meta/bases/:baseId/variables`（creator token，body `{key:"D1", type:"text", value:"v", description:{"x":1}}`）→ `BaseVariablesController.create`（controllers/base-variables.controller.ts:52-61，`@Body()` 原样透传）→ `BaseVariablesService.create`（base-variables.service.ts:37-72）显式 payload 中 `description: body.description`（line 60）无任何校验 → `BaseVariable.insert`（models/BaseVariable.ts:197-208）`extractProps` 白名单含 `'description'`，model 层亦无校验 → `metaInsert2` → knex/pg 将 object 序列化为 dirty JSON 字符串落库；mysql 实例上报错 → 500。
   - 依据：service.update 同场景已被 R3 显式拦截（base-variables.service.ts:114-120 `Variable description must be a string`），其注释原文自证威胁（"objects used to be stored as dirty JSON strings by the pg driver and errored out on mysql"）——同一威胁在 create 完整可达。违反验收「无服务端 500 残留」。
   - 建议：create 中对 `body.description` 复用 update 的同款守卫（非 undefined/null 且 typeof !== 'string' → 400）。

## PASS 项（核验记录）

- **payload/白名单/键锁定**：create 显式构建仅 5 字段（base_id/key/value/description/type），update 仅 value/description/type；`base_id/order/inheritance/default_value/is_overridden/is_inherited/id` 注入不可达（extractProps 二次白名单兜底）；key immutable 拦截（update line 87-89）。
- **type 白名单**：`validateVariableType` 仅放行 `Object.values(BaseVariableValueType)`，非字符串/未知值 400；create 省略 type 回落 TEXT。
- **守卫语义**：create 在 type（含回落值）为 secret 时即拦 `ensureEncryptionAvailable`（不论 value 有无）；update 仅在「secret 行写 value」或「翻转入 secret」时拦（`writesSecretMaterial`），只改 description 不触发——符合 R3 语义。`getCredentialEncryptSecret()` 直读 `NC_CONNECTION_ENCRYPT_KEY`（utils/encryptDecrypt.ts:3）。
- **null 清值**：update `value===null → ''`，model 对空串不加密、明文落库，prepareForRead 空串短路——读写对称；`description===null` 走 patch 传 null 清列。
- **validators 包装**：create（type/value/key）与 update（type/value）均经 `safeValidate` → `BaseVariableValidationError` → 400；update「Nothing to update」与 description 字符串守卫在位。
- **ACL/权限**：`baseVariable*` 仅存在于 `permissionScopes.base`；viewer/commenter/editor 为 include 型且不含 → deny；creator/owner 为 exclude 型 → allow（acl.ts include 继承 forward / exclude 反向折叠逻辑，acl.ts:708-799）。get 单变量返回解密值限于 creator+，与设计注释及 EE 行为一致。list 对 secret 行 strip `value`+`default_value`。
- **context/base 归属**：extract-ids.middleware 对 `:baseId` 路由 `Base.get` 404 前置 + `req.ncBaseId` → `context.base_id`；`validateUniqueKey(context, key)` 用 `context.base_id` 与参数 `baseId` 同源；`getVariableWithBaseCheck` 比对 `variable.base_id !== baseId` 防跨 base id 枚举。
- **race 兜底**：migration `nc_202604290000`（:22-31）存在 unique(`fk_workspace_id`,`base_id`,`key`)；`metaInsert2`（meta/meta.service.ts:301-356）自动注入 `fk_workspace_id`/`base_id` → 约束真实生效；`isUniqueViolation`（pg 23505/mysql ER_DUP_ENTRY/1062/mssql/sqlite 全形）→ 400。
- **BaseVariable.get/list 拷贝解密 + await set**：get cache-miss 时 `await NocoCache.set`（BaseVariable.ts:116）存原始密文行，读取路径 `prepareForRead({ ...data })` 拷贝解密（:126）；list `setList` 存原始行，map 拷贝解密（:170）；update 后 `NocoCache.update` 为 merge 语义（CacheMgr.ts:561-570 `{...o,...value}`），密文/明文与 DB 状态一致，无双解密窗口。
- **Base 双挂钩幂等**：`Base.softDelete`（Base.ts:450-453）与 `Base.delete`（Base.ts:698-700）均 `await BaseVariable.deleteByBaseId`；二次执行 metaDelete no-op + deepDel no-op，幂等。（注：`deleteByBaseId` 不清单变量 cache 键 `${scope}:${variableId}`，但变量 id 不复用且后续访问被 middleware `Base.get` 404 前置拦截，无可达错误读——仅缓存残留，不计 error。）
- **validators 依赖面**：`baseVariableValidators.ts` 仅 import `nocodb-sdk`，sdk-only ✓。
- **实跑**：`npx tsc --noEmit -p tsconfig.json` → 0 错误；`npx jest` → 2 suites / **26 passed, 26 total**（validators 18 + uniqueConstraintHelpers 8）。
- **攻击性找茬**：除上述 issue 外，遍历 create/update/get/list/delete + model insert/update/delete/cache 全路径，未发现其它有可达证据的问题（type 翻转往返加解密、空串 secret、`__proto__`/内部列注入、v1/v2 双路由、并发 unique race 均核验为安全/一致）。
