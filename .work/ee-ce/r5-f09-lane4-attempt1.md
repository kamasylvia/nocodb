# F09 P1 Table Sync — R5 lane4 独立复审报告

> lane 4（zcode subagent）｜会话隔离：camoufox --session f09r5l4｜账号前缀 f09r5l4-*
> 审查对象：R4 修复批 commit 798e860dd1（is_private 分流补强 + debug 清除）回归 + R1-R5 基准 8 项清单
> 后端 :8080 / 前端 :3000 全程未动（零重启、零 dev-backend 调用）
> 日期：2026-09-18

## 结论

**PASS — 0 error**。R4 修复批（798e860dd1）行为矩阵全数实测命中；R1-R4 各批修复无回潮；基准 8 项清单全过；跨功能探针（F02/F04/F05/F07/F08/F10）200 无回归。2 个 minor / 2 个 observation，均不阻塞。

## R4 增量附录核验（重点）

### 1. is_private 分流矩阵（assertSourceReadAccess，798e860dd1）✅

代码核验（table-syncs.service.ts:91-138）：私有分支要求 base 级角色（roles 排除 no_access）；非私有分支要求 workspace_roles 含非 `workspace-level-no-access` 角色；`BaseUser.get` innerJoin 对非 workspace 成员返回空 → raw 空串 → 双分支均 `NcError.baseNotFound`（404 hide-existence）。sourceBase 为 null 的兜底在 loadSource:154-155（Base.get 二次校验）。

API 实测矩阵（source-schema 端点，dest=f09r5l4-dest）：

| 用户画像 | 私有源 base | 非私有源 base | 平台层 base-read 对照 |
|---|---|---|---|
| noaccdst（dest-owner + ws-level-no-access + 源零关系）| **404** ERR_BASE_NOT_FOUND | **404** ERR_BASE_NOT_FOUND | 200（dest 侧有权，能进源检查）|
| wscreator（ws-level-creator + 源零关系）| 404 | **200**（CE workspace 继承恢复）| 200 |
| owner（ws-creator + srcpriv base-owner + srcpub 零 base 角色）| **200**（base 角色路径）| **200**（ws 继承路径）| 200 |
| norel / wsnoacc（ws-no-access）| 403* | 403* | 403 |

\* norel/wsnoacc 的 403 来自 dest 侧 ACL（tableSyncSourceSchema creator+，其非 dest 成员）——未达源检查层，属正常 ACL 拒绝；R4 修复的源侧 404 路径由 noaccdst（有 dest 权 + ws-no-access）精确命中。

**R4 commit message 的两条行为声明（ws-no-access 拒读非私有 base、404 hide-existence）均实测成立；R3 lane2 修复（ws-creator 继承 200）无回潮。**

### 2. jobs-map [CE-EE] 标记 ×3 ✅

jobs-map.service.ts:15 / :34 / :97 三处在位。

### 3. console.debug 残留清除 ✅

table-syncs.service.ts / TableSync.ts / table-syncs.controller.ts / table-sync/ 全量 grep `console.debug` + `F09-hide` = 0 命中。

### 4. 已知 minor 沿袭（不重复计）✅

- `selectedFields: []` 空数组 → 建仅含系统列的空镜像（service.ts:384-393 + :409-411）：行为与 R2 记录一致，无新触发面（UI 不产生 []），**未升级**。
- createSync 非原子（tableCreate 先于映射/job，中途失败留孤儿 synced 表）：沿袭，未升级。

## 基准 8 项清单

### 1. diff 审查 ✅

- F09 commit 链：71896a841f（实现 16 文件）+ ef942b141d（R1）+ 0f16d3cf40 / c051bfa3db（R2）+ 551694ecbe（R3）+ 798e860dd1（R4）。修复批均只触 table-syncs.service.ts / jobs-map / SyncMenuOptions / CreateNewSync，与 impl report 清单一致。
- 后端 F09 文件 [CE-EE] 标记：TableSync.ts(1) / controller(2) / service(12) / processor(4) / Fork.spec(6) / jobs-map(3) / jobs.module(2) / noco.module ✓。
- 禁改文件零改动：store/sync.ts（上游 merge 后未动）、syncUtils.ts（上游 i18n fix 后未动）、nc-gui/utils/acl.ts（不存在）、后端 utils/acl.ts（末次改动属 F02）、ncUtils.ts（上游 merge 后未动）。
- isSyncFeatureEnabled 恒 false（store/sync.ts:19）✓。
- gate：blockTableSync=false（useEeConfig.ts:163，带注释）；blockTableSyncAuto / blockCustomSync 仍 true（:165/:167，付费锁保持）✓。

### 2. 引擎审查 ✅

table-sync.processor.ts：RemoteId 键控 upsert（existingByRemoteId map / seenRemoteIds 去重 / inserts+updates 分箱 / stale sweep）；双侧分页 500/页；失败落 status=error + last_error（catch 块），成功落 active + last_synced_at；paused 跳过（job() 入口）；mark_deleted 重现行 RD 复位（:213-215）；引擎白名单通道（allowSystemColumn/skip_hooks/skipPermissionCheck/skipAttachmentOwnershipCheck）仅在 job 上下文直调，HTTP 不可达。bulkUpdate/bulkDelete 处仅 allowSystemColumn+skip_hooks（无 skipPermissionCheck）——job 上下文无 HTTP 中间件，四轮沿袭设计，非新问题。

### 3. 服务审查 ✅

allow_sync 强制（resolveSourceView 无合格视图 400）；镜像列过滤（isMirrorableSourceColumn：virtual/pk/系统 uidt/Attachment/Deleted 排除）；保留名守卫（engine system cols + tableCreate repopulation 列名，title+column_name 双查）；realtime 触发 API 400（syncTrigger != manual）；system:true 后置补丁（metaUpdate 直改 + COLUMN list 缓存 deepDel）；selected_fields 变更拒收（P2）；resolveLink 501（P2）。

### 4. ACL 矩阵 ✅（API 实测，非 super 账号）

七端点 × 5 角色（list/get/source-schema/resync/freeze/resume/update/resolve-link）：

| 角色 | 结果 |
|---|---|
| owner（dest owner）| list/get/source-schema/resync **200**；freeze/resume/update **400**（前一步 resync 触发 syncing 的业务态 400 = ACL 放行证据）；resolve-link **501** |
| noaccdst（dest owner, ws-no-access）| 同 owner（source-schema 404 = R4 源侧 hide-existence）|
| editor / viewer | 全 **403**（含 resolve-link）|
| anon | 全 **401** |

超管（f01e2e super）仅用于建数据，ACL 判定全部由非 super 账号实测（规避 checkPermission super 直通假 FAIL——F03 R5-lane4 教训沿用）。

### 5. 引擎 e2e ✅（API 实测）

- full-create：srcpub 3 行 {row1..3}×{Title,Qty} → mirror_pub 3 行，RemoteId="1/2/3"、RemoteDeleted=false、Title/Qty 逐值对照一致。
- resync 增行：源 +row4 → resync → 镜像 4 行（RemoteId=4 键控 insert）。
- mark_deleted 策略（srcpriv→mirror_priv）：源删 Id=3 → resync → 镜像 row3 RemoteDeleted=**true**，row1/2 不动。
- delete 策略：updateSync 切 on_delete_action=delete（200）→ 源删 Id=4 → resync → 镜像行物理消失（row3+row4 全清）。
- 生命周期：updateSync(selected_fields)→400；updateSync(title)→200 生效；freeze→paused；paused 时 resync→400；resume→active。
- realtime 触发 createSync→**400**（付费锁保持）；resolve-link→**501**。
- deleteSync→200 → GET→404 → 镜像表 meta→404（进 trash）。
- 本轮实测缺口：字段值 UPDATE 传播（盲刷 updates 分支）未在活体复现实测（共享 bootstrap 账号 f01e2e 被多路并行 signin 互踢，源行 PATCH 404 阻断）——依据 impl 自测日志（inserts=1 updates=3）、jest full-resync spec、R1-R4 四轮 lane 沿袭接受。

### 6. 守卫链 + 系统列 ✅

- editor 对镜像表 insert→**400**（prohibitedSyncTableOperation）；viewer insert→403；editor 列改/列删/表删/加列→403（ACL 层）。
- owner（creator+）删镜像表→**400**；建 form view→**422** ERR_SYNC_TABLE_OPERATION_PROHIBITED。
- owner（creator+）镜像表加列→**200**（见 observation O2）。
- RemoteId/RemoteDeleted：columns meta system=true + readonly=true；grid view columns show=false（末两列）；Fields 面板不出现（System fields 开关翻开后仍不出现——isHiddenCol 硬编码 SYNC_SYSTEM_COLUMN_TITLES 生效）。

### 7. UI 段 ✅（camoufox --session f09r5l4，截图 /tmp/f09r5l4-*.png）

- 入口一：dest base Overview「NocoDB Sync — Mirror a shared view…」卡渲染，点击开向导。
- 向导三步：step1 Browse+base/table 下拉+Next；step2 View+Fields to sync+**Back/Next**；step3 Sync settings（Manually 档+删除策略单选）+**Back/Create sync**——按钮全在 body 渲染且可用（R2 E1 回归重点）；UI 全流程实际创建 sync（src_tbl，status→active）成功。
- 入口二：树上双镜像表带同步图标；表菜单含 **Synced table 分组 + Sync now / Pause sync / Delete sync**（R2 E1 回归重点）；Pause→API status=paused→tooltip「Synced table / Paused」→Resume→API active（tooltip 动态重读正确）。
- 入口三：srcpub 视图 Share 弹窗「Allow sync」开关渲染 ON 且**无 paywall badge**；allow_sync:true 持久化 + uuid 自动创建。
- Fields 面板零系统列暴露（见清单 6）。
- editor 三入口全不可见：①Create New 面板整体隐藏 ②表菜单仅 TABLE ID（Synced table 组/管理项零渲染）③Share 弹窗无 Allow sync 区块。镜像网格 New record 置灰（只读态）。
- console error 0 + Nuxt/vite overlay 0（collector 全操作轮次）。

### 8. 回归 + 质量门

- 跨功能探针（f01e2e super，仅探针不判定 ACL）：F07 snapshots 200 / F05 variables 200 / F02 permissions 200 / F08 base meta 200 / F10 dashboards 200 / F04 syncs sources 200——零回归。
- tsc --noEmit：见文末质量门（后台运行）。
- jest Fork 桶：见文末质量门。

## Issues

### minor

- **M1 缩进混乱（R4 commit 引入，纯格式）**：table-syncs.service.ts:471 `if (grid?.id) {`（8 空格）、:473 注释（12 空格）、:487 闭括号（10 空格）——798e860dd1 删 console.debug 时未还原缩进。功能零影响、tsc 无警；属修复卫生问题，建议随下次触碰该文件时顺手 prettier 归位。

### observation（不计 error，供主会话裁量）

- **O1 引擎 updates 分支活体实测缺口（本轮）**：受多路并行共享 bootstrap 账号互踢限制（f01e2e token_version 被其它 lane 反复 signin 置换），源行 PATCH 无法在 :8080 以非 super 身份完成；updates 分支正确性依据 impl 日志 + jest spec + R1-R4 沿袭。若需活体复现，建议主会话在无并行 lane 窗口用独立高权限账号跑一次盲刷对照。
- **O2 creator 可在镜像表加列（上游 CE 守卫面既有）**：columns.service 的 synced 守卫只覆盖 columnUpdate/columnDelete（readonly），columnAdd 无 synced 判断——owner add column 200。引擎 resync 只写映射列，不破坏数据；属上游 CE 既有行为（fork 守卫面=上游原样），非 fork 引入，与 EE 行为差异无法对照（EE 专有不可见）。建议记 backlog（上游对齐）。

### 非问题（勿计）

- norel/wsnoacc 对十端点 403：dest 侧 ACL 正常拒绝，非源检查路径（R4 的 404 由 noaccdst 精确验证）。
- resume 后旧 tooltip 实例残留「Paused」：hover 重读即正确（Synced table），动态读取无陈旧。
- form view 守卫 422（非 400）：ERR_SYNC_TABLE_OPERATION_PROHIBITED 守卫生效，错误码风格差异。
- UI 向导创建后树上短暂未刷新：页面 reload 后双镜像表齐全（树刷新时序，非数据问题）。
- 共享 bootstrap 账号 token 互踢：已知框架行为（F05 教训入库项）。

## 测试资源留痕（nocodb-dev，前缀 f09r5l4，保留供复核）

- 账号：f09r5l4-{owner,norel,wsnoacc,wscreator,editor,viewer,noaccdst}@ce-ee.local / Xc123456!（.work 外不入 git）
- base：srcpub=pnc97gbb5wzaces（非私有）/ srcpriv=p7il46xp7ekklyg（私有）/ dest=p18chk1q3uc8nw4；workspace w9qi3ljd
- sync：mirror_priv（sync2=tss 系列，active，srcpriv 源）/ src_tbl（UI 向导创建，active）；mirror_pub（sync1）已 deleteSync 验证后进 trash
- 截图：/tmp/f09r5l4-{wizard-created,tree,fields,fields2,fields-sys,share,share2,editor-menu,editor-share}.png

## 质量门

- `npx tsc --noEmit`（packages/nocodb）：**exit 0**
- `pnpm test`（jest，--runInBand）：**Test Suites 3/3，Tests 41/41 passed**（26 基线 + 15 F09 Fork spec），exit 0
- 跨功能探针：F02/F04/F05/F07/F08/F10 全 200，零回归
