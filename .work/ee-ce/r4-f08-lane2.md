# F08 Private Base — R4 lane2 报告(集成测试 + 代码复审,终局收敛轮)

审查对象:6aea3db097(实现)/ 2a86eb7d6c(R1)/ b1d3ec3c5b(R2)/ c8e0c83e0f(R3,重点)。
环境:dev 后端 :8080(全程运行,未重启)、qnap.elf-balance.ts.net/nocodb-dev;测试前缀 `f08r4l2-*`;7 用户(owner/ws-viewer/editor/viewer/inherit/no-access/super)、2 base(priv/public)+ 各 1 表 1 行。

## 结论

**PASS** — 0 error。R3 两修复(c8e0c83e0f)实测+源码双重验证通过;判定链五处终审无逻辑缺口;公共 base 无回归。

## 1. R3 修复验证(重点)

### 1.1 palette 三态(POST /api/v1/command_palette)
| 用户态 | 期望 | 实测 |
|---|---|---|
| priv base + INHERIT 行 | CLEAN | clean ✓ |
| priv base + editor 行 | HIT | PRIV ✓ |
| priv base + viewer 行 | HIT | PRIV ✓ |
| priv base + owner | HIT | PRIV ✓ |
| 无行(ws viewer) | CLEAN | clean ✓ |
| no-access 行 | CLEAN | clean ✓ |
| **公共 base + INHERIT 行(回归)** | HIT(上游行为不回退) | PUB ✓ |

代码核:`commandPaletteHelpers.ts:60-69` 分支 = `(NOT is_private) OR (is_private AND bu.roles != INHERIT)`,NO_ACCESS 由上游 `andWhereNot` 预排除 → 与 getProjectsList 的 EXISTS(NOT IN no-access,inherit) 语义一致。缓存:`Base.update:596` 调 `cleanCommandPaletteCache` → 转私即时生效(实测复现)。

### 1.2 publicSharedBaseGet 三态
公开 link → anon GET `/api/v2/public/shared-base/:uuid/meta` = **200**;PATCH is_private=true → **400** `Shared base feature is not available for private bases`;回退 false → **200**。✓

配套面(同 commit 覆盖):
- shared-view meta:`200 → 400 → 200` ✓;public-datas 侧 rows / count / bulk/dataList 转私后均 400,恢复后 200 ✓(checkViewBaseType 15 处调用点抽测 4 处)
- BaseViewStrategy(xc-shared-base-id 头):转私后 **401** ✓
- 私有 base 上 share create = 400、share update = 400(R1)、share delete = 200(owner 清理,无泄漏)✓

## 2. 角色矩阵抽测(私有 base,GET meta / GET data / GET users)

| 角色 | get | data | users | 备注 |
|---|---|---|---|---|
| 超管 | 200 | 200 | 200 | bypass mask |
| 工作区 viewer(无行) | 404 | 404 | 404 | `ERR_BASE_NOT_FOUND`,存在性隐藏 ✓ |
| base owner | 200 | 200 | 200 | |
| base editor | 200 | 200 | 200 | |
| base viewer | 200 | 200 | 200 | |
| no-access 行 | 404 | 404 | 404 | ✓ |
| INHERIT 行 | 404 | 404 | 404 | ✓ |
| 匿名 | 401(全局) | | | |

公共 base 基线:INHERIT 行 / no-access 行 = 403(上游语义保留)、其余 200、工作区 viewer 可见公共 base ✓。baseList 工作区分支:in=[pub]、na=[]、ed=[priv]、owner/sup=[priv,pub]、wsv=[pub] ✓。

## 3. PATCH is_private 链 + 即时性

- editor PATCH → **403**(baseUpdate 拒 editor)✓
- `is_private:"yes"` / `null` → **400**(swagger schema + service 双层)✓
- owner true→false→true 往返 200 ✓
- 转私后:工作区 viewer **同一 JWT** 下一请求即 404(getWithRoles 每请求解析,无重登)✓
- 移除协作者(editor)→ 同 JWT 下一请求 404 + 其 palette 立即 clean;重新邀请 → 200 ✓

## 4. R1 面抽测(补位回归)

- **legacy api token**(psql 插 `fk_user_id IS NULL` 行):私有 404 / 公共 200;owner 绑定 token 私有 200 ✓
- **duplicate**:私有 base 副本 `is_private=t`,owner 为唯一协作者,源 editor 对副本 404 ✓
- **create with is_private:true**:creator 200 / 工作区 viewer 404 ✓
- 迁移:v2 注册已移除、v2 文件已删(`ls` 确认);v0 注册 + `hasColumn` 守卫 ✓

## 5. 代码复审 — c8e0c83e0f 两改动评估

1. **公共 base 行为等价性**:两处新检查均为 `base?.is_private` 单分支,public 时 no-op——与改前 placeholder 等价;实测公共 link/view 三态(1.1/1.2)证实无回归。checkViewBaseType 在 dataList 等处先于密码校验执行 → 拒绝方向更严(安全侧),可接受。
2. **NcError.badRequest vs baseNotFound(400 vs 404)语义**:匿名公共路由 400 显式消息,认证层 404、strategy 层 401,三层不一致但各有依据:share UUID 为 128-bit 不可猜,攻击者须先持有 link,"已吊销 vs 从未存在"的区分在持有者前提下泄漏量可忽略;strategy 401 对齐上游 `UnauthorizedException` 惯例(handler 内 400 对齐 handler 内显式消息惯例)。判定:**可接受,非 error**(404 更严但非必需)。
3. **判定链五处终审**:① `User.getWithRoles:668-697`(INHERIT→null 上游逻辑 638 行前置,private 无显式角色→NO_ACCESS)✓;② `BaseUser.getProjectsList` 工作区继承分支(raw EXISTS 参数化,`IS NOT TRUE` 兼容 null)✓;③ 同函数 legacy 分支(R1 镜像过滤)✓;④ `extract-ids.middleware.ts:1251-1278` mask(超管/isPublicBase/legacy token 三豁免,排除 NO_ACCESS+INHERIT,guest 三处一致放行)✓;⑤ `commandPaletteHelpers:60-69` ✓。五处语义互相一致,无绕行缺口;公共路由无 @Acl 故不走 mask,由 R3 checkBaseType/checkViewBaseType 兜底——分工正确。
4. 杂项:`tsc --noEmit` exit 0;swagger is_private ×3(Base req/update/read);`useEeConfig.blockPrivateBases=false`、`store/base.isPrivateBase` 接真实 flag、acl `manageBaseType`(creator+,后端 baseUpdate 对应)一致。

## 6. 观察(非 error,无需行动)

- `packages/nocodb/src/services/public-metas.service.ts:399-403`:400 消息向"持有已吊销 link 者"透露 private 状态——见 §5.2,泄漏面可忽略。
- 超管 palette 无显式 base 行时不显示任何 base——上游 palette innerJoin 既有行为,非 F08 范围。

## 附:测试遗留

f08r4l2-* 用户及 nc_base_users_v2 行保留;4 个测试 base(priv/pub/dup/creatPriv)已经 API soft-delete;2 个测试 api token 行已删。psql UPDATE 权限行陷阱未触发(角色变更均走 API 或 insert 新行;workspace_user 两处 UPDATE 后均已重签 JWT)。
