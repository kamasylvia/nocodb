# F08 R4 lane5 — 安全终审报告

结论:**PASS**(0 error;1 条观察项,不计 error,见 §5)

审查对象:6aea3db097(实现)/ 2a86eb7d6c(R1)/ b1d3ec3c5b(R2)/ **c8e0c83e0f(R3,本轮重点)**。
方法:静态走查 + nocodb-dev API 实测(全部本 lane 独立复现;测试前缀 `f08r4l5-l5-*`,base 已清理)。

## 1. R3 修复复检

### 1a. commandPaletteHelpers(packages/nocodb/src/helpers/commandPaletteHelpers.ts:60-69)

静态:新增 andWhere 分支 = `(is_private=false OR NULL) OR (is_private=true AND bu.roles != 'inherit')`。对公共 base 第一支恒真,原过滤(`andWhereNot NO_ACCESS`)行为逐字节不变——等价性走查成立。

实测(私有 base `pr2zls9ryxsd3ec` + 公共 base `pjwpsmb1mc5zvp6`,workspace `w9qi3ljd`):

| 场景 | palette 私有命中 | palette 公共命中 | 判定 |
|---|---|---|---|
| member,pkill 插 INHERIT 行(私+公) | False | True | CLEAN ✓ / 公共 INHERIT 不回退 ✓ |
| member 升 editor(走 API PATCH) | True | True | HIT ✓ |
| member 降回 inherit(走 API PATCH) | False | True | 即时收回 ✓ |
| owner(显式 owner 行) | True | — | HIT ✓ |
| 纯 workspace editor(无 base_users 行) | False | — | join 语义,本就不出现 ✓ |

缓存失效链:palette 键 `CMD_PALETTE:userId:workspaceId`;角色变更走 `BaseUser.updateRoles/insert/delete` → 四处均调 `cleanCommandPaletteCacheForUser`(BaseUser.ts:93/129/427/488),实测 PATCH 后下一次 palette 即反映新角色,无 leak 窗口。NocoCache 为进程内 RedisMock,psql 直改不触发 hook 属测试伪影,生产角色变更全走 API(hook 必经)。

member v2 base meta 随角色同步切换:editor=200 / inherit=404,与 palette 一致。

### 1b. publicMetas.checkBaseType / checkViewBaseType(packages/nocodb/src/services/public-metas.service.ts:395-411)

覆盖面走查:调用点 = public-metas(sharedBaseMeta:390、viewMetaGet:59)+ public-datas 全部 16 个 service 方法(dataList:154 / dataCount:255 / dataAggregate:305 / groupedDataList:366 / getGroupedDataList:418 / dataGroupBy:542 / getDataGroupByCount:594 / getDataGroupBy:631 / dataInsert:697 / relDataList:848 / publicMmList:1024 / publicHmList:1139 / dataRead:1256 / bulkDataList:1308 / bulkAggregate:1400)。`dataGroupByCount`(483)经 `getDataGroupByCount` 间接覆盖;controller 直写的 `downloadPublicAttachment` 经 `dataRead` 覆盖。无遗漏端点。

实测(shared-base uuid `d30ef84c-…`、view uuid `f3131118-…` 均建于公共态,再私有化):

| 端点 | 公共态 | 私有化后 | 恢复公共 | 判定 |
|---|---|---|---|---|
| GET /api/v2/public/shared-base/:uuid/meta | 200 | 400 | 200 | 三态 ✓ |
| GET /api/v1/db/public/shared-base/:uuid/meta(v1 同路由) | — | 400 | — | ✓ |
| GET /api/v2/public/shared-view/:uuid/meta | 200 | 400 | 200 | ✓ |
| GET /api/v2/public/shared-view/:uuid/count | — | 400 | — | ✓ |
| GET /api/v2/public/shared-view/:uuid/groupby | — | 400 | — | ✓ |
| GET /api/v2/public/shared-view/:uuid/rows(dataList) | — | 400 | 200 | ✓ |
| POST …/bulk/dataList | — | 400 | — | ✓ |

dataInsert(POST /rows)私有时 404:来源是 `view.type !== FORM` 守卫(public-datas.service.ts:695,在 checkViewBaseType 之前),GRID share 恒 404 与隐私无关;FORM share 会走到 checkViewBaseType 得 400。行为正确,非绕过。

## 2. 修复新面(误伤检查)

- checkBaseType 仅在 `base?.is_private` 拒绝;公共/sandbox/custom_url base(is_private=false/null)行为不变——publicSharedBaseGet 实测恢复公共后 200,share link 继续可用。
- 私有 base 上新建 share(R1 守卫)未受 R3 影响:R3 只断已存在链接的解析,与 R1「新建 400」互补不冲突。
- palette 对公共 base:SQL 等价走查(§1a)+ 实测(INHERIT 行公共 base 出现、owner 全命中)均无 diff。

## 3. 绕路面抽测(base 私有,member=INHERIT / wsEditor=纯 workspace editor / 匿名)

| 路径 | member(inherit) | wsEditor | 匿名 |
|---|---|---|---|
| v2 base meta | 404 | 404 | 401 |
| v1 base meta(/api/v1/db/meta/projects/:id) | 404 | — | — |
| v2 table rows | 404 | 404(+hdr 亦 404) | 404 |
| v1 data list | 404 | — | — |
| command palette | 不含私有 base | 不含私有 base | 401 |
| base 列表(ws editor 视角) | — | privInList=False,pubInList=True,total=53 | 401 |
| xc-shared-base-id header + v2 meta | 404 | 404 | 401 |
| public shared-base/view meta(带旧链) | 400(见 §1b) | 同 | 400 |

零绕过成功。workspace-level editor 继承可见公共 base(total=53 含目标公共 base)、私有 base 三层(列表/meta/palette)全不漏——`getProjectsList` 私有 EXISTS 过滤(R1)与 palette 分支(R3)行为一致。

## 4. 信息泄漏终审

- 错误语义:无链 uuid → 404(`ERR_VIEW_NOT_FOUND` / baseNotFound);有链+私有 → 400 统一文案 `Shared base feature is not available for private bases…`;有链+公共 → 200。400 文案不含 base title/id,仅提示"联系 owner"。
- palette/列表/搜索:私有 base title、tables、views 对非显式协作者零出现(§1a/§3 实测)。
- 400 vs 404 的存在性差异仅对**持有分享链接者**可辨(uuid 128-bit 随机不可枚举;持链者本曾获授权,信息增量=「base 已转私」)——见 §5 观察项。

## 5. 观察项(不计 error)

1. `public-metas.service.ts:395-411`:有链+私有的 400 与无链 404 可区分,对持链者泄漏「该 base 存在且已私有化」。判定:可接受——uuid 不可枚举、持链者本为历史授权用户、400 文案为面向人的产品语义(与 R1「新建 share 400」文案家族一致);上游 EE 对 pre-existing link 的处理同为 4xx 家族。不建议改动。

## 6. 测试过程备注(非发现)

- 初测 palette「升 editor 未生效」为测试伪影:psql 插 `nc_base_users_v2` 行漏 `fk_workspace_id`,导致 API PATCH 的 metaUpdate WHERE 匹配不到、DB/缓存脱钩。重插带 workspace 的行后缓存失效链完整复现(§1a)。产品代码无涉。
- 测试清理:两个测试 base 已 soft-delete(200);测试用户 `f08r4l5-l5-{owner,member,ws}@t.local` 保留于 nocodb-dev(owner 已提权 super,勿用于生产)。
