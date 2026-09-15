# r1-f07-rev-a（第 3 路：后端代码复审）

对象：F07 Manage Snapshots 后端（BaseSnapshot.ts / base-snapshots.service.ts / base-snapshots.controller.ts / models/index.ts / noco.module.ts / utils/acl.ts 注册；Base.ts 仅看 F07 交互）。
实跑：`tsc --noEmit` 0 错误；jest 26/26 过（2 Fork suite）。

## Issues

1. `packages/nocodb/src/services/base-snapshots.service.ts:160`（配合 `packages/nocodb/src/models/Base.ts:444`）: deleteSnapshot 对副本 base 缺失无守卫，直接调 `Base.softDelete`；Base.get 对已删 base 返回 null，`Base.ts:444` `DataReflection.revokeBase(base.fk_workspace_id, ...)` 无 null 判（`if (base)` 只包住 alias cache 清理）→ TypeError → 500，snapshot 行永久无法经 API 删除。触达链：job 失败 → processor softDelete 副本（duplicate.processor.ts:341）→ 用户从 trash 硬删副本 base → snapshot 仍列出（deriveStatus='error'）→ DELETE snapshot → 500。且绕过平台标准入口 `BasesService.baseSoftDelete`（bases.service.ts:198）的 404 守卫/IntegrationLink 清理/事务/PROJECT_DELETE hook。建议：先 `Base.get(context', snapshot_base_id)`，null 时只删 snapshot 行；存在时改走 basesService.baseSoftDelete。

2. `packages/nocodb/src/services/base-snapshots.service.ts:29-34,57-63`: createSnapshot 互斥检查 TOCTOU——`list` 查 processing 与 `insert(status='processing')` 之间隔着整个 duplicateBase 同步段（Base.get、baseCreate、入队），并发两请求均可过检 → 绕过单 processing 限制，产生双份全量副本。另 insert 在 duplicateBase 之后才执行：insert 前崩溃/抛错 → 复制 job 照跑，产生无 snapshot 记录指向的 live 孤儿 base，无法经 API 清理。建议：先占位插入 processing 行再发起复制（失败置 error），或 per-base 锁。

3. `packages/nocodb/src/services/base-snapshots.service.ts:172-191`（配合 duplicate.processor.ts:339-346）: 无 processing 卡死恢复。正常失败经 catch softDelete 副本 → deriveStatus 得 'error'，可解；但 job 进程崩溃时 catch 不执行，副本 base 永远 status='job' → deriveStatus 恒 'processing' → 该 base 的 createSnapshot 被 :30 检查永久 400 挡死，无超时/reaper。建议：processing 加时长上限或启动时 sweep。

4. `packages/nocodb/src/models/Base.ts:696-700`（F07 交互）: Base.delete/Base.softDelete 均不级联清理 nc_snapshots——`BaseSnapshot.deleteByBaseId`（models/BaseSnapshot.ts:152）全仓零调用点=死代码。原 base 硬删（trash purge）后 snapshot 行残留成孤儿（路由层先 404，不可达、不可清）。建议：Base.delete 挂 BaseSnapshot.deleteByBaseId，或删死代码并记录清理策略。

5. `packages/nocodb/src/services/base-snapshots.service.ts:36-38`: body.title 仅 trim 无长度校验，nc_snapshots.title varchar(512)（nc_001_init.ts:1033）→ >512 字符 DB 层报错 → 500 而非 400。建议：长度校验（对齐 meta API validatePayload 惯例）。

6. `packages/nocodb/src/services/base-snapshots.service.ts:12-14`（注释与事实不符，中等）: "hidden-from-flows" 不成立——Base.list（models/Base.ts:183）只滤 deleted，不滤 status='job'，副本 base（含 processing 中的 'job' 态、completed 态）对创建者在 base 列表/trash 完全可见，标题仅 "…copy" 无 snapshot 标识，易被误改/误删（误删即触发 issue 1 链）。建议：副本 base meta 打标并在 baseList 过滤，或至少确认接受可见性并修 issue 1。

## 复核过无问题的点

- ACL：baseSnapshot* 4 op 注册于 permissionScopes.base（utils/acl.ts:274-277）；creator=exclude 黑名单（acl.ts:643，未排除）→ creator/owner 放行；editor/viewer/commenter=include 白名单 → 拒绝。"creator+ only" 双侧一致，无校验器冲突。
- restore 服务内调 duplicateBase → baseCreate：服务内调用不过 HTTP ACL 中间件，无二次 ACL；与原生 duplicateBase 路由（@Acl('duplicateBase')）同权口径，无提权。
- metaGet2/metaInsert2/metaDelete 经 contextCondition/metaInsert2 注入 base_id+fk_workspace_id（meta.service.ts:301-361,634-701,266-290）：route context 与 snapshot 行 base_id 恒一致；deriveStatus/restore/delete 的 fabricated context（base_id=snapshot_base_id）与 PROJECT 表 contextCondition（id=base_id）自洽，跨 base 查询查不到的担心不成立。
- cache：model 的 key/appendToList/deepDel 形态与 Extension/BaseVariable 惯例一致；CHILD_TO_PARENT 自愈（CacheMgr.ts:458-495,295-328），删单条会同步摘除 list 缓存项。
- 路由：`/api/v1/db/meta/bases/:baseId/snapshots*`、`/api/v2/...` 全仓唯一，无冲突；guard/HttpCode/TenantContext 与 F05 controller 惯例一致；extract-ids 对 :baseId 通用处理（extract-ids.middleware.ts:521-566）。
- metaInsert2 自动注入 fk_workspace_id（meta.service.ts:337）→ snapshot.fk_workspace_id 非空，restore/delete 的 fabricated context 安全。
- 路由层 extract-ids 对已删原 base 404 → restore 不可达，语义合理。
