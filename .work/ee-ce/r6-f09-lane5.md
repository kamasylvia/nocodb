# R6 F09 lane5 — 安全审计重点路 报告

**结论：PASS — 0 error，2 minor，3 观察项**（minor 均非功能/安全违规；质量门 tsc 0 + jest 41/41 全过）

审查员：R6 lane5（安全审计）。账号前缀 `f09r6l5-*`，camoufox session `f09r6l5`。HEAD = aabe3587fe（dd46a3eb1d + R5 minors 均在 :8080 / :3000 HMR 生效态）。测试 base 9 个已全部删除，测试账号留存 dev 库（已知项）。

---

## A. E1 修复回归（dd46a3eb1d）— 六格矩阵（API 实测）

矩阵在 :8080 实测，每格 = 平台 `GET /api/v2/meta/bases/:sourceId` + F09 `POST .../table-syncs/source-schema` + `createSync` 对照。actor 的 dest base 权限经显式 invite+patch 授 creator（保证打到 source 断言层而非 dest ACL 层）：

| 格 | 配置 | 平台 | F09 | 判定 |
|---|---|---|---|---|
| C1 | 非私有 + 显式 no-access + ws-creator | 403 | **404** | ✅ E1 修复点生效 |
| C2 | 非私有 + 显式 no-access + ws no-access | 403 | **404** | ✅ |
| C3 | 私有 + 显式 no-access + ws-creator | 404 | **404** | ✅ |
| C4 | 私有 + 显式 no-access + ws no-access | 404 | **404** | ✅ |
| C5 | 非私有 + 显式 no-access → createSync | 403 | **404** | ✅ 数据面未落镜像 |

五格全部符合任务书预期。C2/C4 的 404 来自 `assertSourceReadAccess` path 3（baseNoAccess 短路），与 dest ACL 无关（dest creator 已显式授予）。

## B. R5 四象限重跑（f81e24a4f4 回归不破）— 全部符合

| 格 | 配置 | F09 | 预期 |
|---|---|---|---|
| Q1 | 非私有 + 零 base 行 + ws-creator | 200 | 200 ✅ |
| Q2 | 非私有 + 显式 editor + ws no-access | 200 | 200 ✅ |
| Q3 | 非私有 + 零关系 + ws no-access | 404 | 404 ✅ |
| Q4 | 非私有 + inherit + ws-creator | 200 | 200 ✅ |
| Q5 | 私有 + 零 base 行 + ws-creator | 404 | 404 ✅ |
| Q6 | 私有 + inherit + ws no-access | 404 | 404 ✅ |

## C. 绕路面枚举（安全审计重点）

逐项实测（变体行经 psycopg 直插 `nc_base_users_v2`，先 API 建 row 再 API 删行清缓存后插入，确保 `BaseUser.get` 走活 SQL 而非缓存；DB 只连 `nocodb-dev`，零提权操作）：

| 变体 roles 值 | 平台 GET base | F09 source-schema | 判定 |
|---|---|---|---|
| `'no_access'`（下划线 legacy） | 200 | **404** | F09 多拒 = fail-closed，与 R6 已知项 D 一致，不升级 |
| `' no-access '`（空白填充） | 200 | 200 | **与平台同向**（平台 SQL `!=` 亦不 trim），parity，非新增绕路 |
| `'editor,no-access'`（多角色拼接） | 200 | 200 | 与平台 priority-1 语义一致（exact match 不命中），parity |
| `'NO-ACCESS'`（大写） | —（平台 401 边缘） | 200 | 大小写敏感匹配两侧一致，parity |

**缓存陈旧行**：API 驱动的 revoke（editor → PATCH no-access → 立即 schema）= **404 立即生效**，`updateRoles` 的 `NocoCache.update` 失效正确，无 HTTP 可达的陈旧窗口。带外 SQL UPDATE 不失效缓存（F09 读到陈旧 viewer 放行）——带外写不在 HTTP 威胁模型内，平台侧 `User.getWithRoles` 同款缓存语义，记观察项 O1。

**双拼写核验**：服务端 `baseRole === 'no_access' || baseRole === ProjectRoles.NO_ACCESS`（SDK 枚举 = `'no-access'` 连字符），双拼写均短路，与平台谓词 `BaseUser.ts:563-631` 的 `!= NO_ACCESS` 对照：平台不查下划线拼写（fail-open），F09 多拒一档（fail-closed，方向正确）。

**跨 workspace**：`loadSource` 的 sourceContext 沿用 dest workspace_id，理论可疑；但 `Base.get` → `metaGet2` → `contextCondition` 强制 `fk_workspace_id = ws AND id = baseId`（meta.service.ts:266-291），外来 workspace 的 base 直接 404。且本 fork 无 workspace 创建端点（`createWorkspace` 前端 stub，后端无 REST 路由），跨 ws 源在实践内不可达。fail-closed，无泄露。

**createSync → 引擎数据面**：引擎写入通道 `allowSystemColumn + skipPermissionCheck + skipAttachmentOwnershipCheck`（table-sync.processor.ts:232-238）仅存在于 job processor 内部参数对象，HTTP 层（data-table.controller → BaseModelSqlv2）无任何路径注入这些 flag；`resync` ACL creator+（editor/viewer 实测 403）。resync 不复检源读权限 = 已裁定 P2 灰区，实测确认行为与文档一致（dest creator + 零源关系 resync 200，引擎拉数成功）——沿袭已知项，不重复报。

## D. 其余清单项（R3 任务书 8 项）

1. **diff 审查**：`git log --grep=F09 -- <保护文件>` 零命中——store/sync.ts、syncUtils.ts、acl.ts（前后端）、ncUtils.ts 全部未被 F09 提交触碰；`isSyncFeatureEnabled = ref(false)` 在位（store/sync.ts:19）；`isEeUI = false` 未动（ncUtils.ts:1）；`blockTableSync=false` / `blockTableSyncAuto=true` / `blockCustomSync=true`（useEeConfig.ts:163-167，付费锁保持）。4 个后端新文件 [CE-EE] 标记齐（TableSync.ts ×1、service ×10、controller ×2、processor ×4），jobs-map ×3。
2. **引擎审查**：e2e 全流程实测通过——full-create（3 行镜像含 Qty 值 + RemoteId 1/2/3 + RemoteDeleted=false）→ 源加 row4 resync = 4 行 upsert → on_delete=delete 策略删源行后镜像同步消失 → on_delete=mark_deleted 策略 RemoteDeleted=true → freeze 后 resync 400「Sync is paused」→ resume → active → deleteSync 200，GET 404，dest 表清单只剩非镜像表。分页 500/页 + chunk 200（源码核验）。
3. **服务审查**：allow_sync 强制（resolveSourceView 无 allow_sync 视图即 400）、镜像列过滤（virtual/pk/system/attachment/deleted 排除）、保留名守卫（含双拼写 + column_name 对照）、realtime 400 实测、system:true 后置补丁 + `COLUMN:<modelId>:list` 缓存失效（R2 修正版）均在位。
4. **ACL 矩阵**：creator 对 list 200 / resolve-link 501；editor 十端点全 403；viewer 全 403；匿名 401。creator 对 get/schema/create 的 404 为数据相关正确态（目标 sync 不存在 / 源 base 无读权）。
5. **守卫链 + 系统列**：owner 直插镜像表 → 400 `Column "Title" is readonly`；editor（显式 editor 角色）insert/update → 同款 400；grid 列 show 标志实测 `RemoteId:false, RemoteDeleted:false`（其余列 true）+ `system:true, readonly:true`（E2 回归不破）；UI 树菜单中 Form menuitem **disabled**（synced 表禁建 form 视图在 UI 生效）。
6. **质量门**：`tsc --noEmit` exit 0；jest Fork 桶 **41/41 passed**（3 suites，exit 0）。
7. **回归探针**：F02 permissions list 200；F05 variables 200；F07 snapshots 200；F08 私有 base 行为在矩阵内验证（Q5/Q6/C3/C4）；F10 dashboards 端点 400「title required」= 存活；F04 syncs 200；AirtableImport 200。零 5xx。
8. **R5 minors 源码核验**：M1 = CreateNewSync.vue:201/214 `show-search` + `:filter-option` 双选择器在位；M2 = SyncMenuOptions.vue `open` prop watch（:34-35，每次打开重拉）+ loading 占位行（:84）+ `loadTables()`（store/base.ts:154 定义并导出 :337，旧「不存在的方法」TypeError 根除）+ `openTable(remaining[0])` 自动跳转（:71）。

## E. UI 段（camoufox session f09r6l5 实测）

- **M1 可搜索选择器：live 验证通过**。向导 step0 base 下拉输入 `e_dest` → 2 项过滤为 1 项精确命中；table 下拉同样可输入过滤。且 base 下拉内容权限过滤正确（editor 只见其有权 base，不见他人 base）。
- **向导 + 入口**：admin 与 editor 均可见 Overview「NocoDB Sync」卡并可打开向导；editor Next 无有效选择不放行，API 层创建/schema 全 403（fail-closed）。
- **editor 三入口**：API 十端点全 403 + UI Next disabled + 源列表权限过滤——无可达创建/schema 通道。无泄露。
- **minor m1（环境受限披露）**：M2 的运行时菜单序列（Sync now → 不刷新重开菜单 → 状态新鲜；Delete → 树即时刷新 + 自动跳表）反复被外部因素打断——审查期间 4+ 次会话在登录后 1-3 分钟内被强制登出，其中一次捕获到 :3000 页面字面 `Network Error`（后端瞬时不可达，8080 随即恢复 200）。结合 git 历史 patrol 自动化（94f7bc3cdc「backend restarted」）与 token_version 单会话互踢语义，判定为环境性干扰而非产品缺陷。M2 三处修复已逐行源码核验在位（见上第 8 项），且旧行为的根因（`useBases().loadTables` TypeError）已确认不可能复现。建议主会话在 patrol 静默窗口补一次专用 UI pass。
- **minor m2**：editor 对镜像表行 DELETE 实测 422（insert/update 为 400 readonly 文案）——拒绝形态与写路径不一致，仍为拒收（4xx），无放行；疑为 v2 delete 载荷形态差异所致的错误分支，建议后续统一为 prohibitedSyncTableOperation 文案。不构成违规。

## F. 观察项（不计 minor，供台账）

- O1：带外 SQL 写 base 角色不触发 `BaseUser.get` 缓存失效，F09 与平台同受影响；HTTP 不可达，无实际绕路面。
- O2：`no_access`（下划线）拼写平台谓词 fail-open（priority-1 命中）而 F09 拒——F09 更严，方向正确；若上游后续统一拼写可回填。
- O3：显式 base 角色但无 workspace 行的用户被 F09 拒（`BaseUser.get` innerJoin workspace 行丢弃 → deny）；平台 priority-1 会放行。本 fork 全员自动入默认 workspace，实践不可达；fail-closed 方向，与 404-vs-403 已知语义差同类。

## 红线遵从

零源码修改；零他路报告阅读；零 dev-backend*.sh / pkill / 重启；DB 仅 `nocodb-dev`（psycopg fixture 插入/查询，无提权）；凭证 Infisical 运行时拉取未落盘；测试 base 9/9 已删；脚本均在 /tmp。
