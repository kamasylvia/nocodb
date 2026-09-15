# r6-f05-rev-a（第 3 路：后端代码复审，F05 第 6 轮收敛终审）

## PASS

无 error。无风格类意见。

## 四轴核验（全过，附证据）

### 1. CRUD 四轴对称（secret 加密态）
- insert：`BaseVariable.prepareForDb`（src/models/BaseVariable.ts:63）按 type=secret 加密 value/default_value；service 层显式 payload（base-variables.service.ts:67-73）拒绝 body 注入 default_value/order/inheritance/override 列。
- update：src/models/BaseVariable.ts:251-322 —— type 翻转双向对称：SECRET→TEXT 时从 `current`（get 返回已解密明文）回填 value/default_value 落明文（:284-291）；TEXT→SECRET 时按新态加密（:293-302）。cache 经 `NocoCache.update` 浅合并（CacheMgr.ts:561-570 `{...o,...value}`）镜像 DB 行态（密文/明文随 type），get 读取时再按 type 解密，无双解密路径。
- get：src/models/BaseVariable.ts:92-130 —— 先缓存后解密拷贝；list：:166-170 —— 逐行 `{...item}` 拷贝解密，不 mutate 缓存引用。

### 2. 守卫语义
- service `ensureEncryptionAvailable`（base-variables.service.ts:177-188）三个触发点：create secret 型（:62，`type||TEXT===SECRET`，无论 value 有无）、update 写 secret 物料（:141-146，`finalType===SECRET && (value!==undefined || typeFlippedToSecret)`）、翻入 secret 型。模型层 `encryptValue` 缺 key 静默明文的坑被 service 层前置拦死。
- key 不可变：service :98-100（拒绝改 key）+ model extractProps 不含 key（BaseVariable.ts:257-266）双保险。
- 竞态：DB 侧 `nc_base_variables_ws_base_key_unique`（migration nc_202604290000_base_variables_and_sandbox_changelog.ts:22-26）+ `isUniqueViolation`→400（service :78-81）；metaInsert2 注入 fk_workspace_id/base_id（meta.service.ts:330-344），唯一约束三元组有效。

### 3. 缓存拷贝解密
- get()：raw 行 `await NocoCache.set` 后 `prepareForRead({...data})`（:112-127），缓存恒持密文；list()：`setList` 存 raw 后逐行拷贝解密（:157-170）。R2 修复到位，无双解密空串路径。
- delete：deepDel CHILD_TO_PARENT（CacheMgr.ts:458-482，按 parentKeys 从父 list 摘除）；deleteByBaseId：PARENT_TO_CHILD 删 list+children（:483-495）。

### 4. 双挂钩（Base 两条删除路径）
- `Base.softDelete`（Base.ts:401，metaUpdate {deleted:true}）与 `Base.delete`（Base.ts:606，metaDelete）为两条独立路径，各自挂 `BaseVariable.deleteByBaseId`（:451-454 / :699-702），无嵌套重复调用；即使先后执行也幂等（0 行 + 重复 deepDel 无害）。softDelete 在事务内（bases.service.ts:218 传 transaction）。CE 无 base 恢复/取消归档端点（grep 仅有该一处 softDelete 调用），变量随软删清空无回退矛盾。

## 实跑
- `npx tsc --noEmit`（packages/nocodb）：exit 0，0 错。
- `pnpm test`（jest）：2 suites / **26 passed, 26 total**（uniqueConstraintHelpers.Fork + baseVariableValidators.Fork）。

## ACL 可达链核验
- `@Acl('baseVariable*')`（默认 scope=base）→ AclMiddleware.aclFn：`userScopeRole=base_roles`；EDITOR/VIEWER/COMMENTER 为 include 制且未含 baseVariable* → 403；CREATOR/OWNER 为 exclude 制（exclude 仅 baseDelete/migrateBase 等）→ 放行；SUPER_ADMIN `'*'` 放行。语义 = creator+，与 acl.ts:267 注释一致。
- baseId 归属：ExtractIdsMiddleware 对 params.baseId 先 `Base.get`（deleted:false 过滤，Base.ts:272-300），非成员无 base_roles → 403；metaGet2/metaList2 经 contextCondition 再按 fk_workspace_id+base_id 过滤（meta.service.ts:265-284），跨 base 读取双重隔离。
- 路由无遮蔽：`/bases/:baseId/variables` v1/v2 各 5 个 decorator 即本 controller 全部；`:sourceId` 型路由均为 2 段（`/:sourceId/tables`），与 1 段 literal 不冲突。

## 攻击性找茬：无（以下候选均被证据排除）
1. base 删除后 per-variable 缓存 key 残留（deleteByBaseId 仅 deepDel list key，list key 缺失时 children 不清）→ **API 不可达**：删 base 后 ExtractIdsMiddleware `Base.get` 过滤 deleted 行 → 404 先于 variables 路由；hard delete 行亦无。且与上游 Extension.deleteByBaseId 同构。
2. 无 Redis 时 mock 缓存 list 持旧对象引用（update 后 list 短暂 stale）→ 上游 CacheMgr 全模型通病，非本 fork 引入。
3. decryptValue 换 key 后静默空串 → 上游 CE 模型既有代码，fork 未触碰，且 write 侧有守卫。
4. GET 单变量返回明文 secret → 设计决策（list 掩码 + creator 门禁），非缺陷。

残留检查：新文件无 console/debugger；`// [CE-EE]` 标记齐全（7 个 backend 触点全带）。
