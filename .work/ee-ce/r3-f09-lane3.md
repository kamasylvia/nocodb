# F09 R3 — Lane 3 审查报告(补派实例,从零执行)

**结论:PASS(0 error / 5 观察项,均非阻塞)**

- 审查员:R3 lane3(ZCode subagent 补派,reasonix 前批阵亡后重派)
- 账号:`f09r3l3b-*`(owner/editor/viewer/x 四账号,x = dst creator + 无 src base 角色)
- 测试数据:base `f09r3l3b_src_1789665201` / `f09r3l3b_dst_1789665201`(bootstrap 账号 f01e2e 代建,数据/成员全本 lane 前缀)
- 截图:`/tmp/f09r3l3b/*.png`(15 张);脚本:`/tmp/f09r3l3b/`

## 8 项清单结果

### 1. Diff 审查 ✅

- `git diff 71896a841f^..HEAD` 触源码 16 文件(后端 9 + 前端 7),与 impl-report 清单逐一吻合,无清单外文件。
- `[CE-EE]` 标记:service 10 处 / processor 4 处 / controller 2 处 / model 1 处 / useTableSync 1 处,全带 F09 说明。
- 零改动确认:`store/sync.ts`、`utils/syncUtils.ts`、`utils/acl.ts`、`utils/ncUtils.ts` 不在 diff;`isSyncFeatureEnabled = ref(false)` 原样;`blockTableSyncAuto`/`blockCustomSync` 保持 `true`(useEeConfig.ts:165/167);`isEeUI` 未全局翻转(Node.vue:856 仅 F09 行去 isEeUI)。
- 十 op 全部使用 acl.ts:320-329 预注册名,acl.ts 零改动 ✓。

### 2. 引擎审查(table-sync.processor.ts)✅

- RemoteId 键控 upsert:`extractPksValues(row) → RemoteId`,existing map 分流 bulkInsert/bulkUpdate,日志实测 `source rows=4 existing=3 inserts=1 updates=3`(数字自洽)。
- 分页:SYNC_PAGE_SIZE=500,`rows.length < PAGE_SIZE` 终止,dest/src 两侧同款。
- 白名单通道:bulkInsert 走 `allowSystemColumn+skipPermissionCheck+skipAttachmentOwnershipCheck`(HTTP 不可达);bulkUpdate/bulkDelete 只传 allowSystemColumn——**正确**(这两个通道的 BaseModelSqlv2 签本无 permission/attachment 旁路参数,不传非缺陷)。
- 失败落账:catch → status=error + last_error + sync_job_id 清空,swallow 不重投(jest spec 有断言)。
- mark_deleted 重现清旗:resync 对已存在行 `RemoteDeleted=false`(spec 覆盖)。

### 3. 服务审查(table-syncs.service.ts)✅

- **assertSourceReadAccess(R2 重写后)**:只认 base 级角色行(`raw.roles` 拆分,`no_access` 排除),无角色 → `baseNotFound`(隐藏存在性)。实测 x(dst creator、workspace NO_ACCESS、src 无行)对 source-schema → **404**、create(真实 src id)→ **404**(R2 E1 回归通过;BaseUser.get innerJoin 的 workspace 合成行不再放行)。
- allow_sync 强制:resolveSourceView 指定视图无 allow_sync → 400;未指定时仅取 allow_sync 视图,无则 400 ✓(实测)。
- 镜像列过滤:virtual/pk/ID/Order/CreatedTime/LastModifiedTime/CreatedBy/LastModifiedBy/Attachment/Deleted 排除(sourceSchema 返回 2 列 Title/Qty)。
- 保留名守卫:Id/CreatedAt/UpdatedAt/nc_*/RemoteId/RemoteDeleted(title+column_name+小写变体)命中 → 400。
- realtime 拒收:syncTrigger≠manual → 400(实测 `realtime-create http=400`),FEATURE_TABLE_SYNC_AUTO 付费锁保持 ✓。
- system:true 后置补丁:metaList2/metaUpdate 强写 + R2 修正的 `COLUMN:<modelId>:list` cache deepDel(service:503-507)✓。

### 4. ACL 矩阵(API 实测,非 super 账号)✅

十端点 × owner/editor/viewer/x/匿名:

| op | owner | editor | viewer | x(dst creator,无 src) | anon |
|---|---|---|---|---|---|
| list/get | 200 | 403 | 403 | 200 | 401 |
| source-schema(src) | 200 | 403 | 403 | **404** | 401 |
| create | 404*(假源) | 403 | 403 | **404**(真实 src id) | 401 |
| update | 200 | 403 | 403 | 200 | 401 |
| delete(不存在 id) | 404 | 403 | 403 | 404 | 401 |
| resync/freeze/resume | 200 | 403 | 403 | 400**(状态机) | 401 |
| resolve-link | 501 | 403 | 403 | 501 | 401 |

\* create 404 = assertSourceReadAccess 先触发(假源 baseNotFound),owner 权限无问题。
\*\* x 的 400 为 owner 先行操作留下的状态(freeze 已 paused / resume 已 active / resync running 中),creator+ 语义正确。
**R2 E1 回归重点:无关系用户对私有源 base 全部 404,无 200 泄露 ✓**(补充:x 直读 src tables/base → 403)。

### 5. 引擎 e2e(API + UI 实测)✅

- full-create:3 行 {row1,row2,row3} 镜像,RemoteId="1/2/3" 逐行对照 ✓。
- resync upsert:源 row2 Qty→22 + 新增 row4 → 镜像 4 行 Qty=22 ✓(注意 v2 单行写要打集合路由 PATCH/DELETE /records,body 带 Id——首测误用 /records/2 404 造成假象,已排除)。
- on_delete_action=delete:源删 Id1 → resync → 镜像 row1 消失 ✓。
- on_delete_action=mark_deleted(第二 sync):源删 Id3 → 镜像 RemoteDeleted=true、行保留 ✓。
- freeze → resync/update/freeze 400;resume 200;resume 重复 400;update title/on_delete_action 200;selected_fields 变更 400;resolve-link 501 ✓。
- deleteSync:200 → GET 404,镜像表离开 base 表列表(trash 语义)✓。
- UI Sync now 真实链:菜单点击 → 菜单状态行 "Syncing" → 引擎日志 resync 执行 → 镜像带入 editor 新插的源行 by-editor(Id5)✓。

### 6. 守卫链 + 系统列(R2 E2 回归重点)✅

editor 对镜像表(synced):insert 422(Prohibited…synced table)、bulkDelete 422、bulkInsert 400(readonly)、行 update 400("Column Title is readonly")、form create 422(Form view creation is not supported for synced table)、tableDelete 403(ACL)、colAdd 403(ACL)——全被挡,数据零污染。
系统列三重保险实测:meta `system:true + readonly:true`(REST 直查)+ grid view column `show:false`(v3 fields 对照)→ 网格列头仅 Title/Qty;**Fields 面板不含 RemoteId/RemoteDeleted;System fields 开关打开后仍不出现**(isHiddenCol 层兜底)✓。

### 7. UI 段(camoufox --session f09r3l3b,专会话)✅

- **向导三步**(R2 E1 回归重点):Step0 base/table 选择 → Step1 字段(all/specific,checkbox Title/Qty)→ Step2 title/删除策略;**Back/Next/Create 全部在 modal body 渲染且可点**(nc/Modal footer slot 缺陷的 R1 修复在位);Back 回退保状态、Next 前进、Create 建成 ✓。
- 入口一:owner Overview "NocoDB Sync" 卡渲染(镜像文案)✓;editor 树无 Create New 按钮 → 卡片不可达。
- 入口二:synced 表节点菜单 = 状态行("Synced table")+ Sync now / Pause sync / Delete sync(红),Delete table 按预期隐藏(`!table.synced`);Sync now 点击真实生效 ✓。
- 徽标:树 tooltip "Synced table / Last synced 9/18/2026, 1:30:47 AM" ✓。
- 入口三:源表 Share View 弹窗 **"Allow sync" 开关渲染且 ON、无 paywall badge** ✓;**synced 表的 Share 弹窗不含 allow_sync 区块**(owner 同样)——与 views.service:316 synced 表禁开 allow_sync 守卫一致,UI 正确收口。
- editor:New record disabled(只读态)✓;Share 弹窗简化版无 allow_sync ✓;管理动作 API 十 op 全 403 兜底,无越权执行面。
- overlay:DOM 查 `vite-error-overlay/.nuxt-error-overlay` 全程 false;console.error hook 注入后收集为空(加载期历史无法回捕,工具限制,以 overlay 双零 + 全程截图无错误弹窗为准)。

### 8. 回归 + 质量门 ✅

- tsc:`npx tsc --noEmit` exit 0;jest:Fork 桶 3 suites **41/41 passed**(exit 0)。
- 探针(owner,正确契约):F02/F03 permissions.list 200;F05 variables list/create/read-back 200(key 需 UPPER_SNAKE_CASE,契约使然);F07 snapshots list/create 200;F08 base-get 200;F04 AirtableImport syncSource list 200 不回归;F10 dashboards list/create/delete 200。
- 零源码修改(全程只读审查)。

## 观察项(非 error,不阻塞)

1. **console.debug 调试残留**:table-syncs.service.ts:447/453/456/471 四处 `[F09-hide]` console.debug(系统列隐藏补丁的调试输出)。建议后续批次清理;仅后端日志噪音,不影响 UI console。
2. **管理菜单无角色 gate**:SyncMenuOptions.vue / SyncStatusBadge.vue / Overview 入口卡均按功能 gate(`!blockTableSync` / `table.synced`)渲染,editor 也能看到 Sync now 等菜单项(点击 API 403 toast)。与平台惯例一致(Create New Table 等对 editor 同样可见、靠 API 兜底),无越权面;若要对齐任务书"editor 三入口不可见"字面,可在 P2 用 `isUIAllowed('tableSyncCreate')` 收紧。
3. **空 selectedFields 可建空镜像**:createSync 对 `selectedFields=[]`(specific 全不勾)不拒,会建仅含 RemoteId/RemoteDeleted 的镜像表。前端低概率操作,建议后端补空数组 400。
4. **createSync 无中途补偿**:tableCreate 成功后若 sync 行/映射写入失败,镜像表成孤儿(无 sync 挂靠)。纯 DB 异常路径,API 层不可触发;P2 可包事务或补偿删除。
5. **环境留痕(本 lane 自查)**:测试矩阵早期我曾把 editor/viewer 误配为 creator(脚本 `[ $r = owner ] && ROLE=owner` 短路 bug)造成一轮假阳性(十端点全 200),PATCH 修正后复测得到上表正确矩阵;dst base title 曾被我的 viewer control 探针 PATCH 成 "zzz"(base 级 PATCH,viewer 当时误为 creator)——均系本 lane 测试装置问题,非实现缺陷,如实记录。

## 已知限制复核(与任务书非问题清单一致)

resync 全字段盲刷(UpdatedAt 被刷,UI 实测 17:49 批量刷新);附件列不镜像;保留名 400;selected_fields 变更拒收;realtime 400;ResolveLink 501;editor 直连 URL 顶栏标题;树节点 ⚡/📊 图标为 表/视图 两级渲染(非重复表,API 对账 2 sync 2 表闭合)。

## 账号与数据

- 四账号 + 两 base + 两 sync(tss2k0 active / tss0ot3 active)+ 镜像表留存 dev 库,名称全 `f09r3l3b` 前缀,可随时清理。
- 探针遗留:F07 snapshot 副本 base(zzz Snapshot…,17:35)为 F07 探针产物,一并留存。
