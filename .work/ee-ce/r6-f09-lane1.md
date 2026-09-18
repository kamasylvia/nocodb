# F09 R6 复审报告 — lane 1（独立审查）

> 审查基线：HEAD = aabe3587fe（R5 minors 修复批）+ dd46a3eb1d（后端 R5 修复）。:8080 / :3000 均含全部修复，未做任何构建/重启。
> 方法：只读代码复审 + 独立 API 集成测试（curl，非 super 账号）+ camoufox 专属 session `f09r6l1` UI 实测。测试数据前缀 `f09r6l1-*`，测试 base 已全部删除。

## 结论：**1 error + 1 minor**（其余全过）

| # | 级别 | 位置 | 问题 |
|---|---|---|---|
| E-1 | **error** | `packages/nc-gui/components/project/Action/CreateNewSync.vue:134` | `useBases().loadTables()` 调用不存在的方法（basesStore 无此导出）→ 创建成功后抛 TypeError：用户看到**错误 toast**（"(intermediate value)().loadTables is not a function"）+ 树不刷新（新 synced 表不可见，需手动刷新）。与 R5 minors 已修的 SyncMenuOptions.onDelete 同款缺陷，修复时遗漏 create 路径 |
| M-1 | minor | `packages/nc-gui/components/dashboard/TreeView/Table/SyncMenuOptions.vue` onDelete | 删除当前正打开的 synced 表后**未自动跳转**剩余首表：`activeTable.value?.id === props.table.id` 在 `loadTables()` 之后才比较，此时 store 已不含被删表 → activeTable=undefined → 条件恒 false → 画布留空白壳 + URL 残留死路径。上游 DlgTableDelete（dlg/Table/Delete.vue:51/110）先捕获 `oldActiveTableId` 再删——顺序缺陷，非上游怪癖 |

## 逐项证据

### 项1 diff 审查 — PASS
- 71896a841f = 16 文件，与 f09-p1-impl-report 清单一致；后续修复批 c051bfa3db/798e860dd1/f81e24a4f4/dd46a3eb1d（后端 service）/aabe3587fe（前端 4 文件）。
- 后端 7 文件 `[CE-EE] F09` 标记计数：TableSync.ts=1 / service=10 / controller=2 / processor=4 / noco.module=4 / jobs.module=2 / jobs-map=3（含 R1 m1 的 ×3 在位）。
- `store/sync.ts`、`utils/syncUtils.ts`、`utils/acl.ts`、`utils/ncUtils.ts` 对 71896a841f^ 零 diff；`isSyncFeatureEnabled` 恒 false（store/sync.ts:19）。
- console.debug 残留：0（service/向导/菜单/composable 四处 grep 空）。
- gate 状态：blockTableSync=false（useEeConfig.ts:163），blockTableSyncAuto=true、blockCustomSync=true（:165/:167）——付费锁保持。

### 项2 引擎审查（table-sync.processor.ts）— PASS
- RemoteId 键控 upsert：`extractPksValues` → existingByRemoteId Map → inserts/updates 分流；重现行清 RemoteDeleted（:213-215）。
- 分页 500/页：源读与 dest 读均 offset 循环、`rows.length < SYNC_PAGE_SIZE` 终止（:156-171/:186-227）。
- 白名单通道引擎内封闭：`allowSystemColumn/skipPermissionCheck/skip_hooks` 仅 processor 构造（:232-238）；HTTP 路径实测仍 4xx（见项6）。
- 失败落账：catch → status=error + last_error（:71-81）；paused 跳过（:53-56）；main mapping 缺失抛不可恢复态（:94-98）。

### 项3 服务审查 + R5 谓词回归 — PASS
- `assertSourceReadAccess`（service:91-141）与平台谓词（BaseUser.ts workspace 分支）逐格对照一致：显式 base 角色排除 no_access/'no-access'/inherit；私有 base 仅走显式角色；非私有 fallback ws 角色（`workspace-level-no-access` 拒）。legacy `'no_access'` 下划线多拒 = D 沿袭 fail-closed，不另计。
- allow_sync 强制：resolveSourceView 无合格视图 400（:198-204）；镜像列过滤 isMirrorableSourceColumn（virtual/pk/system/attachment/deleted 排除）；保留名守卫（:341-382）；realtime 400（:325-329）；resolveLink 501（:777-779）；system:true 后置补丁 + GridViewColumn show=false + COLUMN:list PARENT_TO_CHILD 缓存失效（:470-525）。

### 项4 ACL 矩阵（API 实测）— 6/6 PASS
owner/creator(b1) 十端点全 200（resolve-link 501 除外）；editor/viewer/零关系用户(x1) 十端点全 403（rlink 403=ACL 先拒，语义正确）；匿名 401。私有源 base 十端点无泄露（B5/B6/A3/A4 均 404）。
脚本：/tmp/f09r6l1-acl3.sh；矩阵输出逐码在案。

### R6-A E1 六格矩阵（dd46a3eb1d 回归）— 5 格 + 对照全 PASS
| 格 | source-schema | 平台 GET base |
|---|---|---|
| 非私有+显式no-access+ws-creator (a1) | **404** ✓ | 403 ✓ |
| 非私有+显式no-access+ws no-access (a2) | **404** ✓ | 403 ✓ |
| 私有+显式no-access+ws可读 (a3) | **404** ✓ | 404 ✓ |
| 私有+显式no-access+ws no-access (a4) | **404** ✓ | 404 ✓ |
| 非私有+显式no-access→createSync (a1) | **404** ✓ 且 dest 表数不变（数据面零镜像）✓ | — |

### R6-B R5 四象限重跑（f81e24a4f4 不破）— 6/6 PASS
非私有+零行+ws-creator=200；非私有+显式editor+ws no-access=200；非私有+零关系+ws no-access=404；非私有+inherit+ws-creator=200；私有+零行+ws可读=404；私有+inherit+ws no-access=404。正例 body 校验：view.allow_sync=true、columns=2。
脚本：/tmp/f09r6l1-matrix.sh；16/16 PASS。

### 项5 引擎 e2e — PASS
- full-create：3 行镜像 RemoteId 逐一对照（`1:row1:1,2:row2:2,3:row3:3` + RemoteDeleted=false）。
- resync upsert：源改 row1→row1b/11、增 row4 → 镜像 `1:row1b:11,2:row2:2,3:row3:3,4:row4:4`；删 row3（delete 策略）→ 镜像移除；删 row5（mark_deleted 策略，独立 sync）→ 镜像保留 `5:row5:True`。
- freeze→resync 400→double freeze 400→resume→active；resume while active 400。
- updateSync：title/on_delete 200；selected_fields 变更 400；realtime 触发 400；resolve-link 501。
- selectedFields 子集：镜像无 Qty 列；未知字段 400。
- deleteSync：200 → GET 404 → 表离开 tables 清单（trash 语义，trash 无公开 REST 端点，UI 树移除已另证）。

### 项6 守卫链 + 系统列 — PASS
- editor insert/update/bulkInsert 400；delete 422 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`（上游 prohibitedSyncTableOperation 定义 422，守卫真实生效——R3 任务书「全 400」措辞差异，非回归）。
- owner 列 update 400（"Synced fields cannot be modified directly"）/ 列 delete 400（"is a synced column and cannot be deleted"）；synced 表 DELETE 400。
- 系统列：meta `system=true, readonly=true`；v3 view columns `RemoteId/RemoteDeleted show=false`（Title/Qty show=true）。UI 网格实测仅见 Title/Qty（截图 f09r6l1-open-table.png）。

### 项7 + R6-C UI 段（camoufox session f09r6l1）— 见 E-1/M-1，其余 PASS
- 向导三步 Body 内 Back/Next/Create 按钮渲染可用（R2 修复保持）；Next 未选表前 disabled 正确。
- **M1 可搜索选择器 PASS**：base 下拉输入 `r6l1-src` → 仅剩 f09r6l1-srcpub 匹配项；table 下拉输入 `r6l1_src` → 命中过滤；键盘选中通路正常。
- 向导 create（owner）：服务端成功（sync tss5i7gramoh9mjvv + 镜像 mmn1d2ylg6dsecj synced=true），**但错误 toast + 树不刷新 → E-1**（截图 /tmp/f09r6l1-after-create.png 实锤：绿「Create sync」+ 红「(intermediate value)().loadTables is not a function」并存，侧栏缺新表）。
- **M2 新鲜度 PASS**：Sync now 后不刷新重开菜单 → 状态「Synced table」+ Pause 项恢复（不再卡 Syncing）；freeze→重开=Paused+Resume sync；resume→重开=Synced table+Pause sync。
- **M2 删除流 PASS（除 M-1）**：Delete sync 确认后树即时移除（不刷新页面）、无 TypeError；但正打开该表时无自动跳转 → M-1。
- editor 三入口：Overview「NocoDB Sync」卡**不可见** ✓；树菜单（引擎态 gate）渲染但全部动作 API 403 fail-closed（十端点矩阵）；SharePage allow_sync 通道 editor PATCH 403 fail-closed ✓。无 editor 泄露通道。
- console error/Nuxt overlay：console hook 捕获 0（create 的 TypeError 走 catch+toast，不进 console；E-1 的 UI 证据为 toast 截图）。

### 项8 回归 + 质量门 — PASS
- 探针（owner，DEST base）：F02/F03 permissions list 200、F05 variables 200、F07 snapshots 200、F10 dashboards create/list 200、F04 legacy syncs meta 200、镜像表 records 读 200。8/8。
- **tsc --noEmit exit 0**（packages/nocodb）。
- **jest Fork 桶 41/41**（3 suites，含 table-syncs.Fork.spec 15 项引擎单测）。

## D 沿袭项核验（未升级，不计）
selectedFields:[] 空数组、createSync 非原子孤儿表、resync 不复检源权限、404 vs 平台 403 语义差、legacy 'no_access' 多拒、FAILED 详情泛型、resolve-link 501、realtime 400——均维持 R5 状态。

## 附注
- :3000 会话多次掉登：根源为并行脚本对同一账号反复 signin 触发 token_version 轮换（非 F09 缺陷，dev 环境行为）；改用专属账号 f09r6l1-ui 后稳定。
- 环境残留：f09r6l1-* 测试账号 16 个留存 dev 库（沿袭 700+ 测试账号惯例）；5 个测试 base 已删（owner 3 + f01e2e 名下 orphan 2，全部 200）。
- camoufox session f09r6l1 已关闭。
- 截图证据：/tmp/f09r6l1-after-create.png（E-1 实锤）、/tmp/f09r6l1-open-table.png（网格系统列隐藏）、/tmp/f09r6l1-delete-confirm.png（删除确认流）。

## 修复建议（供裁决）
- E-1：CreateNewSync.vue:134 `useBases().loadTables()` → `useBase().loadTables()`（SyncMenuOptions 同款用法，一行）。
- M-1：onDelete 在 `remove()` 前先捕获 `const wasActive = activeTable.value?.id === props.table.id`（对齐上游 DlgTableDelete 的 oldActiveTableId 模式）。
