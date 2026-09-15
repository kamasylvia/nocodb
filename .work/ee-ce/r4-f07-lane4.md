# r4-f07-lane4 — F07 第 4 轮会审（int + rev）

## issues

### E1 [error][int+rev] base-snapshots.service.ts getCopyBaseRow scope 冲突 → deriveStatus 恒判 error → Restore 永不可用

- **位置**：`packages/nocodb/src/services/base-snapshots.service.ts:258-270`（`getCopyBaseRow`），连带 `deriveStatus`（:220-252）、`deleteSnapshot` 探测（:202）、`ensureCopyExists`（:121）
- **根因**：`getCopyBaseRow` 把业务请求 context 直接传给 `metaGet2(context.workspace_id, context.base_id, MetaTable.PROJECT, snapshotBaseId)`。快照 API 路由（`/api/v2/meta/bases/:baseId/snapshots*`）经 extract-ids 中间件得到 **base 级 context**（`base_id` = 源 base id）。`metaGet2` → `contextCondition`（`meta.service.ts:266-291`）对 PROJECT 表的 base scope 过滤是 `query.where('id', base_id)`，再叠加 metaGet2 自身的 `query.where('id', snapshotBaseId)` → `WHERE fk_workspace_id=? AND id=<源base> AND id=<副本base>` 恒假，**任何 base 级 context 下必返回 null**。
- **实测证据链**（UI + API + DB 三方）：
  1. UI 建 base f07r4c_base（pnopm09q3af2ivg）→ Settings → Manage Snapshots → New Snapshot：POST 200，成功 toast 出现，列表出现 `Snapshot 2026-09-12T14-50-22`。
  2. 2.5s 后（UI 首次轮询）状态即变 **ERROR**（DB `nc_snapshots.updated_at` = created_at + 3s）。
  3. 副本 base `p8vein1ma4kq8mn` 实际存在：`nc_bases_v2` 中 `deleted=false, status=''`（duplicate job 已完成）。若探测正常，deriveStatus 应回 completed。
  4. **复位实验**：DB 将快照 status 重置 `processing` → 再 GET `/snapshots/:id` → deriveStatus 立即又写回 `error`。实锤 getCopyBaseRow 结构性恒 null，非瞬时竞态。
  5. SQL 语义模拟直查：`WHERE fk_workspace_id='w9qi3ljd' AND id='pnopm09q3af2ivg' AND id='p8vein1ma4kq8mn'` → 0 行。
  6. 连带症状：Restore 按钮 disabled（status ≠ completed）；API restore 400 `Snapshot is not ready for restore (status: error)`；**deleteSnapshot 探测同样恒 null → 删快照时跳过副本 softDelete，副本 base 以活 base 形态残留**（实测删快照后副本仍 HTTP 200，需手动删）。
  7. 终态锁死：`deriveStatus` 对 `status==='error'` 提前 return null（:224），一旦误判永不自愈。
- **建议**：`getCopyBaseRow` 不应以业务 context 的 base_id 作 PROJECT scope。副本 base 行按 workspace scope 查即可，例如 `metaGet2(context.workspace_id, RootScopes.WORKSPACE, MetaTable.PROJECT, snapshotBaseId)`（contextCondition 对 `base_id === RootScopes.WORKSPACE` 只加 `fk_workspace_id` 过滤，与 id 条件不冲突），或等价用 condition 对象 `{ id: snapshotBaseId }` + workspace scope；对齐 `Base.get` 缓存层即按 `{workspace_id, base_id: null}` 的姿势。修复后需同时验证 delete/restore 探测路径（同一函数）。
- **影响**：F07 主链路（create→COMPLETED→restore）在 UI 与 API 全部不可用，属阻断级回归。R3 引入的 cache-free probe（注释 F1 fix）为本 bug 引入点嫌疑。

### E2 [error][int] UI 主链路断言未达成（COMPLETED/Restore/跳转无法验证）

- New Snapshot 后 UI 永远停在 ERROR 态，Restore disabled；Restore 点击流（跳转 `/nc/<restoredBaseId>`、`baseSnapshotRestored` toast）因 E1 无法执行。UI 层本身行为与设计一致（成功 toast、异步按 id 轮询、status 色标、按钮禁用逻辑均正确表现了后端返回的状态），断言失败归因于 E1，修复 E1 后须重跑本链路。

## rev 详记（Snapshots.vue 终审）

- `packages/nc-gui/components/dashboard/settings/base/Snapshots.vue`：轮询按快照 id 单查（24×2.5s）、成功 toast、restore `navigateTo(/nc/<id>)`、delete Modal.confirm + 失败容错、status 色标与 disabled 逻辑——均与后端契约一致，**无 error 级前端问题**。
- 两条非 error 观察（不计入 issues）：
  - 轮询 60s 上限后 UI 停留 processing（后端 15min timeout 兜底，重进页面可刷新）——设计取舍。
  - `onMounted(loadSnapshots)` 若 `baseId` 未就绪静默 return 且无 watch——Settings 场景 openedProject 必已就绪，可接受。

## rev 测试

- `cd packages/nc-gui && npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → **2 files, 10/10 passed**（69s）。

## int 已完成项

- API 建/删测试资源（f07r4c_base、副本、快照行）✓ 已全部清理（含 getCopyBaseRow bug 造成的副本残留）
- UI 纯点击导航（搜索卡片 → mini sidebar Settings → Manage Snapshots）✓ 真实 UI 非 stub
- vitest 10/10 ✓
- 清理：camoufox tab 已关，临时凭证文件已删

## 裁决

- int：issues（E1 阻断 + E2 断言未达成）
- rev：issues（E1 同源，前端无独立 error；测试 10/10 过）
- **总裁决：issues（E1 必修，修后重跑 F07 int 主链路）**
