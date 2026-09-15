# r4-f07-lane1 — F07 Manage Snapshots 第 4 轮收敛确认（第 1 路：int + rev）

结论：**issues**

## issues

### I1 (error, 必修) base-snapshots.service.ts:258 getCopyBaseRow metaGet2 scope 错配 → deriveStatus 恒判 error，快照核心链路全断

- 位置：`packages/nocodb/src/services/base-snapshots.service.ts:258-270`（`getCopyBaseRow`），调用点 `deriveStatus`(:231)、`ensureCopyExists`(:125)、`deleteSnapshot`(:202)。
- 根因：`metaGet2(context.workspace_id, context.base_id, MetaTable.PROJECT, snapshotBaseId)` 中 controller 路由 context 的 `base_id` = 源 base id。`meta.service.ts contextCondition`（:294-299）对 `MetaTable.PROJECT` 追加 `WHERE id = <base_id>`，再叠加 `WHERE id = <snapshotBaseId>`（metaGet2 :703-708）→ SQL 含两个互斥 `id` 条件，恒返回空行。
- 实测证据（nocodb-dev 直查 + API）：
  - create snapshot → 200，副本 job 正常完成：`nc_bases_v2` 副本行 `pvir6l8brefy864` status=''、deleted=false、`nc_models_v2` 有完整副本表 → job 侧无失败。
  - 首次 `GET /api/v2/meta/bases/:baseId/snapshots` → 登记行立即被改写 `status='error'`（DB 证实），副本实际存活。
- 后果链（全部实测复现）：
  - a) `restoreSnapshot` 恒 400 `Snapshot is not ready for restore (status: error)` → completed→restore 主链路不可用；
  - b) processing 互斥失效：`createSnapshot` mutex 检查先跑 `listSnapshots` → 把 in-flight processing 行改写 error → 第二次 create 放行（实测连续两个 200、两条登记行、两个副本 base）；
  - c) `deleteSnapshot` 对活副本不执行 `Base.softDelete`（probe 恒 null → 跳过）→ 登记行删除但副本 base 以 live 状态泄漏在工作区（实测残留行 deleted=false）。
- 建议：`getCopyBaseRow` 改用 workspace scope：`metaGet2(context.workspace_id, RootScopes.WORKSPACE, MetaTable.PROJECT, snapshotBaseId)`（contextCondition 对 workspace scope 只加 `fk_workspace_id`，见 meta.service.ts:283-286），或绕开 contextCondition 手写 knex 查询；mutex 判定不应复用会写库的 deriveStatus（或 deriveStatus 拆纯读/写两层）。
- 注：R3「缓存 free 探测」修复方向正确（缓存确实会掩盖副本外删），但 scope 传参引入本回归。

## PASS 项（本轮实测 + 终审通过）

- 删源 base（软删）→ `nc_snapshots` 行清零 + 全部快照副本 base 连带软删（`cleanupByBaseIdWithCopies` 经 `Base.delete` 与 `Base.softDelete` 双挂钩，含 b5 一拖二的嵌套场景，均 DB 证实 deleted=true）。
- 删「副本已不存在」的快照 → 200，登记行清零。
- completed 后副本被手动软删（DB 置 deleted=true）→ GET 派生 error、restore 400（语义正确）。
- title 校验：非 string 400、513 字符 400、512 字符 200。
- 跨 base 隔离：跨 base GET/DELETE 快照均 404，登记行未被误删。
- editor 角色 4 端点（create/list/get/restore/delete）全 403（实测专用 editor 账号）。
- ACL 双侧一致：`src/utils/acl.ts` creator+ 挂 `baseSnapshotList/Create/Restore/Delete`；`nc-gui/lib/acl.ts` 同名 creator+；controller 逐端点 @Acl 对应。
- controller/service/model 注册齐全（noco.module.ts）；`// [CE-EE]` 标记齐全。
- `cleanupByBaseIdWithCopies` 动态 import Base：运行时正常（删源 base 全链路实测），无循环依赖崩溃。
- `BaseSnapshot.deleteByBaseId` 缓存 key `SNAPSHOT:{baseId}:list` 与 `NocoCache.getList/appendToList` 实际拼 key（`scope:subKeys:list`，CacheMgr.ts:277-279）一致。
- /nc/ 跳转：Snapshots.vue restore 成功后 `navigateTo(/nc/{restoredBaseId})` ✓。
- dataHelpers.ts 空 base 守卫：`NcError` import 存在（:19），守卫写法正确。
- rev 实跑门：`npx tsc --noEmit` exit 0；`npx jest baseVariableValidators --runInBand --forceExit` 12/12 passed。
- 测试资源已清理：全部 f07r4a base/副本/快照行/测试用户已删（含 I1c 泄漏副本补删）。

## 裁决建议

I1 为单路发现、经 API + DB 双重实测证实，属必修 error。本轮不计 0-error；修复 I1 后重派第 5 轮。
