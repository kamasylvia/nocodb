# r5-f05-rev-a — 后端代码复审（第 5 轮收敛终审）

## PASS

### 核验证据

**1. service 全文终审（R4 后）**
- 校验对称性（type/value/description/key 四轴）：
  - create：type 白名单校验（undefined/null → TEXT 默认）、value string+64KB（对象/数组显式拒）、key 必填+≤255（模型层再拒非 UPPER_SNAKE_CASE，双 400 通道）、description string-or-null 显式检查（base-variables.service.ts:50-58）
  - update：key 不可变（98-100）；type 仅 body 提供时校验（102-105）；value PATCH null→'' 清空语义（106-112）；description 与 create 同款检查（125-131）；空 patch「Nothing to update」守卫（114-120）。四轴对称成立。
- payload 显式构造：create 仅取 key/value/description/type 四字段入 insert（67-73），order/default_value/inheritance/is_overridden/is_inherited/id/base_id 全部不可注入；update 仅放行 value/description/type（148-154）。extractProps 只 drop undefined 不 drop null（nocodb-sdk commonUtils.ts:19），null 清空可写通。
- 守卫语义（ensureEncryptionAvailable）：create 按解析后 type 判（62-64，R3 修复：无 value 的 secret create 也拦）；update 按 finalType+实际写 secret 物料判（136-146）。模型 encryptValue 缺 key 静默明文的缺口已封死。
- null 语义：update `{type:null}` 静默忽略（validateVariableType(null)→undefined，不入 patch），create `{type:null}`→TEXT；语义自洽（create 无存量可保）。

**2. model 交互**
- insert：metaInsert2 自动注入 fk_workspace_id/base_id（meta.service.ts:353/358），unique 约束 (fk_workspace_id,base_id,key) 真实存在（nc_202604290000 migration:23-26）→ 并发 race 的 isUniqueViolation→400 兜底有效。
- update：type flip 双向补写（SECRET→PLAIN 取解密值回写、PLAIN→SECRET 取明文加密回写，BaseVariable.ts:284-302）；NocoCache.update 单键 merge，CacheMgr list 为 key-list 设计（getList 按 child key mget 同一存储对象）→ list 读自动新鲜，无 stale。
- get/list 缓存拷贝解密：get 先 set 原始密文行、再 `{...data}` 拷贝解密（BaseVariable.ts:116-127）；list 同款拷贝（170）。重复解密链路已断，缓存命中幂等。
- 双挂钩幂等：Base.softDelete（:453）与 Base.delete（:700）均调 deleteByBaseId；二次调用 DB metaDelete 条件删空集 no-op，CacheMgr.deepDel PARENT_TO_CHILD 对缺失键 → del(listOfChildren=undefined) 被 CacheMgr.del `else if (key)` 守卫吞掉（CacheMgr.ts:29-38），无异常。softDelete 在事务内（bases.service.ts:218 传 transaction），cache 删在 commit 前——rollback 后 cache miss 重查 DB，方向安全。CE 无 base 恢复路径，无数据损失面。
- listAsMap 唯一外部消费点 webhook-invoker.ts:378（CE 存量，非本 diff）。

**3. 实跑**
- `npx tsc --noEmit`：exit 0。
- `pnpm test`：2 suites（uniqueConstraintHelpers.Fork + baseVariableValidators.Fork），**26/26 passed**。

**4. 攻击性找茬（前 4 轮 5 路全漏项）：无**

逐项排查并排除的候选（均无可达证据链）：
- fk_workspace_id 未由 service 传入 → metaInsert2 从 context 注入，不缺列；
- 跨 base 越权 → metaGet2/metaUpdate/metaDelete 均 contextCondition 过滤 + service `variable.base_id !== baseId` 双重拦；
- 编辑/查看者越权 → baseVariable* 仅 creator exclude-list 命中（acl.ts:637-642），editor/viewer include-list 未含 → 403；
- list 泄 secret → maskSecretVariable 剥 value/default_value，单 get 为 creator-gated 设计内；
- 密文 key 丢失时解密失败 → decryptValue catch 返回原文（存量行为，非 fork 引入）；
- 路由冲突 → Nest 精确模板匹配，无既有 `bases/:baseId/variables` 占用；
- NcError 双导入源（catchError/ncError）→ catchError re-export 同一类（catchError.ts:24）。

结论：第 5 轮收敛终审 0 error。
