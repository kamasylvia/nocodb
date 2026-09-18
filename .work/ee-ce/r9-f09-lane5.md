# F09 R9 — lane 5（UI 验证重点路）报告

**结论：PASS（0 error + 0 minor）**

- 审查基线：HEAD = 5e3d736b2a（R8 修复批：SyncMenuOptions storeToRefs），与任务书一致。
- R9 重点（删除流自动跳转回归）三腿 + 双判别对照全部 camoufox 活体验证通过，R8 发现的两腿死代码确认已修复。
- 测试数据 `f09r9l5-` 前缀，测试 base 全部删除（residual: NONE），camoufox 会话 `f09r9l5` 已关闭。
- UI 账号（f09r9l5-ui-own / f09r9l5-ui-ed）与 API 账号（f09r9l5-api-*）分离。

---

## A. R9 重点：删除流自动跳转回归（5e3d736b2a 修复验证，camoufox 活体）

静态先行：`packages/nc-gui/components/dashboard/TreeView/Table/SyncMenuOptions.vue:30-32` 现为 `const tablesStore = useTablesStore(); const { baseTables, activeTable } = storeToRefs(tablesStore); const { openTable } = tablesStore`——state 经 storeToRefs、actions 裸解构，与上游 `packages/nc-gui/components/dlg/Table/Delete.vue:23-24` 模式完全一致。`onDelete`（L61-86）先捕获 `activeTable.value?.id` 再 `remove()`，随后 removeFromRecentViews → removeMeta → loadTables → 按捕获 id 命中两腿分支。

### 腿 1：剩余表腿（删当前打开 synced 表，base 内还有其它表）— PASS

- 场景：ui-dest base（keep1/keep2 两张普通表 + UI 向导创建的 synced 表 uid_src_tbl），打开 synced 表 grid 后从树菜单 Delete sync → 确认。
- 删除前 URL：`/nc/py9ulab415n6p3l/mmajcpee66growe/vwwlq9w6x3sn6sd2/uid_src_tbl-uid_src_tbl`
- 删除后 URL：`/nc/py9ulab415n6p3l/mp88e6v9n31kxl8/vw4l00fxhv039brb/uid_keep1-uid_keep1`（**剩余首表 keep1 的 grid**）
- 树即时只剩 `uid_keep1 / uid_keep2`；主区网格可见，`document.title = "uid_keep1 | uid_keep1 | f09r9l5-uid-dest"`（URL 与主区一致，无空白网格/死 tabs）。
- 截图：`/tmp/f09r9l5-shots/09-synced-grid-before-delete.png`、`10-leg1-after-delete.png`

### 腿 2：base 根腿（删至 0 表）— PASS

- 场景：ui-zero base（uid_zero_init 普通表 + API 建 synced 表 f09r9l5-leg2；先经判别对照 2 删掉 init 表），打开 synced 表 grid 后树菜单 Delete sync → 确认。
- 删除后 URL：`/nc/pb86uydxkzefprx`（**归一 base 根**，无 stale table 路径）
- 树 0 表；主区显示 base 空状态页（Create New Table / Import / NocoDB Sync / Connect External 卡片正常渲染）。
- 截图：`/tmp/f09r9l5-shots/14-leg2-zero-url.png`

### 腿 3：非当前表腿（删非当前打开表）— PASS

- 场景：ui-dest 当前打开 keep1 grid，树中 API 建的 synced 表 f09r9l5-leg3（sync id tsssb2ofds2fz89jg）从树菜单删除。
- 删除前后 URL 均为 `/nc/py9ulab415n6p3l/mp88e6v9n31kxl8/vw4l00fxhv039brb/uid_keep1-uid_keep1`（**不跳转**）
- 树即时移除（只剩 uid_keep1），主区 title 不变。
- 截图：`/tmp/f09r9l5-shots/12-leg3-after-delete.png`

### 判别对照（DlgTableDelete 路径与 F09 删除流行为一致）— PASS ×2

- 对照 1（剩余表腿同场景）：ui-dest 打开 keep2 → 树菜单 Delete table（上游 TableDeleteDialog 确认框「Delete Table」按钮）→ URL 跳到剩余首表 keep1 grid，树即时移除。与腿 1 行为一致。截图：`11-control-dlgdelete-keep2.png`
- 对照 2（删普通表后剩 synced 表）：ui-zero 打开 init 表 → Delete table → URL 跳到剩余表（synced 表 f09r9l5-leg2 的 grid `/nc/pb86uydxkzefprx/mz4cujgibqzzevo/.../f09r9l5-leg2-f09r9l5-leg2`）。跳转语义与 F09 一致。截图：`13-control2-zero-jump-to-synced.png`

**R8 lane5 发现的两腿死代码（URL 停死）确认修复，lane1 minor1（0 表 URL 未归根）同根同修确认关闭。**

---

## B. R8/R6 站位回归（全继承项，活体）

1. **创建流树刷新** — PASS。Overview「NocoDB Sync」卡片 → 向导三步（Browse → 源 schema → Sync settings）→ Create sync 后**不刷新页面**：树即时出现 `nc-tbl-side-node-uid_src_tbl`，对话框关闭，成功/错误 toast 零并存。API 侧（浏览器 token 打 :8080）确认 sync `uid_src_tbl:active:delete`。截图：`06-after-create-tree.png`
2. **可搜索选择器** — PASS。step0 base 下拉输入 `f09r9l5-uid-src` → 选项从全量过滤到 1 条命中；table 下拉输入 `uid_src` 命中目标表，Next 由 disabled 转 enabled。截图：`02-wizard-step0.png`、`03-wizard-step0-filled.png`
3. **树菜单新鲜度（三态翻转）** — PASS。Sync now 后不刷新重开菜单：状态 `Synced table` + Pause 项恢复（非 Syncing 卡住）；freeze 后重开：`Paused` + `Resume sync` 项（截图 `08-sync-menu-paused.png`）；resume 后重开：`Synced table` + Pause 项。open prop watch 重拉生效。
4. **editor 三入口 fail-closed** — PASS（全部不可见，无泄露通道）。以 f09r9l5-ui-ed（ui-dest editor）实测：① Overview 创建卡片 `proj-view-btn__create-new-sync` 不在 DOM；② 树 synced 表 context menu 打开后无任何 sync 管理项（Sync now/Pause/Resume/Delete sync 均缺省）；③ settings 抽屉无 `proj-view-tab__syncs` tab。API 侧 editor 对 create/source-schema 均 403（见 D 段）。
5. **系统列网格不可见** — PASS。synced 表（f09r9l5-syscol，3 行镜像数据）网格列头仅 Title/Qty，整页文本无 `RemoteId`/`RemoteDeleted` 字样；API 元数据 `RemoteId/RemoteDeleted = show:false + system:true` 双保险（见 E 段）。截图：`15-syscol-grid-hidden.png`
6. **console error 与 Nuxt overlay 双零** — PASS。探针覆盖两表导航 + 菜单操作：`consoleErrors: []`、`vite-error-overlay: false`。

---

## C. R9 附录 B：编译健康先行门 — PASS

- `GET /_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` → 200
- `GET /_nuxt/components/project/Action/CreateNewSync.vue` → 200
- base 页 / 表页多轮导航均无 vite-error-overlay、无动态模块加载错误。

## D. ACL 十端点 + E1 六格矩阵 + R5 象限 — PASS（25/25）

API 实测（非 super 账号；矩阵账号 dest 侧 creator 提权到达服务层，符合 R9 附录 D 方法学注记）：

**十端点（owner）**：list/get/source-schema/create/update/freeze/resume/resync/delete = 200，resolve-link = 501（沿袭已知）。editor 对 list+create 403；viewer 403；匿名 401。

**E1 六格（显式 base no_access，source-schema + 平台 GET base 对照）**：

| 格 | 组合 | F09 | 平台 | 判定 |
|---|---|---|---|---|
| m1 | 非私有 + no-access + ws-creator | 404 | 403 | PASS |
| m2 | 非私有 + no-access + ws-no-access | 404 | 403 | PASS |
| m3 | 私有 + no-access + ws-creator | 404 | 404 | PASS |
| m4 | 私有 + no-access + ws-no-access | 404 | 404 | PASS |
| m5 | 非私有 + no-access → createSync | 404 | — | PASS（镜像表数据面 0 落库） |

**R5 象限（source-schema）**：q1 非私有+零行+ws-creator=200；q2 非私有+editor+ws-no-access=200；q3 非私有+零关系+ws-no-access=404；q4 非私有+inherit+ws-creator=200；q5 私有+零行+ws-creator=404；q6 私有+inherit+ws-no-access=404。全 PASS，dd46a3eb1d/f81e24a4f4 回归不破。

## E. 引擎 e2e — PASS（0 error）

- **realtime 拒收**：create `syncTrigger:realtime` → 400（"Only the manual sync trigger is supported"），付费锁保持。
- **full-create**：delete 策略 sync → active；镜像表 3 行 = 源 3 行；行键 `RemoteId` 非空（'1'/'2'/'3'…）。
- **系统列元数据**：镜像表 RemoteId/RemoteDeleted = `show:false, system:true`。
- **resync upsert**：源插 row8 → 镜像 3→4 行（insert）；源 PATCH row5 Qty=100 → resync 后镜像 row5 Qty=100（update，手动复验）。
- **delete 策略**：源删 row8 → resync 后镜像回到 3 行（行消失）。
- **mark_deleted 策略**：源删 row7 → resync 后镜像行保留且 `RemoteDeleted=True`。
- **freeze/resume**：freeze → `paused`；resume → `active`。
- **editor 守卫**：editor 向 synced 表 insert → 400；PATCH 镜像行 → 400（"readonly column"）。写路径全拒。
- **deleteSync**：DELETE → 200，sync 从 list 消失，镜像表从 base 树移除（trash 语义）。

方法学注记（不影响判定）：本轮初期 5 个 ERROR 系测试脚本误用 `PATCH/DELETE /records/:rowId`（该仓 v2 路由为 body 式 `/records`）及 records meta 路径（404 fallback）造成的假阳性，经手动逐项复验全部排除，无一属实； ACL 矩阵首轮 403 系 dest 侧角色不足（editor 到不了服务层），按附录 D 用 dest-creator 提权后全过。角色变更后存在服务端角色缓存，须经 API PATCH（baseUserUpdate）触发失效——SQL 直改角色不失效缓存，历轮若遇同象限 403 可比照排查。

## F. 质量门

- **后端 tsc**：exit 0（`/tmp/f09r9l5-tsc.log`）
- **jest Fork 桶**：3 suites / **41/41 passed**，exit 0（`/tmp/f09r9l5-jest.log`）
- **前端编译健康（附录 B Vite URL 法）**：两个 F09 SFC 均 200，base 页无 overlay（见 C 段）

## G. 红线自检

- 只读审查：未修改任何仓库源码；只写 /tmp 脚本与报告。
- 隔离：未读任何其它 lane 报告。
- 未触碰 dev-backend*.sh / pkill / 后端进程；8080/3000 全程健康（首查 200，无轮询需要）。
- psql/SQL 仅用于自建测试账号的 workspace 角色置位（等效 invite API，红线明示允许）；未提全局 super。
- 测试数据全 `f09r9l5-` 前缀；3 个 API base + 3 个 UI base 测完删除，列表核实 residual: NONE。

## H. 沿袭已知项确认（未升级，不计发现）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台 fail-closed、legacy 'no_access' 多拒、FAILED 泛型、resolve-link 501、realtime 400 付费锁、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）、source-schema 对无 allow_sync 视图 200（create 侧强制，灰区）——均保持已知形态，无升级。
