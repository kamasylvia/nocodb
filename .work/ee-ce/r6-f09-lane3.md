# F09 R6 复审报告 — lane 3（f09r6l3）

**结论：1 error + 1 minor**（不判 PASS；其余 8 项清单全过，无泄露、无 fail-open、引擎/ACL/矩阵全绿）

- 基线：HEAD = aabe3587fe（R5 minors）+ dd46a3eb1d（R5 E1），与任务书一致。:8080 含全部修复（未做任何重启/构建）；:3000 HMR 生效。
- 报告落盘：`.work/ee-ce/r6-f09-lane3.md`（未被占，无 -b 后缀）。
- 测试数据：全部 `f09r6l3-` 前缀；39 个测试 base 已全部删除（含历次失败脚本残骸），`jq` 复核 0 残留；camoufox session `f09r6l3` 已关闭。
- 环境干扰记录（非测试结论）：共享 operator 账号 f01e2e 的 signin 会轮换 token_version，并发 lane 反复 signin 导致本 lane 的 API token 与 UI 会话多次被踢——UI 段改用专属账号 f09r6l3-ui（ws-creator）完成。此为环境现象，非产品缺陷。

---

## E1 六格矩阵（dd46a3eb1d 回归）— 全格命中

每格 = source-schema POST + createSync POST（r1/r5）+ 平台 GET base 对照。源 base 分非私有（f09r6l3-src-np）与私有（f09r6l3-src-p，is_private=true API 实证）两棵；探针用户在 DEST base 均挂显式 base creator（隔离 DEST 侧 ACL，只测源读谓词；不影响谓词输入的 ws 角色）。

| 格 | 实测 | 预期 | 判 |
|---|---|---|---|
| 非私有 + 显式 no-access + ws-creator | schema=404 create=404 platform=403 | 404/404/403 | ✅（E1 修复点，ws-creator 不再穿透） |
| 非私有 + 显式 no-access + ws-no-access | schema=404 platform=403 | 404/403 | ✅ |
| 私有 + 显式 no-access + ws-creator | schema=404 platform=404 | 404/404 | ✅ |
| 私有 + 显式 no-access + ws-no-access | schema=404 platform=404 | 404/404 | ✅ |
| 非私有 + 显式 no-access → createSync | 404（dest sync 计数实测保持 0，无镜像落库） | 404 | ✅ |

## R5 四象限重跑（f81e24a4f4 回归不破）— 全格命中

| 格 | 实测 | 预期 | 判 |
|---|---|---|---|
| 非私有 + 零 base 行 + ws-creator | 200 | 200 | ✅ |
| 非私有 + 显式 editor + ws-no-access | 200 | 200 | ✅ |
| 非私有 + 零关系 + ws-no-access | 404 | 404 | ✅ |
| 非私有 + inherit + ws-creator | 200 | 200 | ✅ |
| 私有 + 零 base 行 + ws 可读 | 404（platform=404） | 404 | ✅ |
| 私有 + inherit + ws-no-access | 404 | 404 | ✅ |

谓词字面量核验（代码层）：服务层 `baseRole==='no_access' || baseRole===ProjectRoles.NO_ACCESS`（= 'no-access'，双拼写均拒）；ws 判定用 `workspace-level-no-access`（与 `WorkspaceUserRoles.NO_ACCESS` 枚举一致）；`inherit` 单拼写与枚举一致。私有路径仅放行显式 base 角色，与 `BaseUser.ts:563-631` 平台谓词逐支对齐。

## 8 项清单逐项

### 项1 diff 审查 ✅
- `git diff 71896a841f~1..HEAD --stat` = 16 文件（后端 8 + 前端 8），与实现自述清单一致；新增批 R3-R5 修复均为同文件内迭代，无超范围文件。
- 禁改文件零改动：`store/sync.ts` / `utils/syncUtils.ts` / `src/utils/acl.ts` / `utils/ncUtils.ts` 均不在 diff（acl 十 op 沿用上游注册，acl.ts 零改动实证）。
- `isSyncFeatureEnabled` 恒 false（store/sync.ts:19）；`blockTableSync=false` 仅此一个 gate 解锁，`blockTableSyncAuto`/`blockCustomSync` 保持 true。
- [CE-EE] F09 标记：controller 2 / model 1 / service 10 / processor 4 / jobs-map 3 / jobs.module 2 / noco.module 17——全覆盖。
- `console.debug` 在全部 7 个 F09 文件 0 残留（R4 项 3 回归过）。

### 项2 引擎审查 ✅（table-sync.processor.ts）
- RemoteId 键控 upsert：`extractPksValues(row,true)` → seenRemoteIds 去重 → existing map 命中走 updates（带 dest pk 回填 + mark_deleted 时清 RemoteDeleted），未命中走 inserts。
- 分页 500/页，dest 与 source 双侧循环至 `rows.length < SYNC_PAGE_SIZE`。
- 白名单通道仅引擎内部：`allowSystemColumn` 的 HTTP 面（data-table/bulk-data-alias service）全部经 `param.internalFlags?.allowSystemColumn`，全仓 grep 证实**无任何 controller/调用方设置 internalFlags**（另一合法使用方 at-import 为 Airtable 导入引擎内部，非 HTTP）。
- 失败落账：job catch → status=Error + last_error，成功 → Active + last_synced_at + sync_job_id 清空；Paused 状态 job 启动即跳过。
- on_delete_action 双策略：delete→bulkDelete / mark_deleted→RemoteDeleted=true（引擎 e2e 双向实证，见项5）。

### 项3 服务审查 ✅
- assertSourceReadAccess：见上方矩阵；`BaseUser.get` 的 raw 行读取 roles/workspace_roles 与模型实现一致（BaseUser.ts:171/176）。
- allow_sync 强制：resolveSourceView 对显式 view 无 allow_sync → 400「Source view does not allow sync」；无 view id 时仅挑 allow_sync 的 grid view；UI 实测 allow_sync 关闭的 grid view createSync → 400。
- 镜像列过滤：EXCLUDED_SOURCE_UIDTS（FK/ID/Order/CreatedTime/LastModifiedTime/CreatedBy/LastModifiedBy/Attachment/Deleted）+ isVirtualCol 排除；selected_fields 白名单只认 mirrorable title（schema 实测只出 Title/Qty 两列，Id 等系统列被排）。
- 保留名守卫：reservedNames 含引擎系统列 + table 系统列，冲突 400。
- realtime API 400 拒收（syncTrigger=realtime → 400，付费锁保持）；invalid on_delete_action → 400；同 base 源 → 400。
- system:true 后置补丁 + GridViewColumn show=false（R1 修复在位）+ COLUMN list 缓存 deepDel（R2 修复在位）。

### 项4 ACL 矩阵 ✅（API 实测，专用 dest_acl base）
| 角色 | list | get | schema | create | update | resync | freeze | resume | resolve | delete |
|---|---|---|---|---|---|---|---|---|---|---|
| owner | 200 | 200 | 200 | 200 | 200 | 200 | 400* | 400* | 501 | 200 |
| creator | 200 | 200 | 200 | 200 | 200 | 200 | 400* | 400* | 501 | 200 |
| editor | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 |
| viewer | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 |
| 匿名 | 401 | — | — | — | — | — | — | — | — | — |

\* freeze/resume 的 400 为脚本时序（resync 刚投递、status=syncing 时 pause 被服务层 400 拒——恰为「Syncing 不可 pause」守卫的正面证据；clean 状态下 freeze=200/paused/resume=200 在项5 e2e 全过）。resolve-link=501（P2 预置）符合预期。owner/creator 的 400 另在 UI/引擎段以 clean 状态复核。

### 项5 引擎 e2e ✅（全新 src 表 f09r6l3_t3 + 全新 dest2，UI 账号独立会话无 API 互踩）
1. full-create：3 行镜像，RemoteId={1,2,3}，Title/Qty 值逐行对照一致，RemoteDeleted 全 false，mirror 表 `synced=true`。
2. resync upsert：源改 row1→row1x + 增 row4 → 镜像 row1 变 row1x（按 RemoteId 命中更新）+ row4 插入，共 4 行。
3. delete 策略：删源 row4 → resync → 镜像 row4 消失（sweep），回到 3 行。
4. mark_deleted 策略（第二条 sync）：删源 row5 → resync → row5 保留且 RemoteDeleted=true；再次 resync 无重复行、标记保持。
5. freeze/resume：syncing 中 freeze → 400；paused 时 resync → 400、update → 400；resume → active；对 active sync 再 resume → 400「Sync is not paused」。
6. updateSync：title 200 落库；selected_fields 变更 → 400（P2 锁）。
7. 边界：realtime trigger 400；allow_sync 关闭视图 → 400；不存在视图 → 404；同 base 源 → 400。
8. deleteSync → GET 404；镜像表从 base 表清单消失（trash 统一语义）。

### 项6 守卫链 + 系统列 ✅
- 写路径全拒：insert 镜像表 → 400；bulk insert → 400；删镜像表 → 400；改列名 → 400；建 form view → 422 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`（"Form view creation is not supported for synced table"——守卫命中，仅错误码映射为 422 非任务书简称 400）。
- 系统列双保险（API 层）：meta columns `RemoteId/RemoteDeleted` 均 `system=true` + `readonly=true`；grid view columns 二者 `show=false`（fk_column_id 匹配，R2 修复路径实证）。
- UI 层：网格仅 Title/Qty 两列，RemoteId/RemoteDeleted 不可见；Fields 工具栏无系统列；行内 New record 按钮置灰（只读态自动生效）。

### 项7 UI 段（camoufox --session f09r6l3 专属；账号 f09r6l3-ui，ws-creator）→ **1 error + 1 minor**

✅ 过项：
- **入口一**：空 base 的 Data Actions 面板渲染 "NocoDB Sync" 卡（`proj-view-btn__create-new-sync`），点击开向导。
- **向导三步**：step0 Browse（base/table 双 NcSelect）→ step1 View + 字段（All/Specific radios）→ step2 标题 + 删除策略（Deleted/Retained radios）；**Back/Next/Create sync 三键全程在 dialog body 渲染且可用**（R2 E1 修复保持）。
- **M1 可搜索选择器**：base 下拉键入 "f09r6l3-ui-src" → 过滤至唯一命中（label 正确显示 title）；table 下拉键入 "f09r6l3_ui_t" → 唯一命中。两个 NcSelect 均生效。
- **真实创建**：向导 Create → sync active + 镜像表 synced=true（API 复核 tssa633bue37a5aem / 表 f09r6l3_ui_t）；树上 reload 后出现带同步图标的镜像表。
- **管理菜单（SyncMenuOptions）**：状态行 + Sync now / Pause sync / Resume sync / Delete sync 齐备；synced 表无 Delete-table 项（`!table.synced` 守卫）；无越权 P2 项。
- **M2 树菜单新鲜度**：Sync now → 不刷新页面重开菜单 → 状态 "Synced table"（非卡 Syncing）+ Pause 恢复；Pause → 重开 → "Paused" + Resume；Resume → 重开 → active + Pause。open-prop watch 生效。
- **M2 删除流（主腿）**：Delete sync → 确认弹窗（Cancel/Delete sync 键在 body，R1 修复保持）→ 确认后**不刷新页面**树即时变为 "No tables"（表消失）。
- **入口三（源侧）**：Share 弹窗 "Allow sync" 开关渲染（无付费 badge），点击翻转 true→false→true 生效。
- **console error 与 Nuxt overlay 双零**：全程 hook console.error/error/unhandledrejection 计 0 条；无 vite-error-overlay/nuxt-error-overlay 元素。

❌ **error-1（E-1）创建流树不刷新：`CreateNewSync.vue:134` 调 `useBases().loadTables()`，但该方法只存在于 `useBase`（store/base.ts:154，:337 导出）；`useBases`（store/bases.ts，"todo: merge with base store"）全文 0 处 loadTables。**
- 运行时 = TypeError，且该调用位于 `createSync` 的 try 块内（:119-135）→ 被 `catch` 吞掉 → 用户看到 error toast，树不刷新。
- 实测复现 2/2：向导创建成功（API 确认 sync active + 镜像表存在）后**树持续 "No tables"**，手动 reload 才出现镜像表。
- 溯源：P1 commit 71896a841f 引入；R5 minors（aabe3587fe）修掉了 SyncMenuOptions 里同款不存在的 `useBases().loadTables()`（删除流改用 `useBase` 的正确导出），但**创建流调用点漏修**——同根因残留。修法与删除流同款：改用 `useBase()` 的 `loadTables`（或 `loadTables` 后强刷 base 上下文）。

⚠️ **minor-1（M-1）删除流自动跳转的「base 根」腿未触发**：base 内仅镜像表一张时，Delete sync 确认后树已即时刷新，但 URL 仍停在已删表视图路径，主区渲染残空视图（面包屑 "//"，空 grid 骨架）；代码 `remaining.length===0 → navigateTo(baseUrl(...))` 未生效（疑 `loadTables` 后 `activeTable` 已被清空导致 `if (activeTable.value?.id === props.table.id)` 分支跳过）。恢复手段 = 手动点任意导航，无数据影响。「剩余首表」腿（remaining.length>0 → openTable(remaining[0])）本轮未构造场景实测。

### 项8 回归 + 质量门 ✅
- F02/F03（permissions）、F04（syncs/Airtable SyncSource）、F05（variables）、F07（snapshots）、F10（dashboards）端点探针全 200、响应形状正常。
- F08：is_private=true 的源 base 实存（API GET 实证），私有语义矩阵（上表）全过。
- 质量门：`npx tsc --noEmit` **exit 0**；jest Fork 桶 **41/41 passed**（3 suites；26 基线 + 15 F09 新增）。

---

## 沿袭已知项（本轮未重复计错，符合任务书 D 节）
selectedFields:[] 空数组、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限、拒绝码 404 vs 平台 403 语义差（fail-closed 方向）、FAILED 详情泛型、resolve-link 501（P2）、realtime 400（付费锁保持）。

## 观察项（不判错，供主会话裁量）
1. **fail-closed 边缘**：`assertSourceReadAccess` 依赖 `BaseUser.get`（innerJoin workspace_user）；若某用户仅在某非默认 workspace 的 base 上有显式 base 角色而无该 workspace 成员行，会被 404（平台列表谓词用 leftJoin 会放行）。默认 workspace 邀请流经 `ensureUserInDefaultWorkspace` 兜底，不可达此态；仅非默认 workspace 手工造行可触发，方向 fail-closed。
2. **表单守卫错误码**：synced 表建 form view 返回 422（非 400），任务书「全 400」为简写；守卫本体命中，无需修。
3. **并发环境**：f01e2e signin 轮换 token_version 的互踢现象会被多 lane 并发放大（本 lane UI 段被迫换专属账号）；建议后续轮任务书为 UI 段固定分配独立账号。

## 测试留痕
- 脚本：/tmp/f09r6l3-m1.sh（ACL+矩阵首跑）、/tmp/f09r6l3-m1b.sh（B 相 clean 重跑）、/tmp/f09r6l3-m2.sh/m2b.sh/m2c.sh（引擎 e2e）、/tmp/f09r6l3-*.png（UI 截图：向导过滤、镜像网格、删除后、终态）。
- 输出日志：/tmp/f09r6l3-m1-run.log、m1b-run.log、m2-run.log、m2b-run.log、m2c-run.log；质量门 /tmp/f09r6l3-tsc.log、/tmp/f09r6l3-jest.log。
- 清理：39 个 f09r6l3-* base 全删（含 5 次脚本重试残骸），复核 0 残留；f09r6l3-* 账号（wscreator/wseditor/wsna/basecreator/baseeditor/baseviewer/ui/uicheck/admin）留存于 dev 库（沿袭 dev 库 700+ 测试账号惯例，未计问题）。
