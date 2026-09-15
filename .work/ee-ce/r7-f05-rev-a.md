# r7-f05-rev-a — 第 3 路(后端代码复审)第 7 轮最终收敛确认

## PASS

无 error。攻击性找茬未发现具 API 可达链的 bug/安全问题。

## 验证记录(终审四轴)

### 1. 实跑结果
- `tsc --noEmit`:exit 0,0 error(packages/nocodb)
- `npx jest`:2 suites(baseVariableValidators.Fork + uniqueConstraintHelpers.Fork),**26/26 passed**

### 2. service/validators/model 四轴对称
- `create`(base-variables.service.ts:37):key/type/value 走纯 validator(description 独立 string|null 检查),显式构造 payload → base_id/order/inheritance/is_overridden/is_inherited/default_value/id 均不可注入;model 层 insert 二次拦 KEY_REGEX(UPPER_SNAKE_CASE)+ 64KB。
- `update`(base-variables.service.ts:85):key immutable(`null`/`''`/异值均 400);type/value 校验对称;PATCH `value:null → ''` 清空语义;`Nothing to update` 守卫;description string|null 检查与 create 对称。
- 前后端 ACL 对称:后端 `baseVariableList/Create/Update/Delete` ∈ permissionScopes.base(utils/acl.ts:268-271,creator=exclude 型全允许、EDITOR include 列表无 → creator+ only);前端 nc-gui/lib/acl.ts 仅加于 ProjectRoles.CREATOR include。对称成立。

### 3. 守卫语义(ensureEncryptionAvailable)
覆盖 secret 材料写入全部三条可达路径,与 model 加密路径(willBeSecret + updateObj.value/default_value,BaseVariable.ts:293-302)精确对齐:
- create type=secret(含 value 未给/value=''):service.ts:62 拒;
- update 对 secret 行写 value(含 null→''):service.ts:141-146 拒;
- update text→secret flip(value 不写时 model 会重加密存量值):typeFlippedToSecret 拒。
枚举仅 text/secret(sdk globals.ts:527),无第三态绕过。model 其余调用点仅 webhook-invoker.ts:378 `listAsMap`(只读),service 是唯一写入口,守卫不可绕。

### 4. 缓存拷贝解密(fork 修复验证)
- `get()`:先 `await NocoCache.set` 存密文原行,再 `prepareForRead({...data})` 拷贝解密 → 缓存永持密文,无双重解密;cache hit 路径同拷贝。
- `list()`:逐行 `{...item}` 拷贝解密,缓存引用不被原地改写。
- `update()`:CacheMgr.update 实测为 merge(`{...o, ...value}`,CacheMgr.ts:561-568),patch 加密字段并入缓存,不丢 key/base_id;缓存与 DB 同态(密文),读路径统一 prepareForRead。
- CacheMgr.get unwrap(res.value,CacheMgr.ts:get)实证 cache hit 返回原始 row,链路自洽。

### 5. 双挂钩幂等(Base.delete + Base.softDelete)
- 两处挂钩(Base.ts:451、:698)均调 `BaseVariable.deleteByBaseId`;`metaDelete({base_id})` 条件删除对空集 no-op,重复执行幂等。
- CE 无 base restore API(bases.service/controller 无 restore 路径),软删即用户视角终点 → softDelete 物理清变量(注释声明的密文 orphan 动机)无恢复丢失可达面;跟随上游 Extension.deleteByBaseId 同款模式。
- 调用处 context.base_id 与路由 baseId 同源(extract-ids.middleware.ts:523-536 通用 `params.baseId` 分支:Base.get 存在性校验 + 404 + context 注入),`validateUniqueKey` 用 context.base_id 与 insert 的 baseId 一致,无错位。
- DB unique(fk_workspace_id, base_id, key)(migration nc_202604290000:23-26)→ 并发同 key create 由 isUniqueViolation 兜底转 400(pg 23505/mysql ER_DUP_ENTRY/mssql 2627/2601 全覆盖)。
- deleteByBaseId 的 deepDel PARENT_TO_CHILD(CacheMgr.ts:473-483)删 list + 级联 del 全部 child 单变量 key;list 缺失时 getList 有 dangling-fallback 自愈(CacheMgr.ts:308-345)。

### 6. 权限/越权
- getVariableWithBaseCheck:variableId 不属 baseId → 404(不泄露存在性);跨 base 变量不可达。
- list 掩盖 secret 的 value/default_value(maskSecretVariable,undefined 序列化省略,不泄密文);单条 get 明文仅 creator 权限面,与写权限同面,无降权读写。
- extract-ids 对不存在的 baseId 直接 404,uuid/伪 id 无法到达 service。

## 攻击性找茬
无。考察过并排除的疑点(均无 API 可达链,不计 error):
- softDelete 清变量 vs Extension 仅 hard-delete 清:CE 无 restore API,不构成数据丢失面;
- deepDel list 缺失时 del(null):前缀化为具名 key 删除,no-op 无害;
- secret 行仅改 description 不触发守卫:model 该路径不写 value/default_value,无加密需求,守卫范围精确;
- isReplay 沙盒 id 注入:service 不透传 id,insert 仅 isReplay() 语境消费,API 不可达。
