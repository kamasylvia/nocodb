# r3-f05-rev-a — F05 第 3 轮后端代码复审（rev 路 a）

实跑：`npx tsc --noEmit` = 0 error；`npx jest "baseVariableValidators|uniqueConstraintHelpers" --runInBand --forceExit` = 26/26 passed。

已核通过项（不重复展开）：
- R2 修复闭环：BaseVariable.get/list 拷贝解密 + `await NocoCache.set`（缓存存原始密文行，list 的 setList 分支存 DB 原始行，命中/未命中路径均不 mutate 缓存引用）。
- Base.softDelete 挂 deleteByBaseId：位置在 FileReference.bulkDelete 之后、metaUpdate(deleted) 之前，ncMeta（trx）正确透传；MCPToken/FileReference 顺序无依赖冲突。
- service 显式 payload：base_id 用 path 值；order/default_value/inheritance/is_overridden/is_inherited 不可注入；update 只透传 value/description/type；key 不可变。
- validators 抽离：`helpers/baseVariableValidators.ts` import 仅 `nocodb-sdk`（sdk-only 达成）；service safeValidate = ValidationError→400、其余 rethrow，语义无回归；null→'' 清值在 model 层（falsy 跳过长度检查/加密）落库 ''，读回 ''，listAsMap 跳过空值，闭环正确。
- type 白名单与 model 协同：service 合法集 {text,secret}（sdk enum），model typeFlipped 逻辑只判 SECRET，一致。
- KEY_REGEX 双层：service key≤255 + model KEY_REGEX（UPPER_SNAKE）；DB `nc_base_variables.key` = varchar(255)（migration nc_202604290000），pg varchar 超长报错不静默截断；unique(fk_workspace_id,base_id,key) 存在，race 由 isUniqueViolation→400 兜底。
- Base.delete（硬删）保留 deleteByBaseId 无害：metaDelete knex query.del() 对 0 行不抛错；NocoCache.deepDel PARENT_TO_CHILD 对不存在 key del 安全（redis/mock 均 0 值删除）；Base.delete 当前无调用点（软删驱动），双重清理幂等。
- ACL：baseVariableList/Create/Update/Delete 在 permissionScopes.base；EDITOR 为 include 模式未含、CREATOR/OWNER 为 exclude 模式默认全给 → creator+ only 达成；@Acl 名与 scope 一致；noco.module controller/service 注册齐全；路由 v1/v2 双注册无冲突。
- 缓存侧链：insert 后 appendToList、delete 后 deepDel CHILD_TO_PARENT、update 后 NocoCache.update 与 DB 行状态一致。

## issues

1. `packages/nocodb/src/services/base-variables.service.ts:141-159`（ensureEncryptionAvailable）+ 协同缺口在 `packages/nocodb/src/models/BaseVariable.ts:279-302`（update typeFlipped 分支）：**type 翻转到 secret 不带 value 时加密守卫被绕过，存量明文静默落库且行标记为 secret**。
   - 链路（实例无 `NC_CONNECTION_ENCRYPT_KEY`，creator 权限）：
     ① `POST /api/v2/meta/bases/:baseId/variables` body `{key:'TOKEN', value:'sk-live-xxx', type:'text'}` → 200（text 不要求 key，合理）；
     ② `PATCH /api/v2/meta/bases/:baseId/variables/:id` body `{type:'secret'}` → service 守卫 `isSecretWrite = (type===SECRET && value!==undefined) || (value!==undefined && type===undefined)`，value=undefined 两分支均 false → 放行；
     ③ model update：previousType='text' ≠ nextType='secret' → typeFlipped 分支把 `current.value`（明文）搬入 updateObj.value → willBeSecret → `encryptValue` 无 secret 原样返回 → `metaUpdate` 写入**明文 + type='secret'** → 200；
     ④ 结果：service.list 走 maskSecretVariable 掩码、UI 显示 secret 徽标，`decryptValue(明文)` 原样返回无报错 → 管理员无从察觉，"encrypted at rest" 承诺被静默打破（AGENTS.md 明确记录该守卫的存在目的即防此洞，R2 收窄重开了此缝）。
   - 副症状（同根因）：secret 行 `{value: null}` 清值操作（value='' 无需加密）在无 key 实例也 400——清值不应要求加密 key。
   - 建议：守卫条件补第三分支 `(nextType===SECRET && existing.value)`（翻转且行上有值时也要求 key）；value===''（清值）豁免 key 要求。或下沉 model 层：typeFlipped && willBeSecret && 行上有值 && 无 key 时抛错。

2. `packages/nocodb/src/services/base-variables.service.ts:56-57,112-118`：**description 完全未校验类型/长度，与"显式 payload + validators 收紧"目标不一致**。
   - 链路（creator 权限）：`PATCH /api/v2/meta/bases/:baseId/variables/:id` body `{description: {x:1}}`（或数组）→ update 仅判 `body.description !== undefined` 即透传 → model extractProps 含 'description' → `metaUpdate` knex 对 text 列绑定 object：pg driver JSON.stringify 存 `'{"x":1}'` 脏数据；mysql2 对 object bind 抛驱动错误 → **500**（验收点"无服务端 500 残留"被 creator 可主动触发，pg 侧为静默脏数据）。create 同样透传无校验。
   - 建议：validators 补 `validateVariableDescription`（非字符串 reject、超长 reject，null→undefined），create/update 同样走 safeValidate。
