# F09 R5 复审报告 — lane 5（zcode 独立第 5 路）

> 审查员：lane5（f09r5l5-* 专属账号，camoufox --session f09r5l5）
> 日期：2026-09-18 04:05–05:15 CST
> 对象：R4 修复批回归（commit 798e860dd1）+ 全清单复检（r3 任务书 8 项 + r4 增量附录）
> 后端：:8080 pid 9304（commit 94f7bc3cdc 巡逻重启，含全部 F09 修复）——全程未动

## 结论

**issues: 1 error / 2 minor / 2 observation / 1 E-blocked（清单7 UI 实测段）**

- **E1（本轮唯一 error）：非私有源 base 的 base 级 no-access 被工作区继承绕过**——`assertSourceReadAccess` 非私有分支只看 ws 角色，不消费显式 base 角色 no-access；平台层 403 拒绝的用户可经 F09 建同步并镜像该 base 全量数据（API 实测复现，见 §4）。
- 质量门：tsc exit 0；jest Fork 桶 41/41（3 suites）。
- R4 附录三项（is_private 分流矩阵 / jobs-map 标记 ×3 / console.debug 残留）全部 PASS。
- 清单7（UI 实测）E 级受阻：:3000/:3001/:3002 三个前端实例全处于僵死态（诊断证据 §7），按纪律未杀未重启，轮询 5min+ 未自愈；以静态代码审查作旁证，非 F09 代码问题。

---

## 1. diff 审查（清单1）— PASS

- F09 提交域（71896a841f + 修复批至 798e860dd1）实触 16 文件（`git diff --name-only 71896a841f~1..HEAD`），与实现报告清单一致（+`useTableSync.ts` 新增）。
- 后端四文件 `[CE-EE] F09` 标记：TableSync.ts ×1 / table-syncs.service.ts ×12 / table-syncs.controller.ts ×2 / table-sync.processor.ts ×4。
- jobs-map.service.ts `[CE-EE]` ×3（L15 import / L34 构造注入 / L97 映射）——R4 附录2 **PASS**。
- console.debug / `[F09-hide]` 残留：grep 四文件零命中——R4 附录3 **PASS**。
- 零改动文件确认：`store/sync.ts`、`utils/syncUtils.ts`、`utils/ncUtils.ts` 最后触达为上游 merge；`packages/nocodb/src/utils/acl.ts` 最后触达为 F02（F09 域内零改动）。
- `isSyncFeatureEnabled = ref(false)` 恒 false（store/sync.ts:19）；`blockTableSync=false`（useEeConfig.ts:163）、`blockTableSyncAuto=true`（:165）保持付费锁。

## 2. 引擎审查（清单2）— PASS（静态）

`table-sync.processor.ts`：
- RemoteId 键控 upsert：源行 `extractPksValues(row, true)` → dest RemoteId Map 匹配 → insert/update 分流（BaseModelSqlv2.ts:6245 签名核验，`asString=true` 返回字符串 pk）。
- 分页读源/读 dest 均 500/页 + `rows.length < SYNC_PAGE_SIZE` 终止（L155-171 / L185-227）。
- 白名单通道 `allowSystemColumn` 仅出现在 processor 内部 write params（L232-238）；HTTP 侧 insert/update/delete params 无此通道（`main` 带 owner token 直插 synced 表 400 实证，见 §6）。
- 失败落账：catch → `status=Error + last_error`（L71-81），成功 → Active + last_synced_at（L65-70）；rethrow 抑制有合理注释（防半写镜像队列重试）。

## 3. 服务审查（清单3）— PASS（静态）+ 1 error（动态见 §4）

- `assertSourceReadAccess` is_private 分流在位（L112-137）：私有分支要求显式 base 角色（非 no-access）；非私有分支要求 ws 角色 ≠ workspace-level-no-access。
- allow_sync 强制：`resolveSourceView` 无 allow_sync 视图 400（L187-200）。
- 镜像列过滤 `isMirrorableSourceColumn`：virtual/pk/ForeignKey/ID/Order/CreatedTime/LastModifiedTime/CreatedBy/LastModifiedBy/Attachment/Deleted 全排除（L58-70）。
- 保留名守卫：TABLE_SYNC_SYSTEM_COLUMNS + Id/CreatedAt/UpdatedAt/nc_* 大小写双集合（L338-379）。
- realtime 400：`syncTrigger !== Manual` 400（L322-326）；实测 `syncTrigger:"realtime"` → 400 "Only the manual sync trigger is supported"。
- system:true 后置补丁：metaList2/metaUpdate 直写 + COLUMN list 缓存失效（L495-522）。
- 编辑注记（minor-1，非功能性）：798e860dd1 删 console.debug 时遗留缩进错乱（table-syncs.service.ts L471 `if (grid?.id) {` 8 空格起、L473 注释 12 空格、L487 闭括号错位）——tsc 0，纯外观。

## 4. ACL 矩阵（清单4）— API 实测（非 super 专属：主账号仅 org-viewer+ws-creator）

### 4.1 十端点 × 角色（dest=destD，含真实 sync tsstz700gcok4ts4m）

| 角色 | list | get | sourceSchema | create | update | delete | resync | freeze | resume | resolveLink |
|---|---|---|---|---|---|---|---|---|---|---|
| owner(main) | 200 | 200 | 200 | 200 | 200 | 200(SD) | 200 | 200 | 200 | **501** |
| creator(u-creator) | 200 | 200 | 200 | 200 | 200 | 200(SC) | 200 | 200 | 200 | **501** |
| editor(u-editor) | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 |
| viewer(u-viewer) | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 |
| anonymous | 401 | 401 | 401 | 401 | 401 | 401 | 401 | 401 | 401 | 401 |

owner/creator 十端点 200（resolveLink 501 预期内）、editor/viewer 全 403、匿名全 401——与 r3 清单要求完全一致。

### 4.2 source-access 判定矩阵（R4 附录1；sourceSchema 走 destD，createSync 走 destE）

| 调用者（源侧关系） | 非私有 srcNP | 私有 srcP |
|---|---|---|
| u-zero（无关系，signup 默认 ws no-access） | createSync **404** ✓ | sourceSchema **403**（dest 侧 ACL 先挡）/ createSync 404 ✓ |
| u-wsna（显式 ws-level-no-access） | createSync **404** ✓（R4 修复回归点） | 404 ✓ |
| u-wscreate（ws creator，无 base 角色） | sourceSchema **200** / createSync **200** ✓（工作区继承） | **404** ✓（私有需显式 base 角色） |
| u-creator（升级前仅 destD base creator，ws no-access） | sourceSchema **404** ✓（base 邀请不给 ws 继承） | — |
| u-srced（srcP base editor + destE creator） | — | sourceSchema **200** / createSync **200** ✓（私有 × 显式 base 角色） |
| main（源 owner） | 200 ✓ | 200 ✓ |

**R4 修复批（798e860dd1）的修复目标全部回归 PASS：ws-level-no-access 与零关系用户对非私有源全部 404。**

### 4.3 E1（error）：ws creator × base 级 no-access（非私有源）

- 搭建：u-bna 以 `roles:"no-access"`（ProjectRoles.NO_ACCESS 正名）受邀进非私有 srcNP（邀请 200），再升其 ws 角色 = workspace-level-creator。
- 平台层：GET srcNP base meta **403**、GET records **403**（显式 base no-access 压过 ws 继承，平台语义正确）。
- F09 层：sourceSchema(srcNP) **200**、createSync(srcNP) **200**（真实 sync `tssi7vb17v2f2kn70` 创建，引擎已把 srcNP 全表镜像进 destE）。
- 根因：非私有分支（service L124-137）只评估 `workspace_roles`，完全未消费 `raw.roles`（base 级 no-access 未作为显式拒绝信号）。
- 判定：**error**。显式 no-access 是用户的明确拒绝授权，F09 绕过它外泄源数据。修法：非私有分支在 wsRead 通过后，若 `baseUser.is_mapped && raw.roles === 'no-access'/'no_access'` 应同样 404。
- 证据保留：sync tssi7vb17v2f2kn70 + 镜像表 `f09r5l5_m_gap` 未清理，供修复轮复验。

## 5. 引擎 e2e（清单5）— PASS（API 实测，dest=destE）

- full-create：main 建 sync `tss2xrn7p1z15w2nb`（srcNP，delete 策略）→ settle active → 镜像表 `m0cpx83tx8e8dz6` 3 行 {row1,1/row2,2/row3,3}，RemoteId="1/2/3"、RemoteDeleted=false，与源逐行对照一致。
- resync upsert：源改 row1 Qty=99、增 row4、删 row3 → resync → 镜像 3 行 {row1,99/row2,2/row4,4}：update 1、insert 1、消失行 delete 全部正确（初次误判为引擎失灵，实为测试脚本 v2 records API 用法错——bulk PATCH/DELETE 须对象数组 `[{Id:N}]`，带响应重测后确认引擎无误）。
- freeze/resume：freeze 200 → resync 400 "Sync is paused..."、update 400 → resume 200。
- mark_deleted：建 sync `tssjvxkmavek12kub`（onDeleteAction:mark_deleted）→ 镜像全量 → 源删 row4 → resync → 镜像保留该行且 **RemoteDeleted=true**。
- 状态机守卫：running 中 update 400、paused 中 resync/update 400、selected_fields 变更 400（P2 锁）、on_delete_action 双向改 200、realtime 创建 400（付费锁）。
- deleteSync：delete 200 → GET **404** "TableSync not found" → 镜像表从 base tables 列表消失（进平台 trash；trash 无独立 meta 路由，上游走 internal ops，以列表消失 + 软删语义为准）。

## 6. 守卫链 + 系统列（清单6）— PASS（API 实测）

- editor（destE base editor）对镜像表 m0cpx83tx8e8dz6：insert 400（readonly 守卫）、bulkUpdate 400（readonly）、bulkDelete **422 ERR_SYNC_TABLE_OPERATION_PROHIBITED**、加列 403（ACL）、建 form **422 ERR_SYNC_TABLE_OPERATION_PROHIBITED**（editor/owner 双验）、删表 403。
- owner(main) HTTP 直插 synced 表 400 —— 引擎白名单通道（allowSystemColumn+skipPermissionCheck）HTTP 不可达实证。
- RemoteId/RemoteDeleted 双保险：列 meta `readonly:true, system:true`（表 meta 实测）+ 默认 grid 视图列 `show:false`（/api/v1/db/meta/views/:id/columns 实测，唯二 false 两行精确命中 RemoteId=c0h6afg0r01m6ng / RemoteDeleted=cvic1outj4h2kao）。
- Fields 面板不暴露：UI 段 E 受阻（§7）；`isHiddenCol`（SYNC_SYSTEM_COLUMN_TITLES）+ system:true + show=false 三层在位，R1-R4 各轮 UI 实测均 PASS，沿袭风险低。

## 7. UI 段（清单7）— E-blocked（前端环境僵死，非 F09 代码问题）

诊断证据（均有命令留痕）：
1. **:3000**（PID 59078，周四起陈旧 nuxt dev，占 [::1]:3000）：同源 `/api/v1/auth/user/me`、`/api/v2/meta/bases` 一律返回 **HTML SPA fallback**（应用 API 全断）→ 页面永久骨架屏（截图 01/02/03）。
2. **:3001**（PID 7636，今晨 03:50 新 nuxt dev，含 F09 源码）：根路由 SSR 首渲染 44.5s；同源 `/api` 同样回 HTML（无代理转发）；signin/auth 路由可渲染、表单登录成功，但 `/nc/:ws/:base` 路由树/内容永不渲染（截图 05），轮询 5min+ 未自愈。
3. **:3002**（PID 31396，他路会话实例）——未占用。
4. 三 nuxt 同仓并发互踩（GOAL-STATE 历轮「frontend self-healed」同源 chronic 问题）。
5. 页面侧深查：error / unhandledrejection / console.error 三钩子 reload 后全空、资源加载零 4xx/0、token 有效（len 384，页面内带 xc-auth 直连 :8080 fetch 200）——排除 F09 前端代码问题，纯属共享前端进程僵死。
6. 纪律：严禁 pkill/重启他路进程（全局 §8），未杀未动。

静态旁证（替代性核验）：
- 向导 Back/Next/Create 三按钮在 **modal body 内**渲染（CreateNewSync.vue L272-302，R1 lane2/3/4 修复注释在位，data-testid `table-sync-back/next/create` 齐备）——R2 E1「footer slot 不渲染」问题的修复代码完好。
- editor 三入口静态审查 → **minor-2**：①Overview「NocoDB Sync」卡 `v-if="!isMobileMode && !blockTableSync"`（Overview.vue:134-136）无角色门（同列表兄弟项均带 `isUIAllowed('tableCreate')`）；②树节点 `SyncMenuOptions` `v-if="table.synced"`（Node.vue:855-857）无 isUIAllowed——editor 会看到入口但点击即 403（API ACL 已证不破防）。无数据暴露，判 minor；③SharePage allow_sync 区块 `!blockTableSync && grid`（SharePage.vue:708）上游 Share 对话框入口本身有权限门，可达性 OK。

## 8. 回归 + 质量门（清单8）— PASS

- tsc：`npx tsc --noEmit` **exit 0**（packages/nocodb）。
- jest：Fork 桶 **41/41 passed**（3 suites：26 基线 + 15 table-syncs.Fork.spec.ts；引擎日志 upsert/mark_deleted/paused-skip 全命中）。
- 探针（main token，全 200）：F05 `/api/v2/meta/bases/:id/variables`、F07 `.../snapshots`、F10 `.../dashboards`、F04（Airtable syncSource）`/api/v2/meta/bases/:id/syncs`、F02 `.../permissions` 返回 `[]`；F08 `is_private:true` 读写均正常；F03（Data permissions，本 fork 范围待做项）无独立路由，经 F02 端点探活（400 "Invalid entity undefined" = API 活且校验正常）。
- 环境注记：轮次中发现共享 fixture f01e2e（impl report §4 指定引导账号，实为 super+ws-owner）仅用于 ① ws 邀请（3+2 次）② 换取 workspace id 的临时 base（建删各一，title 带 f09r5l5 前缀）；其余全部操作（9 账号、6 base、10 sync、全部矩阵探测）均 f09r5l5-* 自有前缀。

## 汇总

| 项 | 判定 |
|---|---|
| E1 base 级 no-access 绕过（非私有源） | **error**（API 双层实测：平台 403 vs F09 200+镜像） |
| minor-1 R4 commit 缩进残留（service L471-487） | minor（纯外观，tsc 0） |
| minor-2 editor 可见死入口 ×2（Overview 卡 / 树菜单，静态） | minor（API ACL 不破防） |
| observation-1 sourceContext.ws 取 dest ws（跨 ws 场景理论分歧） | observation（CE 单默认 ws 不可构造，Workspace.insert 为 stub） |
| observation-2 resync 不复验源读权限（沿用 impl report 已声明 P1 限制） | observation（已文档化） |
| 清单7 UI 实测 | E-blocked（诊断证据 §7） |
| R4 附录 1/2/3 | 全 PASS（附录2 jobs-map ×3；附录3 console.debug 零残留） |
| 已知 minor 沿袭（selectedFields:[] / 非原子建表） | 未升级，不重复报 |
| 质量门 | tsc 0 + jest 41/41 |
