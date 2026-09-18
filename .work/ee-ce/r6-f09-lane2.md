# R6 F09 lane2 复审报告（独立审查员 lane2，账号前缀 f09r6l2-*）

> **结论：1 error + 0 minor**（另 2 条 observation，不计分）。
> 基线：HEAD = aabe3587fe（dd46a3eb1d + R5 minors 修复批），:8080 全修复后端 + :3000 HMR 前端，全程零构建零重启零 pkill。
> camoufox session `f09r6l2` 专属；测试数据全部 `f09r6l2-` 前缀；测试 base 测完已删（5/5 → 200）。

---

## 1. E1 修复回归（R6-A 六格矩阵）——全命中 ✅

`assertSourceReadAccess`（table-syncs.service.ts:91-141）baseNoAccess 短路（'no_access'/'no-access' 双拼写，:121-122）实测：

| 象限 | 用户构成 | F09 source-schema | 平台 GET base | 判定 |
|---|---|---|---|---|
| 非私有+显式 no-access+ws-creator | e1a | **404** | 403 | ✅ |
| 非私有+显式 no-access+ws no-access | e1b | **404** | 403 | ✅ |
| 私有+显式 no-access+ws-creator | e1c | **404** | 404 | ✅ |
| 私有+显式 no-access+ws no-access | e1d | **404** | 404 | ✅ |
| 非私有+显式 no-access → createSync | e1a | **404**（ERR_BASE_NOT_FOUND） | — | ✅ |

createSync 404 后 DEST_E1 表数 0→0、sync 数 0（数据面不落镜像）；补充：q5（私有源+零 base 行+ws 可读）createSync 亦 404、零镜像。错误体统一 `ERR_BASE_NOT_FOUND`。

## 2. R5 四象限重跑（R6-B）——全命中 ✅（f81e24a4f4 回归未破）

| 象限 | 用户 | 实测 | 预期 |
|---|---|---|---|
| 非私有+零 base 行+ws-creator | q1 | 200 | 200 ✅ |
| 非私有+显式 editor+ws no-access | q2 | 200 | 200 ✅ |
| 非私有+零关系+ws no-access | q3 | 404 | 404 ✅ |
| 非私有+inherit+ws-creator | q4 | 200 | 200 ✅ |
| 私有+零 base 行+ws 可读 | q5 | 404 | 404 ✅ |
| 私有+inherit+ws no-access | q6 | 404 | 404 ✅ |

环境矩阵经 DB 侧复核（13 账号 ws/base 角色逐行核对无误）：ws-creator = admin/q1/q4/q5/e1a/e1c，其余 auto no-access；SRC_NP 行 = q2 editor/q4 inherit/e1a e1b no-access；SRC_P(is_private=t) 行 = q6 inherit/e1c e1d no-access；全部矩阵用户持 DEST_E1 显式 creator（保证请求到达源校验层）。

## 3. 八项清单逐项证据

### 清单 1 diff 审查 ✅
- 基提交 71896a841f 16 文件与 f09-p1-impl-report 清单一致；累积 diff（base=2fe80a9716..HEAD）同为 16 文件，无清单外文件。
- 后端 8 文件 [CE-EE] F09 标记全在（TableSync.ts×1、service×10、controller×2、processor×4、noco.module×17、jobs.module×2、jobs-map×3、Fork.spec×6）。R4 增量②jobs-map ×3 复核在位（:15/:34/:97）。
- 零改动文件实测 UNCHANGED：nc-gui/store/sync.ts、utils/syncUtils.ts、utils/acl.ts、utils/ncUtils.ts（isEeUI=false :1）、后端 src/utils/acl.ts。
- `isSyncFeatureEnabled` 恒 false（store/sync.ts:19）；blockTableSyncAuto/blockCustomSync 保持 true（useEeConfig.ts:165/167）——付费锁未松。
- R4 增量③ console.debug ×4 残留：F09 文件 grep 零命中。

### 清单 2 引擎审查 ✅
table-sync.processor.ts：RemoteId 键控 upsert 正确（源 extractPksValues→dest RemoteId map，:153-227）；源/镜像双向分页 500/页（SYNC_PAGE_SIZE=27 行处，offset 循环 <size break）；白名单通道仅引擎内部（engineWriteParams :232-238 = allowSystemColumn+skipPermissionCheck+skipAttachmentOwnershipCheck+skip_hooks，HTTP 层不可达，e2e 编辑器写路径 400 佐证）；失败落账实测：删源表→resync→`status=error` + `last_error="Source table has been deleted — delete this sync and recreate it"`，且 error 态允许 deleteSync 收尾（200）。Paused job 直接 skip（:53-56）。

### 清单 3 服务审查 ✅
- R5 重写谓词与平台 BaseUser 列表 SQL（BaseUser.ts:563-631）逐路径对齐：显式角色≠no_access/no-access/inherit→读；空/inherit→ws 继承（非私有）；显式 no_access→无条件拒；私有仅路径 1。角色常量核对：ProjectRoles.NO_ACCESS='no-access'（enums.ts:40）、WorkspaceUserRoles.NO_ACCESS='workspace-level-no-access'（:50）——服务双拼写检查覆盖。
- allow_sync 强制（resolveSourceView :190-204）；镜像列过滤（isMirrorableSourceColumn 排 virtual/pk/系统 uidt/Attachment/Deleted）；保留名守卫（:341-382 含 tableCreate 系统列 + RemoteId/RemoteDeleted 双拼写）；realtime 400（:325-329）；system:true 后置补丁（:498-517）+ 网格 show=false（:474-490）+ R2 缓存键修复（:521-525，PARENT_TO_CHILD list 键）。

### 清单 4 ACL 矩阵 ✅（API 实测，非 super）
十端点 × owner/creator=200（resolve-link=501 除外）、editor/viewer=全 403（含 resume 403 补测）、anonymous=401×4 抽样：
```
PASS 1 list / 2 get / 3 source-schema / 4 create / 5 update / 6 delete / 7 resync / 8 freeze / 9+9b resume: o=200 c=200 e=403 v=403
PASS 10 resolve-link: o=501 c=501 e=403 v=403
PASS anon list/resync/source-schema/resolve-link = 401
```
注：为使 creator 的 createSync 200 路径可达，给 creator 加了 SRC_NP 显式 viewer（仅此一处额外授权，测后随 base 删除）。R2 E1「无关系用户对私有源十端点不泄露」由 §1 矩阵覆盖（404 优先于 ACL 面板语义，fail-closed）。

### 清单 5 引擎 e2e ✅
full-create（3 行镜像、RemoteId=1,2,3、RemoteDeleted=false）→ resync upsert（源 PATCH row2 Qty=22 → 镜像 22；新增 row4 入镜像）→ on_delete 双策略（delete：删源 row1→镜像消失；mark_deleted：RemoteDeleted=true 且行保留；PATCH 切换策略后 resync 按新策略执行）→ freeze（paused+resync 400）→ resume（active）→ updateSync（title/on_delete 200、selected_fields 400）→ realtime createSync 400（付费锁保持）→ deleteSync（get 404；镜像表随平台 tableDelete 语义移除——本平台表级删除为 meta 硬删，migration nc_202606121400 注释明言 synced 表不过 trash，非 fork 偏差）。

### 清单 6 守卫链 + 系统列 ✅
editor 对 synced 表：insert 400、bulkUpdate 400/403、bulkDelete 403、updateSync 403、tableDelete 400、form view 创建 422（ERR_SYNC_TABLE_OPERATION_PROHIBITED "Form view creation is not supported for synced table"——守卫生效，上游错误码即 422）；viewer 读记录 200（只读语义正确）。RemoteId/RemoteDeleted：columns.system=true + readonly=true + 网格 GVC show=false（双保险，R1/R2 修复维持）；editor 网格同样不可见（UI 截图 22-editor-dest.png：仅 Title/Qty）。

### 清单 7 UI 段（camoufox session f09r6l2）——1 error
- **向导三步**：step0 Browse+base/table 选择器、step1 View+Fields to sync、step2 title+删除策略，Back/Next/Create 全部在 body 渲染且可用（Back 后 step0 选择保留）；Create 实际建成（API 复核 f09r6l2_uiA status=active）。✅
- **M1 可搜索选择器**：base 下拉输入 `srcnp`→过滤命中 f09r6l2-srcnp（截图 08）；table 下拉输入 `tnp`→仅命中 f09r6l2_tnp；键盘输入+Enter 选取成功。✅
- **M2 树菜单新鲜度**：Sync now 后**不刷新页面**重开菜单→状态行 "Synced table" + Pause 恢复（非 Syncing 卡死）；Pause→重开→Resume sync 出现；Resume→重开→Pause 恢复。✅（`open` prop watch + loading 占位生效）
- **M2 删除流**：Delete sync 确认后（无刷新）树中该表**即时消失**（旧 `useBases().loadTables()` TypeError 已修，`useBase().loadTables` 真实存在 store/base.ts:154/337）；localStorage/近期视图状态无已删表残留。**但「当前正打开该表视图→自动跳转」未发生**（两次复现：f09r6l2_uiA、f09r6l2_syncD），URL 停在已删表视图路径、画布空网格 + 残留 Data/Details tabs，无错误页。→ **error E-l2-1**，见 §5。
- **editor 三入口**：树节点菜单无任何 sync 项（菜单体不渲染 sync 段）；Share 按钮=升级弹窗（无 share 弹窗，allow_sync 不可见）；无向导入口/base 首页 Data Actions 不可达。API 侧（ACL 矩阵）editor 全端点 403 闭环——零成功通道。✅
- **console error 与 Nuxt overlay 双零**：error/unhandledrejection hook 挂钩后交互扫描 `errs:[]`、`overlay:false`。✅

### 清单 8 回归 + 质量门 ✅
- 探针（admin token 实测）：F02 permissions 200、F03 POST permissions{} 400（synced 守卫活）、F04 legacy syncs 200（AirtableImport 走同一 syncSourceList 通道，不回归）、F05 variables 200、F07 snapshots 200、F08 私有 base owner GET 200、F10 dashboards 200。
- **tsc：`npx tsc --noEmit` exit 0**。
- **jest Fork 桶：3 suites / 41/41 passed**（"db exploded" 为失败路径用例的预期日志）。

## 4. 沿袭已知项确认（未升级）
selectedFields:[] 空数组、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限、FAILED 详情泛型、resolve-link 501、realtime 400——均维持原状，未观察到恶化。

## 5. Error 详情

### E-l2-1【R6-C3 部分修复不完整】SyncMenuOptions onDelete 自动跳转分支为死代码
- 位置：`packages/nc-gui/components/dashboard/TreeView/Table/SyncMenuOptions.vue:55-76`
- 根因：onDelete 顺序为 `remove()`(:57) → `removeFromRecentViews`(:63) → `removeMeta`(:64) → `await loadTables()`(:65) → **之后**才判 `activeTable.value?.id === props.table.id`(:66)。loadTables 已把被删表从 tablesStore.baseTables 移除，而 activeTable（store/tables.ts:38-47）是在**已刷新列表**里按 route.params.viewId find → 必然 undefined → 条件恒 false → `openTable(remaining[0])`(:71) 与 `navigateTo(baseUrl)`(:73) 均不可达。
- 平台对照：DlgTableDelete（`dlg/Table/Delete.vue`）在删除前先捕获 `const oldActiveTableId = activeTable.value?.id`（:51），删除后比较 `oldActiveTableId === toBeDeletedTable.id`(:110) → 平台删除当前打开表会正确跳转，F09 版不会。
- 运行时复现 ×2（uiA、syncD，均先打开该表视图再菜单 Delete sync 确认）：树即时消失（loadTables 本身生效）、recent/meta 清理已执行（:63-64 在 loadTables 前无条件运行）；URL 停留 `/nc/<ws>/<base>/<已删tableId>/<viewId>/...`，画布空白网格 + 失效 "Data/Details" tabs，无自动跳到剩余首表（syncD_1）亦未回 base 根。
- 影响：删除 sync 后停留死视图，需手动点击其他表恢复；无数据风险、无 console error、无 overlay。按任务书 C3 明确预期（"自动跳到剩余首表（或 base 根）"）判 error（修复不完整）。
- 修复建议：`const oldActiveTableId = activeTable.value?.id` 提到 :57 `remove()` 之前，:66 改为 `if (oldActiveTableId === props.table.id)`，其余不动（与 DlgTableDelete 同构）。

## 6. Observations（不计分）
1. **paused 态菜单仍渲染可点 "Sync now"**（模板 :93 仅在 Syncing 隐藏；Paused 不隐藏）——点击得 400 "Sync is paused. Resume it before syncing"（fail-closed，无数据风险）；产品语义或应隐藏/禁用，与 R6-C3 的"菜单项翻转"验收无冲突（Pause↔Resume 翻转已验证）。
2. **深链直接打开 base URL 卡树骨架**：`/nc/<ws>/<base>` 直开/刷新时树区 22 个 skeleton 长挂（无 XHR 发出、无 JS error、无 overlay），SPA 内从 workspace 首页点击进入则正常——框架级行为，F09 十六文件不含路由/树加载路径；本轮 UI 验证全部改由 SPA 点击导航完成。

## 7. 红线与留痕
- 只读审查：仓库源码零修改（git status 仅 .work 流程文件）；只写 /tmp/f09r6l2/ 脚本与截图 + 本报告。
- 未动 dev-backend*.sh / pkill / 后端进程；8080/3000 全程在线（3000 绑 IPv6 [::1]，用 localhost 访问）。
- DB 访问（Infisical KDL 拉凭证，host=qnap.elf-balance.ts.net，库名硬编码 nocodb-dev）：仅两类写动作——① 本 lane 自建账号 f09r6l2-admin 的 org 角色置 org-level-creator、② 其 workspace_user 行置 workspace-level-creator（均等效 invite API 结果、非 super 提权、不绕过 enforcement，与实例既有 f01e2e=org-level-creator 同构；红线"严禁 psql 提全局 super"未触碰）；其余全部角色变更走真实 API（ws invitations / base users invite）。上述 setup 动作列此供 orchestrator 审计。
- UI/API 同账号 token_version 互踢为实例已知行为，全部实测以单一通道为准（API 侧在 UI 测试段后重取 token）。
- 清理：5 个测试 base（dest/srcnp/srcp/dest-e1/probe3）DELETE 全 200；13 个 f09r6l2-* 账号留存于 dev 库（沿用历轮惯例）。
- 截图与脚本：/tmp/f09r6l2/shots/*.png（01-24）、/tmp/f09r6l2/{setup,e1-quadrants,e2e,e2e-b,e2e-c,acl}.sh、state.env。
