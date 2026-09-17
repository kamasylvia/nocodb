# F09 R5 lane2 复审报告(独立第 2 路,camoufox session f09r5l2)

> 日期 2026-09-17/18 深夜轮。对象:R4 修复批 798e860dd1 回归 + R3 修复批 551694ecbe + 全量 F09(71896a841f / c051bfa3db)。后端 :8080(nocodb-dev)、前端 [::1]:3000。全程未动 dev-backend/pkill/后端。
> 账号 f09r5l2-*:owner / editor / viewer / zws / wscreator(ws-creator 继承)+ 共享通道 f01e2e(中途密码失效,见「环境异常」)。

## 结论:1 error(P-1,实测复现)+ 2 minor + 5 observation;其余全 PASS

---

## E1(error)R4 非私有分支漏看显式 base 角色——平台层可读的源被 F09 404 拒

- **位置**:`packages/nocodb/src/services/table-syncs.service.ts:124-137`(assertSourceReadAccess 非私有分支,R4 798e860dd1 引入)
- **实测矩阵**(干净 base 对,src=非私有、priv=is_private=true,全部调用方持 DST creator 过 ACL 后到 service 层):

| 源 base | 调用方源侧关系 | 平台层 GET base/records | F09 source-schema | F09 createSync |
|---|---|---|---|---|
| 非私有 | 零关系(ws-no-access,signup 默认) | 404 | **404 PASS**(R4 核心) | 404 PASS |
| 非私有 | **显式 base creator** | **200 / 200** | **404 FAIL** | **404 FAIL** `ERR_BASE_NOT_FOUND` |
| 非私有 | ws-level-creator 继承(无显式角色) | 200 | 200 PASS | — |
| 私有 | 显式 base creator | 200 | 200 PASS | — |
| 私有 | 零关系 | 404 | 404 PASS | — |
| 私有 | ws-creator 自建(建者自动 owner) | 200 | 200 PASS | — |

- **根因**:非私有分支只读 `raw.workspace_roles`(`wsRead = wsRoles.some(r => r !== 'workspace-level-no-access')`),**不回退看显式 base 角色 `raw.roles`**。平台层角色合成(`User.ts:668-691`)是「显式 base_roles 优先,无则 ws 继承」——显式 creator + ws-no-access 的用户平台层完全可读,F09 却 404。私有分支(`raw.roles` 判定)与非私有分支语义倒挂:私有认显式角色,非私有不认。
- **影响**:被 owner 显式授权源 base 角色的协作者无法把该 base 用作 sync 源(向导/schema 双 404);授权语义倒挂(继承角色反而可用)。与 R3 lane2 修复的「非成员 404 dead end」同构,但发生在显式授权子集。
- **修复建议**:非私有分支改 `wsRead || baseRoles.some(r => r !== 'no_access' && r !== ProjectRoles.NO_ACCESS)`(私有分支同一判定已存在,可直接复用)。
- **定级理由**:任务书 ACL 矩阵「无关系用户拒」核心已达成,但「owner/creator 对端点 200」的授权者语义在非私有源被破坏;API 实测双端点复现,非推测。

## M1(minor)三入口对 editor 无渲染层角色门控(任务书清单 7 口径)

- 读码(三条入口条件均只看 feature gate,无角色):
  - `Overview.vue:135` `v-if="!isMobileMode && !blockTableSync"`
  - `Node.vue:855` SyncMenuOptions `v-if="table.synced"`;`SyncMenuOptions.vue` 模板内无 isUIAllowed
  - `SharePage.vue:708` `v-if="!blockTableSync && activeView?.type === GRID"`
- 实测(editor 登录):base overview URL 被重定向回 grid(有表 base 不落 overview 页),入口一直接实证受限;树节点菜单按钮对 editor 存在,dispatch 点击未弹出(hover 门控,无法完全实证菜单项);SharePage 未逐项截图。
- **后端 ACL 硬闸完好**:editor 对十端点全 403(实测),无权限提升/数据暴露。纯 UI 可见性缺口(editor 见 Sync now/Pause/Delete sync 按钮,点击后 403 toast)。建议入口渲染加 `isUIAllowed` 判定或菜单项按角色隐藏。

## M2(minor)deleteSync 成功后树不刷新

- UI 点 Delete sync → 确认弹窗「"ui_sync" Cancel/Delete sync」→ 确认 → API 侧实证 syncs=[]、镜像表从 tables 消失(**后端删除成功**),但树仍显示已删节点,切表也不刷新,整页重载才消失。`SyncMenuOptions.onDelete` 已调 `useBases().loadTables()`(SyncMenuOptions.vue onDelete),实际效果未生效——疑 store 缓存路径,建议核 loadTables 刷新面。

## Observation(不计入 error/minor 计数,O 系)

1. **O1** `table-sync.processor.ts:254-259` updates 分支手写 `{cookie, allowSystemColumn, skip_hooks, typecast}`,未复用 `engineWriteParams`(少 `skipPermissionCheck`/`skipAttachmentOwnershipCheck`)。resync 实测正常(附件列不镜像,通道也无 HTTP 权限拦截),但与 insert 分支不对称,建议统一展开避免后续加字段遗漏。
2. **O2** R4 commit 缩进变形(`table-syncs.service.ts:471/473/487`,2→8 空格错位),功能等价,格式瑕疵。
3. **O3** synced 镜像表 columnAdd 无守卫:creator 对镜像表 POST columns 返回 200(加列成功)。resync 不触碰该列、引擎无破坏,但「只读镜像可加列」与 EE 语义不符(上游 CE 守卫链本就只覆盖 update/delete,列加是上游缺口,fork 可考虑补)。
4. **O4** 前端 sync 状态缓存不彻底:Sync now 点击后菜单项按 syncing 态收起(状态机正确),但引擎完成后菜单不自动恢复(需整页重载),与 M2 同源的状态刷新问题。
5. **O5** v2 行级写守卫的 HTTP 码不一致:insert=400(readonly)、update=400(readonly)、delete=**422** `ERR_SYNC_TABLE_OPERATION_PROHIBITED`(上游 prohibitedSyncTableOperation 映射)。任务书「写全 400」口径按 4xx 客户端错误从宽判定通过,口径建议统一记录。

## 8 项清单逐项

1. **diff 审查**:PASS。F09 全量改动 = 16 文件(4 commits 合并),与实现报告清单一致;后端文件 [CE-EE] 标记齐;jobs-map [CE-EE] ×3 在位(:15/:34/:97);store/sync.ts、syncUtils.ts、acl.ts、ncUtils.ts 零触碰(last-touch=F02 commit);isSyncFeatureEnabled 恒 false(store/sync.ts:19);blockTableSyncAuto/blockCustomSync 保持 true(useEeConfig.ts:165/167)。
2. **引擎审查**:PASS。RemoteId 键控 upsert 实证(full-create 3 行精确;源改值 resync 刷新 33;源删行 delete 策略 sweep 行消失;mark_deleted 策略 RemoteDeleted=true 双样本);分页 500/页;白名单通道仅引擎内部(HTTP insert 400 无法绕过);失败落 status=error+last_error(jest 断言);paused 跳过(实测 resync 400)。
3. **服务审查**:PASS,除 E1。allow_sync 强制(resolveSourceView 400);镜像列过滤(附件/虚拟/pk/系统/软删列排除);保留名守卫;realtime API 400(实测);selected_fields 变更 400(实测);system:true 后置补丁 + GVC show=false 双保险在位。
4. **ACL 矩阵**:PASS(十端点 × creator/editor/viewer/anon = 200/403/403/401,resolve-link creator 501 除外);E1 为源侧判定缺陷(见上),目标侧 ACL 无问题。
5. **引擎 e2e**:PASS。full-create → RemoteId 对照(Id/RemoteId/RemoteDeleted 精确)→ resync upsert → on_delete_action 双策略(delete sweep + mark_deleted)→ freeze(resync 400)→ resume → updateSync(title/on_delete 可改)→ deleteSync → GET 404 + 镜像表出 meta、数据保留。
6. **守卫链 + 系统列**:PASS。editor 对镜像表 insert/update 400、delete 422、建 form 400(路由见 O5 备注)、删表 400(`Synced tables cannot be deleted`);RemoteId/RemoteDeleted `system=true readonly=true` 实证;grid GVC show=false 后置补丁在位(createSync 内)。
7. **UI 段**:PASS(带 M1/M2)。Overview「NocoDB Sync」卡渲染(截图 01);向导三步全通:step1 base/table 双下拉 → step2 字段 radio + Back → step3 标题/删除策略 + Back/Create(截图 02/03/04),Back/Next 往返正常,Create 成功建 sync(API 实证 active);管理面板:树节点菜单 Sync now/Pause sync/Delete sync 实装(截图 05),Sync now 点击 → 引擎跑完 active(last_synced_at 实证),Delete sync 确认弹窗 → 删除成功(截图 06/07);editor:Overview 入口不可见(testid 不存在)、console error 与 Nuxt overlay 双零(挂钩实证);SyncStatusBadge/树 synced 表 New record disabled(只读 UI)。
8. **回归 + 质量门**:PASS。F01 unique(重复插 400)、F02 permissions 面(200;synced 表拒配 400)、F03 acl 面(非 5xx)、F04 syncSource(200 不回归)、F05 variables 200、F07 snapshots 200、F08 is_private 读写一致、F10 dashboards 200、Airtable import 非回归;`tsc --noEmit` exit 0;jest Fork 桶 41/41(3 suites)。

## 环境异常(不影响判定,留痕)

- f01e2e@ce-ee.local 密码中途失效(20:35 前有效,后被改;疑并行 lane 或外部操作)。该账号名下遗留 3 个本 lane 产生的 base 删除 403,需 orchestrator 用有效 owner 通道清理:`pk8t9my8i8a26g7`(f09r5l2_src_1789676133)、`pb3bdn8nvqt3s9r`(f09r5l2_dst_min3,内含 sync tss0kuhv6f6ind5xy + 镜像 f09r5l2b_eng 系测试数据)、`psr0ilr00e38jq6`(f09r5l2_tok_probe 空壳)。本 lane 自建 base(f09r5l2b_* ×5)已全部删除。
- 前端登录态:token 不落 cookie(localStorage/内存),camoufox 整页导航必掉登录(SPA 内稳定);API signin 同账号会顶掉浏览器会话——UI 段后期全部改 SPA 内导航完成。
- 测试脚本与状态:`/tmp/f09r5l2-*.py`(probe/matrix/engine/diag/regress);截图 `.work/ee-ce/f09r5l2-shots/01-08*.png`。

## 纪律自检

只读审查未改任何源码;未读他路 R5/R4 lane 报告;未动 dev-backend*.sh/pkill/后端;8080 全程健康未触发轮询;camoufox 全程 --session f09r5l2(中途浏览器自身崩溃 2 次,重启同会话);数据仅动 f09r5l2* 前缀 + f01e2e 名下由本 lane 创建并已报告的 3 个 base。
