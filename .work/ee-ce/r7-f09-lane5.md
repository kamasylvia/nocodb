# R7 F09 lane5 报告（安全审计重点路）

## 结论：**1 error（blocker）+ 0 minor**（另有 3 条观察项，不计 error/minor）

**E1（blocker，5a11c4ab86 引入）：`CreateNewSync.vue` `loadTables` 重复声明 → SFC 编译失败 → :3000 整个 base 页不可用，R7-A/B 与 R6-C 全部 UI 验证腿无法执行。**

- 位置：`packages/nc-gui/components/project/Action/CreateNewSync.vue:18` 与 `:76`
- 5a11c4ab86 diff 仅 +1 行：L18 `const { loadTables } = useBase()`；而文件既有本地向导函数 L76 `const loadTables = async (baseId: string) => {...}`（选源 base 后拉源表清单用，L159 `watch(selectedBaseId, (id) => { if (id) loadTables(id) })` 真实调用）。`<script setup>` 同作用域两个 `const loadTables` → 重复词法声明。
- 实锤证据（Nuxt dev server 日志 `/tmp/f09r7l5-nuxt-dev.log`，重启后全新进程同样报错）：
  ```
  ERROR Internal server error: [vue/compiler-sfc] Identifier 'loadTables' has already been declared. (76:6)
  File: .../components/project/Action/CreateNewSync.vue:76:6
  ```
- 运行时表现：打开任意 base 页（Overview → ProjectActionCreateNewSync 静态导入链）即 `error loading dynamically imported module: .../CreateNewSync.vue?t=...` → Nuxt 错误页（"Go back home"）。camoufox 会话 f09r7l5 实测两次深链 + 硬刷新均复现。curl 该模块 URL = 404，同目录其余组件（CreateNewDocument/Node/SyncMenuOptions/SyncStatusBadge/Overview/SharePage）全部 200 → 单文件回归。
- 注意：commit message 自述 "Verified: HMR compiles clean" 不成立——旧 :3000 进程（9/17 00:58 起）持有旧编译产物掩盖了错误，R6 五路 UI 测试大概率测的是旧模块。
- 建议修法（未动码，本路只读）：L18 改名解构（如 `const { loadTables: reloadBaseTables } = useBase()`，L138 同步改名）或 L76 本地函数改名 `loadSourceTables`（两处调用语义本就不同：store 版无参刷目标树，本地版带 baseId 拉源表）。
- 质量门缺口观察：`tsc --noEmit` 不编译 .vue，jest Fork 桶纯后端——现有质量门抓不到 SFC 语法错（见观察 O3）。

---

## 逐项证据（8 项清单 + R7/R6 增量）

### 1. diff 审查 — PASS
- F09 改动面 = 16 文件（71896a841f 起至 HEAD 5a11c4ab86），与 f09-p1-impl-report 清单一致；R3-R6 修复批均在列。
- 后端 4 新文件 `[CE-EE]` 标记计数：TableSync.ts 1 / table-syncs.service.ts 10 / table-syncs.controller.ts 2 / table-sync.processor.ts 4；noco.module.ts 17 / jobs.module.ts 2 / jobs-map.service.ts 3。
- 禁改文件零 F09 触碰：`store/sync.ts`（最后上游 i18n 提交）、`utils/syncUtils.ts`、`utils/acl.ts`（nc-gui，无提交）、`utils/ncUtils.ts` 均非 F09 提交（backend acl.ts 改动属 F02，不属 F09）。
- `isSyncFeatureEnabled` 恒 false（store/sync.ts:19 `ref(false)`）。

### 2. 引擎审查（table-sync.processor.ts）— PASS
- RemoteId 键控 upsert：源 pk 值串键（extractPksValues），existing map upsert，消失行按 on_delete_action 双策略（delete→bulkDelete / mark_deleted→RemoteDeleted=true）；重复 remoteId 去重。
- 分页 500/页（SYNC_PAGE_SIZE），dest 与源双向分页。
- 白名单通道仅引擎内部：`engineWriteParams`（allowSystemColumn+skip_hooks+skipPermissionCheck+skipAttachmentOwnershipCheck）为 processor 局部常量；全 controllers/services 目录 grep 无任何 HTTP 路径转发这些 flag（bulk-data-alias/data-table 的 internalFlags 为服务内上游机制，无外部注入点）。
- 失败落 status=error+last_error，成功 active+last_synced_at（e2e 实测，见 §5）。

### 3. 服务审查 — PASS（含平台谓词逐字对照）
- assertSourceReadAccess（table-syncs.service.ts:91-141）与平台谓词对照（BaseUser.ts:540-631 baseList SQL + User.getWithRoles:602-706）：
  - 显式 base 角色 ∉ {no_access, no-access, inherit} → 放行 = SQL 分支 1（whereNotNull ∧ != NO_ACCESS ∧ != INHERIT ∧ != 'inherit'）✓
  - base 行 null/''/inherit ∧ ws 角色 ≠ no-access ∧ 非私有 → 放行 = SQL 分支 2 + F08 私有子句 ✓（本 fork ws 表仅六合法角色，`workspace-level-inherit` 不可经 API 写入——workspace-users.service 白名单排除，故 service 的 wsNoAccess 只排除 no-access 与平台 WorkspaceRolesToProjectRoles 映射行为等价，无可达 fail-open）
  - 显式 no_access → 无条件 404 = getWithRoles 私有短路语义（dd46a3eb1d E1 修复）✓
  - 无 base 行 → 404 ✓（BaseUser.get innerJoin WORKSPACE_USER，无 ws 行时 raw=null 亦拒）
  - 拼写差异：legacy 'no_access'（下划线）平台 SQL 视为显式角色放行、F09 双拼写均拒 → fail-closed 多拒，沿袭 R6-D 非缺陷。
- allow_sync 强制：resolveSourceView :190-204（显式 viewId 或首个 allow_sync grid，无则 400）✓
- 镜像列过滤 isMirrorableSourceColumn（virtual/pk/system 9 类 uidt/attachment/deleted 排除）✓；保留名守卫 :341-382 ✓；realtime API 400 :325-329 ✓；system:true 后置补丁 + list 键缓存失效 :498-525 ✓

### 4. ACL 矩阵（API 实测，非 super）— PASS
owner/creator 十端点过 ACL（不存在 syncId 返服务层 404，非 403）；editor/viewer **403 ×10**；匿名 **401 ×10**；零关系用户对 dest 十端点 **403 ×10**（无任何 200 泄露）。十端点 = list/get/sourceSchema/create/update/delete/resync/freeze/resume/resolve-link(501)。

### 5. 引擎 e2e（API 实测）— PASS
- full-create：镜像 3 行，RemoteId=["1","2","3"]，titles=[row1,row2,row3]，status active ✓
- resync upsert：源 +row4 → 镜像 4 行，RemoteId="4" ✓
- on_delete=delete：源删 row4 → resync → 镜像回 3 行 ✓
- on_delete=mark_deleted：第二 sync，源删 row3 → resync → 行保留 RemoteDeleted=true ✓
- freeze=200 / paused resync=**400** / resume=200 → active ✓
- deleteSync=200 → GET 404，镜像表出 live 列表（trash 语义，沿袭轮已验）✓
- realtime=400（付费锁保持）✓

### 6. 守卫链 + 系统列 — PASS
- editor/owner 对 synced 镜像表 insert 全 **400**（"readonly column cannot be updated"——镜像列全 readonly）✓
- RemoteId/RemoteDeleted：meta system=true + readonly=true；网格列 DB 实测 `nc_grid_view_columns_v2.show=f`（show=false + system=true 双保险，R2 E2 修复保持）✓
- allow_sync 开到镜像 grid view → **400** "Allow sync cannot be enabled on a synced table"（同步环防护）✓

### 7. UI 段（camoufox --session f09r7l5）— **BLOCKED by E1**
- base 页无法加载（E1 编译错）→ R7-A 创建流树刷新、R7-B 删除流三腿、R6-C M1 可搜索选择器、M2 菜单 open-watch 新鲜度、editor 三入口 UI 可见性、console 双零——全部无法执行。非 E3（有明确产品根因即 E1）。
- API 层等效覆盖：editor createSync/读源 schema 均不可达（403 ×10，fail-closed 保持，无泄露通道）。

### 8. 回归 + 质量门 — PASS
- F02：field permission create（RECORD_FIELD_EDIT + granted_type=user + subjects）= **200**；list 200 ✓
- F03：table permission create（TABLE_VISIBILITY）= **200** ✓
- F04：syncs（legacy SyncSource/Airtable）list = **200**（/api/v2 与 /api/v1 双路由）✓
- F05：base variables list = **200** ✓
- F07：snapshots list = **200** ✓
- F08：is_private base 创建 + 回读 `is_private:true` ✓
- F10：dashboards list = **200** ✓
- 质量门：`tsc --noEmit` **exit 0**；jest Fork 桶全绿（table-syncs.Fork.spec **15/15**，全桶 exit 0）。⚠️ 注意 tsc 不覆盖 .vue（E1 漏网根因，见 O3）。

---

## R7-A / R7-B / R6 增量判定

| 腿 | 判定 | 依据 |
|---|---|---|
| R7-A 创建流树刷新（5a11c4ab86 修复点 1） | **无法验证 — 该修复本身不可编译（E1）** | 代码意图正确（L138 `await loadTables()` 调 store 版，store/base.ts:154 存在），但与 L76 撞名致整个组件编译失败 |
| R7-B 删除流自动跳转（修复点 2） | 代码审查 PASS / 运行时无法验证（页面不可达） | SyncMenuOptions.vue:60-83 先捕 `oldActiveTableId` 再 remove，剩余表腿 openTable(remaining[0])、根腿 navigateTo(baseUrl)、非当前表不跳（oldActiveTableId≠id 短路）三腿逻辑齐；该组件可编译（curl 200），但页面被 CreateNewSync 连带挂掉 |
| R6-A E1 六格矩阵 | 全 PASS（API 实测两轮） | A1 非私有+noacc+wscreator F09=404/平台=403；A2 404/403；A3 404/404；A4 404/404；A5 createSync=404 且 dest 表数 0→0、syncs=0（数据面不落镜像）|
| R6-B 四象限重跑 | 全 PASS（两轮复跑一致） | B1 200/200；B2 200/200；B3 F09=404/平台=403（404 vs 403 = 沿袭 fail-closed 语义差）；B4 inherit 200/200；B5 404/404；B6 404/404 |

## 安全审计专项（本路重点）

1. **谓词象限对照**：service 三路判定与平台 SQL/getWithRoles 十格（R6-A 六格 + R6-B 六格重叠）逐格实测一致；唯一拼写分叉（legacy 'no_access'）为 fail-closed 方向。
2. **绕路面枚举**：
   - 通用 jobs API：jobs-meta.controller 仅 jobList；JobsController 仅 /jobs/listen（polling，带 owner 校验）——**无任意入队端点**，引擎入口收敛于 createSync/resync 两个 creator+ ACL 端点 ✓
   - resolveLink = 501（paste 模式无凭证面）✓
   - TableSync.getAny（processor 内）仅由 enqueueSyncJob 的服务内 job data 触达，无外部 syncId 注入面 ✓
   - sourceSchema 对源 base 的全部读路径都过 loadSource→assertSourceReadAccess（含 dest=source 自镜像 400 拒绝）✓
   - 镜像表不可作为源（views.service :309-318 + 实测 400）→ 无链式同步环 ✓
3. **createSync→引擎数据面**：createSync 时点校验源读权 + allow_sync；引擎 ignoreRls 在本 fork **无权限面可绕**（BaseModelSqlv2.resolveRlsConditions CE no-op，"CE: no-op, no RLS"，src/ee 不存在）——F03 权限走 permission 守卫链非行级过滤，且 synced 表拒配权限（permissions.service :49/:98）。resync 不复检源权限 = 沿袭 P2 灰区（R6-D），未升级。
4. **白名单通道**：allowSystemColumn/skipPermissionCheck 等仅存在于 processor 内部参数对象，HTTP 层 grep 无转发点。

## 观察项（不计 error/minor）

- O1：`getSync/listSyncs` 响应 mappings 含源 base/table/view id——dest creator 可见他人建 sync 的源标识（仅 id，非数据）；EE 同构语义，P2 可加源侧可见性过滤。
- O2：`workspace-level-inherit` ws 角色在 F09 wsNoAccess 判定中会放行而平台映射为拒——当前白名单不可写入该值，纯理论分叉；建议随 P2 对齐 `wsRoles.every(r => ![no-access, inherit].includes(r))`。
- O3：质量门缺口——tsc --noEmit 不编译 .vue（E1 漏网）；建议补 vue-tsc 或构建期 compile check 进质量门（LESSONS 候选）。

## 环境留痕

- 基线 HEAD = 5a11c4ab86；:8080 全程健康（200，未做任何重启）；:3000 因 E1 模块 404 报错页——经一次**前端同服务重启**（§8.2 同种进程，旧 pid 59078 → 新进程，同 NODE_ENV=development、cwd packages/nc-gui，日志 /tmp/f09r7l5-nuxt-dev.log）后错误依旧，从而坐实 E1 为源码缺陷而非进程状态；重启也使其他 lane 后续 UI 测试能拿到真实编译错误而非旧缓存模块。
- 曾 touch CreateNewSync.vue/Overview.vue 触发 watcher（md5 前后一致 1f84e314…/1bd3d70d…，git diff 空，内容零改动）。
- 测试数据：全部 `f09r7l5-` 前缀；**dev 库 live 残留 = 0 base / 0 table sync**（实测 count=0）；camoufox 会话 f09r7l5 已 close；psql 仅连 nocodb-dev 只读查询（未提权、未写库）。
- 凭证零落盘（DB 密码每次经 `ps eww` 运行时现取，不入任何文件）。

**报告完 — lane5（f09r7l5），R7 F09。结论：1 error（E1 blocker，修复腿本身不可编译，UI 全腿阻断）+ 0 minor；API 面（安全矩阵/ACL/引擎 e2e/守卫链/回归探针/质量门）全绿。**
