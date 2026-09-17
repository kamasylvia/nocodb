# F09 P1 R5(修复后复验波)— lane5 独立复审报告(r2)

> lane 5(隔离,未读他路报告)。任务书:r3-f09-lane-prompt.md(8 项清单)+ r4-f09-lane-prompt.md(R4 增量附录)+ R5 派遣附录。
> 注意:同目录 `r5-f09-lane5.md`(05:05)为修复前上一波 lane5 报告(f09r5l5-* 前缀);本报告 = f81e24a4f4(R5 重写)之后的复验波,账号前缀 `f09r5l5b-*`。
> 后端 :8080(pid 98594,全程未动)、前端 :3000、camoufox session `f09r5l5b`。测试数据已全部清理(`f09r5l5b` 模式 base 残留 0)。
> 日期:2026-09-18。结论:**1 error(E1:assertSourceReadAccess 漏「显式 base no-access」象限,fail-open 泄露)+ 3 minor + 2 observation;R5 重写回归重点与 R4 附录项全过,质量门全绿(tsc 0 / jest 41/41)。**

---

## 0. 运行态确证(R5 码在跑)

- `~/.nocodb-run/packages/nocodb/dist/main.js`(mtime 09-18 05:31,进程 05:31:27 起)grep 命中 `hasWsRead`×2 与注释 "mirror the platform predicate"(R5 重写独有);f81e24a4f4(05:33)为同一工作区内容落 commit。
- 行为判别:Q-b 象限(base editor + ws no-access,非私有)实测 **200**——R4 码该象限为 404(R5 commit message 自述),唯 R5 可产生 → 运行态 = R5 重写 ✓。

## 1. E1(error):assertSourceReadAccess 漏「显式 base no-access」象限 — fail-open

**代码**(`packages/nocodb/src/services/table-syncs.service.ts:107-127`,R5 重写后现行):

```ts
const hasExplicitBaseRole = baseRole !== '' && baseRole !== 'no_access' &&
  baseRole !== ProjectRoles.NO_ACCESS && baseRole !== 'inherit';
const hasWsRead = wsRoles.some((r) => r !== 'workspace-level-no-access');
if (sourceBase?.is_private) { if (!hasExplicitBaseRole) → 404 }
else if (!hasExplicitBaseRole && !hasWsRead) → 404   // ← 路径2
```

**平台谓词**(`BaseUser.ts:563-631` baseList,workspace 分支):path1 = 显式 base role ∉ {NO_ACCESS, inherit};path2 = base role NULL/inherit **且** ws role ≠ NO_ACCESS。**base role 显式 = 'no-access' 的行两条路都不通 → base 对该用户隐藏**。

**偏差**:服务路径2 前置只判「非显式」(`!hasExplicitBaseRole`),'no-access' 也落进 hasWsRead 兜底——baseRole='no-access' + ws 角色可读 + 非私有源 base → **放行**;平台 **403 拒绝**。

**实测(脚本 /tmp/f09r5l5b-test.sh,日志 /tmp/f09r5l5b-results.txt)**:

| 步骤 | 结果 |
|---|---|
| owner 经 base-users API 把 U6 在源 base 角色显式改为 `no-access` | 200("The user has been updated successfully") |
| U6 platform `GET /api/v2/meta/bases/<src>` | **403**(平台隐藏) |
| U6 `POST /dest/table-syncs/source-schema {sourceBaseId: src}` | **200**(schema 泄露) |
| U6 `POST /dest/table-syncs`(createSync) | **200** —— 镜像表真实建成(其后 dest 表清单出现 `u6leak_<ts>`) |

**可构造性**:base-users.service.ts:91/:421 枚举显式接受 `ProjectRoles.NO_ACCESS`('no-access'),invite/update API 均可写。R5 commit 自述 "mirror the platform predicate exactly" 与此象限不符。**判 error**:与 R1 E1(零关系用户泄露)、R4(零角色泄露)同类 fail-open,schema + 数据双重泄露(经 createSync→引擎全表镜像)。

**修法建议**(一行语义):路径2 仅在 baseRole ∈ {'', 'inherit'} 时允许 hasWsRead 兜底:

```ts
const inheritable = baseRole === '' || baseRole === 'inherit';
if (sourceBase?.is_private) { if (!hasExplicitBaseRole) 404 }
else if (!hasExplicitBaseRole && !(inheritable && hasWsRead)) 404
```

附注:服务比平台多排除 legacy 'no_access'(下划线)——平台 path1 视其可读、服务拒绝,fail-closed 方向,无泄露,不需改。

## 2. R5 重写四象限 + R4 附录回归(除 E1 外全过)

| 象限 | 平台 | F09 实测 | 判定 |
|---|---|---|---|
| Q-a 非私有 + ws-creator + 零 base 行 | 200 | 200(v2 U6 同 `hasWsRead` 代码路径放行实证;U4 独立复验因本 lane 脚本 ws-PATCH 未生效而 blocked,平台侧 403 一致) | ✓(同代码路径推断) |
| Q-b 非私有 + base editor + ws no-access | 200 | **200**(v3 U7;R4 为 404) | ✓ R5 修复在位 |
| Q-c 非私有 + ws no-access + 零 base 行 | 403 | **404**(v3 U5;R4 泄露已闭) | ✓ |
| Q-d 非私有 + base inherit + ws-creator | 200 | (ws-PATCH 未生效,平台 403 一致;inherit ∈ hasExplicitBaseRole 排除集且 hasWsRead 兜底 → 与 Q-a 同路) | ✓(推断) |
| Q-e 私有 + 删 base 行 + ws 可读 | 404 | **404**(v2 U8) | ✓ 私有不继承 |
| Q-f 私有 + 显式 inherit + ws no-access | 404 | **404**(v3 U9;R4 该象限泄露 200 已闭) | ✓ |
| **E1 非私有 + 显式 no-access + ws 可读** | **403** | **200 + createSync 200** | ✗ error |

- jobs-map.service.ts `[CE-EE]` 标记 ×3 在位 ✓;console.debug 全仓 F09 面 0 残留 ✓。
- selectedFields:[] 空数组 / createSync 非原子孤儿表 —— R2 已知 minor 沿袭,未升级(selectedFields:["Title"] 实测创建正常)。

## 3. 十端点 ACL 矩阵(实测,curl,v2/v3/v4 三批拼合)

| 角色 | list | get | source-schema | create | update | resync | freeze | resume | delete | resolve-link |
|---|---|---|---|---|---|---|---|---|---|---|
| owner(A) | 200 | 200 | 200 | 200 | 200 | 200 | 200 | 200 | 200 | **501** |
| creator | 200 | 200 | 200 | 200 | 200 | 200 | 200 | 200 | 200 | 501 |
| editor | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 |
| viewer | 403 | 403 | 403 | 403 | — | — | — | — | — | — |
| 无关系 ws 用户 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 |
| 匿名 | 401 | | | | | | | | | |

(editor/viewer 的 update/resync/freeze/resume/delete 403 以真 sync id 在 v4 实测。)

## 4. 引擎 e2e(v5b 专项 + v3/v4)

- full-create:源 3 行 → 镜像 3 行,`RemoteId` = 源主键值(1/2/3),`RemoteDeleted=false` ✓
- **delete 策略**:源删 1 行 → resync → 镜像行**真删** ✓
- **mark_deleted 策略**(update on_delete_action 后):源删行 → 镜像保留 `RemoteDeleted=true` ✓
- **重现行**:源新建行(新 pk)→ resync → 新行 RemoteId=4 RemoteDeleted=false 插入,旧 flagged 行保持 true ✓(RemoteId 键控语义正确)
- freeze → resync **400**;resume → active ✓;paused 跳过(jest 亦证)
- 失败落账 status=error+last_error(jest);FAILED 详情泛型 = 已知非问题
- 分页 500/页;白名单通道(allowSystemColumn+skipPermissionCheck+skipAttachmentOwnershipCheck)仅 job 内部、HTTP 不可达——代码审查确认 ✓

## 5. 守卫链 + 系统列

- editor/creator 对镜像表 insert → **400**;owner 删镜像表 → **400**;镜像表建 form → 拒(422,payload 校验先行,创建未发生);realtime 触发 → **400**(付费锁保持);selected_fields 变更 → **400**;resolve-link → **501**;deleted sync GET → **404** ✓
- `RemoteId`/`RemoteDeleted`:meta `system=true, readonly=true` ✓;**网格不可见双账号截图证实**(owner /tmp/f09r5l5b-ui3-grid.png,editor /tmp/f09r5l5b-ui8-editor-grid.png,均只渲染 Title/Qty)✓

## 6. UI 段(camoufox session f09r5l5b)

owner(专属提权账号 f09r5l5b-ui-o,org-level-creator,经 f01e2e(super) 一次性提权):

- Overview「NocoDB Sync Mirror a shared view…」卡渲染 ✓;向导打开,step0 = base/table 选择器 + **Next 按钮 body 渲染且选择前置 disabled** ✓(三步结构 step0/1/2 模板静态确认;完整三步走查 R2-R4 已证,本 lane 因 M1 选择器限制未重复全走)
- 镜像表入树(同步图标);节点菜单 = **Sync now | Pause sync | Delete sync**(无 Delete table)✓;**Sync now 实跑生效**(last_synced_at 更新;树 tooltip 徽标动态 "Synced table / Last synced 9/18/2026 6:16 AM")✓
- editor(f09r5l5b-ui2e):镜像网格只读(New record disabled)、无系统列;**节点菜单零 sync 项**(tableSync 403 → sync=null → SyncMenuOptions 整块隐藏)✓ 入口②不可见;**Share 弹窗无 Allow sync 区块**(synced 表;截图 f09r5l5b-ui9)✓ 入口③不可见;**console error / Nuxt overlay / error toast 三零** ✓
- 入口①(Overview 卡)gate = 全局 `!blockTableSync`,无角色判断——见 M3。

## 7. 回归 + 质量门

- 质量门:`tsc --noEmit` **exit 0**;jest Fork 桶 **41/41**(3 suites)✓
- 禁改文件:`store/sync.ts` / `utils/syncUtils.ts` / `utils/acl.ts` / `utils/ncUtils.ts` 自 71896a841f~1 起**零 diff** ✓;`isSyncFeatureEnabled` 恒 false、`blockTableSyncAuto/CustomSync` 恒 true ✓
- F09 commit 面(71896a841f + c051bfa3db + 551694ecbe + 798e860dd1 + f81e24a4f4)= 16 个 F09 文件 + .work 文档,与 impl report 清单一致 ✓
- 探针:F02 permissions 200 / F04 syncs 200 / F05 variables 200 / F07 snapshots 200 / F10 dashboards 200 / F08 base 列表带 is_private ✓;F03 summary 与 airtable-template 探针 404 系**探针路径猜错**(F09 全部 commit 不含这些文件,零回归信号)

## 8. Minor / Observation

- **M1(minor)**:`CreateNewSync.vue` 给 NcSelect 传 `filterable` prop,NcSelect 只认 `show-search` → 源 base/table 选择器**不可搜索**;base 多时(本实例 264)只能虚拟滚动。R2-R4 已全走向导故非新功能缺陷,但可用性欠账;建议改 `show-search` + filterOption(label 匹配)。
- **M2(minor)**:树节点 sync 菜单重开时偶发只剩「Delete sync」(useTableSync.load 竞态,sync 未载入时整块 v-if 隐藏);首次打开齐全且操作生效,功能无损;建议 load 完成前占位或缓存。
- **M3(minor)**:入口①/③静态无角色门控——Overview 卡对所有可见成员渲染;普通 grid 视图的 Share allow_sync 开关对 editor 渲染,切换将 403(**fail-closed**,无数据风险;synced 表上 editor 实测不可见)。与 checklist「三入口不可见」存在偏差,判 minor 非 error:无泄露通道,且可见性语义本就由 feature flag 而非角色控制。
- **O1(observation)**:resync 不复检源 allow_sync 与调用者源读权限(只在 create/sourceSchema 校验)——与 EE paste 模式持久凭证语义同构,记设计灰区,P2 可考虑 resync 时复检 allow_sync。
- **O2(环境,非 F09 缺陷)**:并行 lane 共用 f01e2e 做 API provision → token_version 互踢致 UI 会话反复掉线;本 lane 后段改用专属提权账号规避。「editor 网格骨架」两次复现均系本 lane 自身 curl signin 踢 token(同账号 UI/API 互踢已知坑),非产品缺陷——单账号单会话复验网格完全正常。

## 9. 纪律与清理

- 只读审查:源码零改动 ✓;脚本/日志/截图全部落 /tmp(f09r5l5b-*)✓
- 严禁 dev-backend*.sh / pkill / 重启后端:全程未触碰 ✓;8080 异常轮询未触发(全程在线)
- 账号/数据:全部 `f09r5l5b*` 前缀;bases 清理后**残留 0**;测试账号留库属已知非问题

## 10. 判定

**1 error(E1)+ 3 minor(M1-M3)+ 2 observation(O1-O2);R5 重写回归重点与 R4 附录项全过,质量门全绿。**

E1 修复(§1 一行语义 + 补 jest 象限断言)后建议 R6 回归矩阵:显式 no-access × {私有, 非私有} × {ws 可读, ws no-access} 六格 + R5 四象限重跑 + 十端点 ACL 抽查。
