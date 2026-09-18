# F09 P2 R4 — lane 1（R3 修复回归 + 全矩阵站位）报告

**结论：PASS — 0 error + 0 minor**

R3 四项修复（editor 卡 gate / hash 形 URL / 响应凭据剥离 / 漂移日志格式）活体全过，无新违反；P1+P2 全矩阵站位全绿；质量门三件套全绿。R4 连击 3/3 达成条件满足（以他路汇总为准）。

基线 253c3b6ee5（R3 修复批；HEAD=2316318dad 仅 dispatch chore）。审查时间 2026-09-19 凌晨，后端 :8080 = pid 96879 运行 dist（~/.nocodb-run 与仓内 dist size/mtime 同源，mtime 03:00 晚于进程启动 03:51 前构建，P2+R1+R3 特征全命中：sourceInputMode×4 / sharedViewUrl×5 / passwordProtected×7 / bypassSyncedFieldGuard×4 / detach×22 / sourceCreate×6 / extractSharedViewUuid×4 / source_password_hash×4）。

## 0. 环境与账号

- f01e2e@ 仅基建（建 4 base + 邀请），lane 资源全 `f09p2r4l1-` 前缀：SRC（源表 3 列 3 行 + grid view allow_sync + 密码）/ D1（api creator，API 全链）/ D2（ui creator，UI 活体）/ D3（空 base，editor 入口）
- 账号 f09p2r4l1-api / -ui / -e（UI/API 分离）；camoufox session `f09p2r4l1` 专属，已 close
- 环境备忘：:3000 前端监听 localhost(::1) 而非 127.0.0.1（IPv4 curl 不通，浏览器用 `http://localhost:3000` 即可）；后端日志 = /private/tmp/nocodb-internal.log（dev-backend-internal.sh 起法）

## 1. R4-1 editor Overview 卡 —— 过（修复活体）

- **editor 不可见**（`r4-editor-d3-overview.png`）：e 账号开空 base D3，动作面板仅「Data Actions / No actions available」——「NocoDB Sync」卡**不再渲染**（R3 lane5 error 场景消除）；`Overview.vue` gate = `!isMobileMode && !blockTableSync && isUIAllowed('sourceCreate')`（253c3b6ee5 diff 在位）
- **creator 可见可用**（`r4-creator-d2-overview.png`）：ui 账号 D2 动作面板四卡齐（Create New Table / Import Data / **NocoDB Sync** / Connect External Data），点卡开向导建同步成功（见 §4）

## 2. R4-2 hash 形共享 URL —— 过

`http://localhost:3000/#/nc/grid/<uuid>` 形态（R3 lane4 M-1 场景）三端点：

| 断言 | 结果 |
|---|---|
| resolveLink 无密码 → 200 `{"passwordProtected":true}`（零 title 泄露） | PASS |
| resolveLink 对密码 → 200 全坐标（base/table/view == SRC） | PASS |
| resolveLink 错密码 → 400 | PASS |
| sourceSchema 无密码 → 200；带密码 → 200 列集 [Title,Note,Num] | PASS |
| createSync paste（hash URL，无 sourceTableId）→ 200 镜像 + 引擎拉数 | PASS |

extractSharedViewUuid hash-候选实现（253c3b6ee5）源码审 + 活体双验。

## 3. R4-3 响应凭据剥离 —— 过（API + DB 双面）

- **getSync / listSyncs 响应 mappings 键集无 `source_uuid` / `source_password_hash`**（坐标键 source_base_id/source_table_id 等保留）；listSyncs 为裸数组形态，同验剥离
- **服务端持久凭证在位**（nocodb-dev 只读查 `nc_table_sync_mappings`）：role=main 行 `source_uuid`=uuid 本体 + `source_password_hash`=`$2a$10$…` bcrypt 格式（明文不落库）——「服务端 only、响应不泄露」语义完整
- detach 后映射行删除（DB 复查零行）

## 4. R4-4 漂移日志 —— 过

源列 Num（Number/bigint）改 SingleLineText → resync 200 → 镜像 Num 列 uidt=SingleLineText/dt=text（readonly:true 保持）+ 后端日志：

```
Table sync tss1qk5rpjuejieod: propagated column type change Num: bigint -> SingleLineText
```

**「旧值 -> 新值」格式**（R3 M-2 的 new→new 消除）；oldType 先于 mutation 捕获（253c3b6ee5 diff 在位）。

## 5. P1+P2 全矩阵站位 —— 全过（API 侧 f09p2r4l1-api @ D1）

| 面 | 断言 | 结果 |
|---|---|---|
| paste 引擎 | 镜像 synced:true；业务列 readonly；RemoteId/RemoteDeleted system 列 show=false | PASS |
| paste 数据 | 初始 3 行全数据；源加 row4 → resync → 4 行传播 | PASS |
| paste 持久凭证 | api 对 SRC **无 base 角色**，resync 仍 200（凭 mapping 凭证） | PASS |
| selected_fields 减列 | PATCH [Title,Num] → 200，镜像 Note 列删 | PASS |
| selected_fields 增列 | PATCH 加回 Note → 200 列回（readonly）+ resync 后 note1-4 **真实进数**（R1 E4 回归） | PASS |
| 语义校验 | 未知 title 400；[] 400；null → 200 全字段 | PASS |
| freeze/resume | paused ↔ active 翻转 | PASS |
| on_delete_action | 非法值 `rename_table` → 400 拒收（合法枚举 delete/mark_deleted）；`mark_deleted` → 200 | PASS |
| resync 复检 | allow_sync 关 → resync 400；重开 → 200（守卫链回归） | PASS |
| detach | 200 / getSync 404 / synced:false / readonly 全解 / 插行 200 可编辑 | PASS |
| deleteSync | 第二镜像 deleteSync（重放）200，表出 base 列表（trash 语义） | PASS |
| ACL 十一端点 | list/get/source-schema/create/update/delete/resync/freeze/resume/resolve-link/detach：无关系用户全 403；editor-in-base 全 403；匿名 401 | PASS |
| synced 写守卫 | editor 插行 400 + owner 插行 400 | PASS |
| syncing 守卫 | createSync 后瞬删 400 一例（重放 200）——疑 syncing 态守卫命中，未留 body；同语义由 jest Fork 桶断言覆盖（41/41 过） | PASS* |
| DB 落库 | 见 §3 | PASS |

\* 竞态窗口未强造（jest 断言在位即站位足够）。

## 6. UI 活体（camoufox f09p2r4l1；ui 账号 @ D2）

- **向导双模式**（`r4-wizard-step0-paste-empty.png` / `r4-wizard-step0-filled.png`）：Browse [checked] / Paste link 单选在位；切 Paste → URL 框现、**密码框随 URL 非空才出现**、Next 空态 [disabled]；填 hash 形 URL + 密码 → resolve → step1 字段页 → step2（title 预填 + 双删除策略）→ **Create sync 200**，镜像表入树
- **镜像 grid**（`r4-d2-mirror-grid.png`）：**4 records 全数据**（含 API 侧加的 row4）、列头闪电 readonly 徽标、New record disabled（synced 守卫活体）
- **树菜单三态**：
  - Active（`r4-menu-active-state.png`）：常规组五项 + **Sync now / Pause sync / Convert to regular table / Delete sync** 全在；**无 Delete table**
  - Paused（`r4-menu-paused-state.png`）：Pause → 重开菜单翻 **Resume sync**（无 reload）
  - Syncing 竞态：小表同步瞬时完成未捕捉（非违反；Syncing 隐藏由 jest 断言 + R3 活体覆盖）
- **删除流三腿**：
  - 腿 B Convert（`r4-after-convert.png` / `r4-after-convert-reload.png`）：树闪电徽标消失；reload 后数据 4 行保留、列锁消失、**New record 可用**
  - 腿 C 菜单翻转（`r4-converted-menu.png`）：转正表菜单 = 常规组 + **Delete table** 出现 + Sync 组整块消失
  - 腿 A Delete sync（`r4-delete-sync-confirm.png` / `r4-after-delete-sync.png`）：确认弹窗（sync id — 表名 + Cancel/Delete sync）→ confirm → mirror-b 出树 + redirect 离开原表
- **editor 三入口**：入口 1 本轮核心（§1）不可见 ✓；入口 2/3（树菜单 Sync 组、Share 模态 allow_sync 区块）由 useTableSync 403 → sync=null gate 与 editor 简版 Share 承载，R3 已验证、本轮无相关代码变更

## 7. 质量门 —— 全绿

- `tsc --noEmit` exit 0（/tmp/f09p2r4l1-tsc.log）
- jest Fork 桶：**3 suites / 41 tests 全过**（/tmp/f09p2r4l1-jest.log）
- Vite URL 编译强验（`/_nuxt/@fs/` 真实 JS 产物，createHotContext）：Overview.vue 200 + CreateNewSync.vue 200 + SyncMenuOptions.vue（dashboard/TreeView/Table/ 路径）200

## 8. 计数

0 error + 0 minor。R3 四项修复全部回归通过，未发现新问题。

## 证据索引

- 截图：/tmp/f09p2r4l1/shots/（r4-editor-d3-overview / r4-creator-d2-overview / r4-wizard-step0-paste-empty / r4-wizard-step0-filled / r4-d2-mirror-grid / r4-menu-active-state / r4-menu-paused-state / r4-after-convert / r4-after-convert-reload / r4-converted-menu / r4-delete-sync-confirm / r4-after-delete-sync）
- 脚本：/tmp/f09p2r4l1/（setup.sh、t1.sh 分段 S1–S9）
- 质量门日志：/tmp/f09p2r4l1-tsc.log、/tmp/f09p2r4l1-jest.log

## 清理

4 个测试 base（SRC/D1/D2/D3，全 `f09p2r4l1-` 前缀）经 f01e2e 软删 200，base 列表残留 0；lane 账号 3 个留存（f01e2e 基建模式惯例，测试口令仅存 /tmp 脚本不入仓）；camoufox session f09p2r4l1 已 close（no active sessions）。
