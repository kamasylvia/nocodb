# r3-f07-rev-b — F07 前端第 3 轮终审（Snapshots.vue）

## PASS

### 核查项与证据

**1. 轮询新逻辑（R2 修复确认）**
- `Snapshots.vue:42-52`：按新快照 id 定点轮询 `GET /api/v2/meta/bases/{baseId}/snapshots/{newId}`，24 次 × 2.5s 上限，`completed`/`error` 即 break；列表按 `s.id === newId` 定位 upsert（unshift/替换），不整表刷新。与 TASK 规格「定点 24×2.5s」一致。
- 端点存在性：`packages/nocodb/src/controllers/base-snapshots.controller.ts:49-51` 注册 GET-by-id 路由，与前端 URL 完全匹配。
- 返回体匹配：service `getSnapshot` 返回快照对象（`base-snapshots.service.ts:95-111`），前端 `one.data` 直接消费；create 返回 `BaseSnapshot.insert` 对象（含 id）；restore 返回 `{ base_id }`（service:155），与前端 `res.data?.base_id` 匹配；list 返回数组，`res.data ?? []` 匹配。
- 状态门：restore 按钮仅 `status === 'completed'` 可点（`Snapshots.vue:169`），与后端 restore 前 `derived !== 'completed'` 拒绝（service:129-133）双保险。

**2. /nc/ 跳转（R2 修复确认）**
- `Snapshots.vue:70-72`：restore 成功后 `navigateTo(\`/nc/${restoredBaseId}\`)`。路由形式与仓内既有模式一致（`components/dashboard/TreeView/ProjectNode.vue:398` `navigateTo(\`/nc/${baseId}/settings/settings\`)`），`/nc/{baseId}` 为合法 base 路由。

**3. 菜单门收敛（R2 修复确认）**
- `composables/useEeConfig.ts:426-428`：`blockSnapshots = computed(() => false)`，带 `// [CE-EE] F07` 标记。
- `BaseSettingsMenu.vue:262`：菜单项条件 `!blockSnapshots && isUIAllowed('baseSnapshotList')` — 正常显示；`BaseSettingsMenu.vue:50` 的 upgrade 分支因 gate=false 成为死分支（无副作用，no-op）。
- `components/project/View.vue:195`（路由入口）、`:641-656`（tab 门 + 内容渲染 `DashboardSettingsBaseSnapshots`，即本组件）均解封，无 `<NcSpanHidden />` 残留，无 upgrade 弹窗路径可达。
- 后端 ACL key 齐：`src/utils/acl.ts:274-277`（baseSnapshotList/Create/Restore/Delete）。

**4. i18n**
- 10 个 key 经 JSON parse 逐一验证存在：`labels.manageSnapshots`、`msg.info.baseSnapshotsSubtitle/baseSnapshotsEmpty/baseSnapshotCreate/baseSnapshotDeleteTitle/baseSnapshotDeleteDescription/baseSnapshotsRestoreHint`、`msg.success.baseSnapshotCreated/baseSnapshotRestored/baseSnapshotDeleted`、`general.restore/delete/cancel/snapshots`；`{title}` 插值参数与调用（`Snapshots.vue:81`）匹配。

**5. 标记与类型**
- `// [CE-EE]` 标记：Snapshots.vue:2/33/70、View.vue:42/195/640、BaseSettingsMenu.vue:34/49/262、useEeConfig.ts:426。en.json 为 JSON 无法加注释（惯例豁免）。
- `SnapshotType`（`nocodb-sdk/src/lib/Api.ts:7940`）字段 `id/title/status/created_at` 均在，模板消费合法。

**6. 实跑测试**
- `npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → **Test Files 2 passed (2)，Tests 10 passed (10)** ✓

### 非阻断观察（不计 error）
- 轮询循环无 unmount 取消：若用户在 ≤60s 窗口内切换到其它 base，下一次定点 GET 会带新 baseId + 旧 snapshotId → 404 → 外层 catch 弹一次误导性 toast；快照行状态由下次 `loadSnapshots`（onMounted，服务端 deriveStatus）自愈。边界窄、无状态损坏，属健壮性 nit 非功能性 error。
