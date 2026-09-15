# r4-f08-lane1 — F08 Private Base R4 终局收敛轮(集成测试 + 代码复审)

**结论:1 error**

- packages/nocodb/src/modules/jobs/jobs/export-import/duplicate.controller.ts:86(duplicateSharedBase 的独立 baseCreate):复制私有 base 时副本落为公共(is_private=f),绕过 duplicate.service.duplicateBase 的 R1 继承修复(duplicate.service.ts:113 只覆盖 /api/v2/meta/duplicate/:baseId 正路;本 controller 的 baseCreate body 不含 is_private)。建议:controller 内 baseCreate 补 `is_private: !!base.is_private`(置于 `...(body.base||{})` spread 之后防降级),或改走 duplicateService.duplicateBase 复用修复;可追加「目标 base 私有且请求者无显式协作者角色 → 404」与 extract-ids 掩蔽语义对齐。

## Error 详情与证据

- 实测(nocodb-dev):私有 base b1(paveucd8a8irg21,is_private=t,psql 设 uuid 后)经
  `POST /api/v2/meta/duplicate/w9qi3ljd/shared/<uuid>` → job 成功,副本 `f08r4l1-priv copy`(p1huouj0s6mwlmq)**is_private=f**。
- 对照:同 base 走正路 `POST /api/v2/meta/duplicate/paveucd8a8irg21` → 副本 pcb3i1lfluhlb6t **is_private=t**(修复路径工作正常);公共 base 正路副本 =f(不误提权)。
- 定性:duplicateSharedBase 是 UI 实路径,非死代码——`packages/nc-gui/pages/index.vue:177` 挂 `DlgSharedBaseDuplicate`(`components/dlg/SharedBaseDuplicate.vue`,经 `useCopySharedBase` → `api.base.duplicateShared`,SDK `Api.ts:10620`),即「Duplicate shared base / Use this template」流程;后端 ACL `duplicateSharedBase`(workspace owner/creator 可调)。R1 commit 把「duplicate or snapshot of a private base lands as a public base」列为修复目标,本入口遗漏,与 R1 已修项同级。触发面:workspace owner/creator 自伤面为主;另 `Base.getByUuid`(RootScopes.BASE 全局)不受工作区隔离,跨工作区 creator + 泄露 uuid 可复制出全员可读副本(严重度上限)。

## R3 修复验证(本轮重点,全部通过)

### a. commandPaletteHelpers palette 补 is_private 分支 — PASS
场景:b1 私有 + b2 公共;member 持两 base 的 INHERIT 行(psql 插新行),editor 持 b1 显式 editor 行,owner = b1/b2 owner。
- member `POST /api/v1/command_palette`:私有 b1 **0 hits**(首查直查 DB + 二查命中 NocoCache 缓存路径均 0);公共 b2 **3 hits**(上游 INHERIT 行为不回退)。
- editor:b1 **3 hits**(显式协作者可见)。owner:b1 3 hits + b2 3 hits。
- 代码等价性:b.is_private=false/NULL 时新分支第一支恒真,公共 base 与上游逐行为等价;私有 + NO_ACCESS 由前置 `andWhereNot(bu.roles, NO_ACCESS)` 排除,INHERIT 由新分支排除,与 getProjectsList 的 EXISTS 过滤(NO_ACCESS/INHERIT 均不显式)语义一致。
- 缓存一致性(扫尾复核):Base.update 无条件 `cleanCommandPaletteCache`(ws 级)→ privatize/转公开后 palette 不陈旧;BaseUser insert/角色变更 `cleanCommandPaletteCacheForUser` → 加/改协作者后立即生效。

### b. publicMetas.checkBaseType(publicSharedBaseGet)— PASS
b2 建 shared-base 链(uuid=f22da0cf…):匿名 `GET /api/v2/public/shared-base/:uuid/meta`(xc-shared-base-id)公开 **200** → PATCH is_private=true → **400**(msg="Shared base feature is not available for private bases…")→ 转回 false → **200**(返回 base_id/base_title 正常)。

### c. checkViewBaseType view-scoped public 端点 — PASS(抽 meta + dataList + dataCount 三个)
- 私有 b1 的预存 view share 链:匿名 `GET /api/v1/db/public/shared-view/:uuid/meta`、`GET /api/v2/public/shared-view/:uuid/rows`、`GET /api/v2/public/shared-view/:uuid/count` 全 **400**(body 同上,不回显 base_id/title)。
- 公共 b2 链:三端点 200 → b2 转 → 全 400 → 转回 → 全 200。
- 覆盖完整性(代码复核):public-datas.service 15 处调用 + public-metas.viewMetaGet 1 处;17 个公开方法逐一核对无遗漏(wrapper `dataGroupByCount`/`dataGroupBy` 委托的内部版 `getDataGroupByCount`/`getDataGroupBy` 各自含调用);参数形态全部 `(view, base)` 一致。次序:部分方法 check 先于 verifyPassword(私有时 400),viewMetaGet 先 verifyPassword(密码错 401)——差异仅错误码选择,均拒绝,无数据泄漏。

## 稳定性抽测(每类 ≥2 项,全过)

| 类 | 项 | 结果 |
|---|---|---|
| is_private 校验 | PATCH "abc"/"true"/1/null | 全 **400**("is_private must be a boolean",create/update 双侧 strict boolean);原值不被污染 |
| is_private 往返 | false→true→false→true | 4×200,DB/GET 读回值正确 |
| legacy token(base-scoped) | 非绑定 base | 401(authtoken 策略 scope 检查 `apiToken.base_id !== ncBaseId`,在 base 元数据查询前,与 is_private 无关);绑定 base 200。语义=token 范围不匹配,不泄漏 is_private |
| legacy token(account-wide userless) | 私有 meta/dataList | **404**(与不存在 base 的 404 ERR_BASE_NOT_FOUND 同型,存在性不泄漏);公共 meta/dataList **200** |
| shared-base 链 | 私有建链 / 公共建链 / 管理端点匿名 GET | 400 / 200 / **401** |
| shared-base 预存链 | 私有(经 GlobalGuard base-view 策略分支场景) | 400(publicMetas 层;R1 BaseViewStrategy is_private 401 分支代码在位,本路由仅 PublicApiLimiterGuard 故由 R3 层拦截) |
| duplicate 继承 | 正路私→t、公→f | 通过 |
| duplicate 防降级 | body.base.is_private=false 覆盖尝试 | 副本仍 **t**(is_private 置于 spread 后) |
| snapshot 链 | base-snapshots.service:60 走 duplicateService | 代码复核:被修复路径覆盖 |
| member 无显式角色 × 私有 | meta / api-tokens / data GET / data insert / users | 全 **404**;base list 不含 b1 |
| 显式协作者 editor × 私有 | meta / data | **200/200** |
| 超管(owner,users.roles=super) | privatize/read/update/duplicate 全程 | 全 200 |
| workspace 继承主路径 | wseditor(workspace-level-editor、无 base 行) | 公共 meta 200;私有 meta 404;列表无 b1 |
| palette 缓存陈旧 | member 二次查询(命中缓存) | 私有仍 0 hits |

member 对公共 b2 meta = 403 的说明:member 的 workspace 角色为 workspace-level-no-access,INHERIT 继承 no-access → 403,为上游固有行为(非 F08 回退);真正的继承路径由 wseditor 用户验证通过。

## 回归 — PASS

- 公开 base CRUD:create 200 / read 200 / update 200(title/description 生效)/ list 含新名 / delete 200 / re-read 404。
- 分页计数:records list limit=2 → rows 2 + totalRows 3 正确;base list totalRows 正确(owner 视角 68)。(观察:base list 对 limit=2 返回整页 pageSize=68,上游 PagedResponseImpl 行为,F08 未触及 list 分页,不计。)
- jest:**26/26 passed**(2 suites,testRegex Integration|Source|Fork 桶)。base-view.strategy.spec 等上游 spec 不在该 testRegex 内(CE 默认测试面,非本 fork 新增,未跑)。
- `npx tsc --noEmit`:**exit 0**。

## 其它扫尾结论

- palette 修改对公共 base 等价性:见 R3-a,布尔逻辑恒真分支,无行为差。
- 错误消息存在性泄漏:checkBaseType/checkViewBaseType/BaseViewStrategy/shared-bases 建/刷链统一文案,不回显 base 标识;private 404 掩蔽与不存在 404 同型(extract-ids + controller 层)。
- R2 遗留:非布尔 400 双侧 strict boolean 实测通过;v0 guarded migration 本轮由迁移已应用 + 全量行为正常佐证。

## 环境

后端 http://localhost:8080(全程可达,无重启无杀进程)、前端 :3000 可达;dev DB qnap.elf-balance.ts.net:5432/nocodb-dev(仅 nocodb-dev)。测试产物清理:6 个 f08r4l1* 测试 base 已删,psql 临时行(2 legacy tokens、3 base_users)已删;f08r4l1-* 测试用户保留(与前三轮同做法)。无 E3。
