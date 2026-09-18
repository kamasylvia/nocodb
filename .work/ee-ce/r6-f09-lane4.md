# R6 F09 lane 4（UI 重点路）复审报告

**结论：1 error + 1 minor（其余全项 PASS；质量门 tsc exit 0 + jest Fork 桶 41/41）**

> 审查基线：HEAD = aabe3587fe（R5 minors 前端修复）+ dd46a3eb1d（E1 后端修复），与任务书一致。
> 后端 :8080 / 前端 :3000 全程未动（仅轮询健康，从未重启）；camoufox session `f09r6l4` 专属，测完已 close。
> 测试数据全部 `f09r6l4-*` 前缀；4 个测试 base（srcA/srcB/srcP/destD + 501probe）测完已删（API DELETE 200 ×5，余量 0）。

---

## E1（error，1 例）：删除当前打开表的「自动跳转」未生效（R5 删除流修复不完整）

**现象**（浏览器实测，无刷新）：
- 删除当前正打开网格视图的 synced 表（tbl_b 镜像）后：
  - 树中该表**即时消失** ✓（R5 修复的核心目标达成）
  - sync 记录删除、dest 表清单移除、API 侧状态一致 ✓
  - **但 URL 停留在已删表路由**（`/nc/<base>/<已删tableId>/<viewId>/...`，>10s 不变），主区渲染**空白网格**，未跳到剩余首表（f09r6l4-sync-main）也未回 base 根。截图 `16-delete-confirm-modal.png`（删除前，tbl_b 视图打开 + 确认弹窗）→ `17-after-delete.png`（删除后：树已无 tbl_b + 空白网格 + URL 未变）。

**根因**（代码定位，`packages/nc-gui/components/dashboard/TreeView/Table/SyncMenuOptions.vue:55-76`）：
- onDelete 在 `await remove()` + `await loadTables()` **之后**才判 `activeTable.value?.id === props.table.id`。
- 参照实现 `packages/nc-gui/components/dlg/Table/Delete.vue:48-51` 在删除前捕获 `oldActiveTableId`，注释明言：**"As when table is deleted, activeTable is set to null"**——`activeTable` 是 computed（`store/tables.ts:37-49`，经 `loadProjectTables(force=true)` 重算 baseTables 后 find 不中 → undefined），删除后比较恒 false → openTable/navigateTo 分支为死代码。
- 即 R5 minors（aabe3587fe）照抄了 DlgTableDelete 的清理调用（removeFromRecentViews/removeMeta/loadTables），**漏抄了最关键的 oldActiveTableId 先捕获模式**。

**修复建议**：onDelete 开头 `const oldActiveTableId = activeTable.value?.id`，删除后改判 `oldActiveTableId === props.table.id`，跳转用 `baseTables.value.get(...)` 过滤后 openTable(remaining[0]) 或 navigateTo(baseUrl(...))（照抄 DlgTableDelete:117-133）。

**不计入**：核心删除流（登记行删除、镜像表下树、数据一致性）完好；数据零丢失；这是跳转子项失败，但 R6 任务书 C3 明确列出「自动跳到剩余首表（或 base 根）」为预期行为，故按 error 报告，请 orchestrator 裁决。

## m1（minor，1 例）：向导创建成功后树不刷新——`useBases().loadTables()` 不存在（P1 起残留）

- `packages/nc-gui/components/project/Action/CreateNewSync.vue:134`：创建成功后调 `useBases().loadTables()`。全仓唯一 `useBases` 定义在 `store/bases.ts:9`，**无 loadTables 导出**（loadTables 在 `store/base.ts:154` 的 useBase 上）→ 运行时 TypeError，被 createSync 的 try/catch 吞掉（message.error toast）→ 树不刷新。
- 实测：UI 向导创建 srcB 同步（向导三步 Back/Next/Create 全在 body、成功关闭）；API 侧 sync + 镜像表（synced:true）立即存在；但树在 reload 前一直不显示新表（截图 `08-after-ui-create.png` 树缺新表 → reload 后 `09-grid-readonly.png` 双表齐）。
- 与 R5 删除流修复的是**同一 bug 类残留**（SyncMenuOptions.vue:59 修复注释原话 "useBases() has no loadTables (the earlier call threw and the tree never refreshed)"）；git log -L 证实该行自 P1（71896a841f）就有。修复 = 改调 `useBase().loadTables()`（或 `tablesStore.loadProjectTables`）。
- 不计 error 理由：后端与数据完好，仅前端刷新缺失，reload 即见；与 R5 已裁 minor 同级。

---

## 逐项证据（8 项清单 + R6 增量 A/B/C）

### 1. diff 审查 — PASS
- `git diff 71896a841f~1..HEAD --stat`：16 文件，与 f09-p1-impl-report 清单一致（4 后端新文件 + 3 注册文件 + spec + 7 前端）。
- [CE-EE] F09 标记：TableSync.ts ×1、table-syncs.service.ts ×10、controller ×2、processor ×4、jobs-map ×3（R4 回归项在位）。
- 零改动文件确认：`store/sync.ts` / `syncUtils.ts` / `utils/acl.ts` / `utils/ncUtils.ts` diff 为空；`isSyncFeatureEnabled = ref(false)`（store/sync.ts:19）。
- console.debug ×4 残留清除（R4 回归）：F09 四个前端文件 grep 零命中。

### 2. 引擎审查（源码 + :8080 实跑）— PASS
- processor：RemoteId 键控 upsert；SYNC_PAGE_SIZE=500 分页读源（ignoreViewFilterAndSort+ignoreRls）；写入通道 allowSystemColumn+skipPermissionCheck（引擎内部）；失败落 status=error+last_error（src 读码确认）。
- 实跑（destD←srcA，API）：full-create 3 行 RemoteId 1/2/3 全对照；resync 后 row4(RemoteId=4) 插入 + row1 Qty=100 全字段刷新传播；freeze→paused（resync 400）→resume→active；on_delete_action=delete：源删行→镜像删行 ✓；=mark_deleted：源删行→镜像留行 RemoteDeleted=true ✓（`Title=row3b, RemoteId=5, RemoteDeleted=true`）；updateSync 双向切换策略均 200。
- realtime trigger → 400（付费锁保持）；selected_fields 变更 → 400（P2 已知）；resolve-link → 501（已知）。

### 3. 服务审查 — PASS
- assertSourceReadAccess（dd46a3eb1d 版）源码审查：baseNoAccess 短路（'no_access'/'NO_ACCESS' 双拼写）+ is_private 分流 + ws 继承三路逻辑与平台谓词（BaseUser.ts:563-631）镜像一致。
- allow_sync 强制（无开关视图 400）、镜像列过滤（virtual/pk/system/attachment/deleted 排除）、保留名守卫（RemoteId/RemoteDeleted 等撞名 400）源码在位。
- 镜像表实测列：Title/Qty readonly:true system:false；RemoteId/RemoteDeleted readonly:true + **system:true**（R2 E2 双保险在位）；`__nc_deleted` 等 Engine 列 system:true。

### 4. ACL 矩阵（API 实测，非 super 账号）— PASS
owner（creator+）对八端点全 200；editor/viewer 全 403；匿名全 401：

| op | owner | editor | viewer | anon |
|---|---|---|---|---|
| list/get/sourceSchema/create/resync/freeze/resume/update | 200×8 | 403×8 | 403×8 | 401×8 |
| delete（无效 id 探针） | 404 | 403/401 同列 | — | 401 |

- 无关系用户对源 base 十端点：C1-C5 格全部 404（见下）；ResolveLink 501（实跑确认）。

### 5. E1 六格矩阵（R6 增量 A）— 全部符合预期，PASS

| 格 | 设置 | F09 source-schema | 平台 GET base | 判定 |
|---|---|---|---|---|
| C1 | 非私有+显式 no-access+ws-creator(wsc) | **404** BASE_NOT_FOUND | 403 | ✓（E1 修复点） |
| C2 | 非私有+显式 no-access+ws-no-access(wsna) | **404** | 403 | ✓ |
| C3 | 私有+显式 no-access+ws-creator(wsc) | **404** | 404 | ✓ |
| C4 | 私有+显式 no-access+ws-no-access(wsna) | **404** | 404 | ✓ |
| C5 | 非私有+显式 no-access→createSync(wsc/wsna) | **404** | — | ✓ 且 dest 表数 0（数据面不落镜像） |

### 6. R5 四象限重跑（R6 增量 B）— 全部符合预期，PASS（f81e24a4f4 回归不破）

| 象限 | 实测 | 判定 |
|---|---|---|
| 非私有+零 base 行+ws-creator(wsc→srcB) | 200 | ✓ |
| 非私有+显式 editor+ws-no-access(bedit→srcA) | 200 | ✓ |
| 非私有+零关系+ws-no-access(zero→srcA) | 404 | ✓ |
| 非私有+inherit+ws-creator(wsc→srcB patch inherit) | 200 | ✓ |
| 私有+零 base 行+ws-creator(wsc→srcP) | 404 | ✓ |
| 私有+inherit+ws-no-access(wsna→srcP) | 404 | ✓ |

- 方法注：ws-no-access 用户先给 dest base 显式 creator，排除 dest 侧 ACL（creator+）先行 403 干扰，确保测的是源读判定（首轮实测曾现 403-先行，修正后全矩阵干净）。

### 7. UI 段（camoufox 重点，全部截图证据在 /tmp/f09r6l4/shots/）— M1/M2a/M2b PASS，M2c 见 E1

| # | 项 | 结果 | 证据 |
|---|---|---|---|
| M1 | 向导 step0 base 下拉输入 `f09r6l4-srcB` → 过滤命中唯一项 | PASS | `03-m1-base-search.png`（输入+唯一候选同框） |
| M1 | table 下拉输入 `tbl_b` → 过滤命中 | PASS | `05-m1-table-search.png` |
| 向导 | 三步 Back/Next/Create sync 按钮在 body 且可用（R2 E1 回归） | PASS | `06-wizard-step2-fields.png`、`07-wizard-step3-create.png`；UI 创建成功（API 复核 sync+镜像表存在） |
| M2 | 树菜单新鲜度：Sync now 后**不刷新页面**重开菜单 → 状态 active（非卡 Syncing）+ Pause 项在 | PASS | `11-sync-menu-active.png` → `12-menu-after-syncnow.png`；API 复核 last_synced_at=23:56:36 刚更新 |
| M2 | freeze 后重开菜单 → Paused + Resume 项翻转 | PASS | `13-menu-paused-resume.png`（Paused+Resume+Delete 同框）；API 复核 paused |
| M2 | resume 后重开菜单 → Synced table + Pause 项翻回 | PASS | `14-menu-resumed.png`；API 复核 active |
| M2 | 删除流：树即时消失 | PASS | `16`→`17`（树 tbl_b 即时消失，无刷新） |
| M2 | 删除流：自动跳转 | **FAIL → E1** | `17-after-delete.png`（URL 停留已删表 + 空白网格） |
| M2 | 近期视图清理 | PASS(代码级) | removeFromRecentViews 在 onDelete 调用链；本版本工作区首页无 Recent views UI 区块（`18-home-recents.png`），无可断言的可见泄露 |
| 守卫 | 编辑者三入口 | 无泄露 | Overview Sync 卡仅在空态渲染（0 命中）；editor 树节点 options 下拉未露 sync 菜单项（`20-editor-sync-menu.png`）；且 editor API 十端点全 403（上表）——无成功 createSync/读 schema 通道 |
| 系统列 | RemoteId/RemoteDeleted 网格+Fields 面板不可见（R2 E2 回归） | PASS | `09-grid-readonly.png`（仅 Title/Qty+New record disabled）；Fields 面板快照 grep RemoteId/RemoteDeleted = 0 命中（`10-fields-panel.png`） |
| console | Nuxt overlay | 双零 | 两次 eval `nuxt-overlay:false`；全程 20 张截图无错误浮层。注：UI 段两度弹回登录页系**测试方法自扰**（lane 自己的 curl signin 递增 token_version 踢掉浏览器会话），非产品缺陷 |

### 8. 回归 + 质量门 — PASS

| 探针 | 结果 |
|---|---|
| F02 permissions GET | 200 |
| F03 synced 表配 table permission | 400（拒配守卫生效） |
| F04 AirtableImport | `components/import/` 目录跨全部 F09 commit **零 diff**；`store/sync.ts`/`syncUtils.ts` 零改动 |
| F05 variables GET | 200 |
| F07 snapshots GET | 200 |
| F08 私有 base is_private | true（owner 视角保真） |
| F10 dashboards GET | 200 |
| tsc --noEmit | **exit 0** |
| jest Fork 桶 | **3 suites / 41 tests 全过，exit 0**（table-syncs.Fork.spec PASS + uniqueConstraintHelpers + baseVariableValidators） |

## 沿袭已知项核对（D 清单，未升级，不计）
selected_fields:[] 空数组、createSync 非原子孤儿表、resync 不复检源读权限（P2 灰区）、404 vs 403 语义差（fail-closed 方向）、FAILED 详情泛型、resolve-link 501（本轮实跑复核 501）、realtime 400（付费锁保持）——全部维持原状，无升级。

## 环境留痕
- :8080/:3000 全程健康（8080 每次探测 401 快速响应；一次前端 Network Error 弹回为测试自扰，已复现归因，产品无恙）。
- 未执行 dev-backend*.sh / pkill / psql / 任何构建重启；camoufox `f09r6l4` 会话已 close。
- 测试 base ×5 全删（含 501probe）；f09r6l4-* 测试账号按惯例留存 dev 库。
- 截图 20 张：/tmp/f09r6l4/shots/01-20*.png；测试脚本与状态：/tmp/f09r6l4/。
