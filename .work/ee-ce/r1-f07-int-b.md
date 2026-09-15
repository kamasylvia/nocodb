# r1-f07-int-b — F07 Snapshots 集成测试·对抗面（第 2 路）

对象：F07 Manage Snapshots（`services/base-snapshots.service.ts` / `models/BaseSnapshot.ts` / `base-snapshots.controller.ts`）。环境：dev server 127.0.0.1:8080 + pg nocodb-dev（qnap.elf-balance.ts.net）。账号：f07r1b 专用号 401（Invalid credentials）→ 回落 f01e2e@ce-ee.local。资源前缀 f07r1b_，测完已删（API DELETE + DB deleted=true 终验，0 nc_snapshots 残留）。

## 裁决结论

issues 2 实际违反（I1 500、I2 孤儿副本 base）；观察 4 条（O1-O4，行为记录+语义判定，交裁决）。核心 CRUD/权限/清理链 PASS。

## issues（实测复现）

- `packages/nocodb/src/services/base-snapshots.service.ts:37` : create body `{"title":123}` 与 `{"title":{"obj":"x"}}` 均 HTTP 500，`TypeError: _body_title.trim is not a function`（stack 指向 createSnapshot 的 `body?.title?.trim()`）: 入口做 `typeof title === 'string'` 校验，非串回 400（或 extractProps+DTO 校验）。复现：`POST /api/v2/meta/bases/{baseId}/snapshots`。
- `packages/nocodb/src/services/base-snapshots.service.ts:36-55` : title 超长（600 字符 > nc_snapshots.title varchar(512)）时 400 `ERR_DATABASE_OP_FAILED`（PG 22001），但 400 发生于 `BaseSnapshot.insert`，而 `duplicateService.duplicateBase`（L42）已先行真实复制 base → 产生孤儿副本 base（DB 实证 `pm4ixe03awu82lp` 'Snapshot 2026-09-12T03-05-29 of f07r1b_B'：nc_bases_v2 deleted=false、workspace list 可见、无任何 nc_snapshots 行，不可经快照删除）: title 长度校验前置于 duplicateBase 调用之前（≤255/512），否则先校验后建副本。

## 观察记录（行为 + 判定，非必改）

- O1 `base-snapshots.service.ts:30-34/145-170` : DELETE processing 中的快照返回 200 放行；删除后 nc_snapshots 行消失 → 立即再 create 返回 200（原「一次一个 processing」守卫被绕过，两个 DuplicateBase job 并发）。被删副本 DB 遗留 `deleted=true, status='job'`（job 收尾不再更新，无害但脏）。判定：放行 delete 可接受（软删语义），守卫可绕过为低风险缺口，建议 delete-processing 时同步标记或接受现状。
- O2 `base-snapshots.service.ts:100-143` : 快照非时点冻结。completed 后对副本 base 直接加表 f07r1b_evil + 2 行 → restore 产物 11 表（10 原生 + evil），evil 表 2 行全在。副本 base 是 workspace 内活 base（list 可见可编辑）。判定：与「snapshot=时点冻结」语义不符（中风险，交裁决：EE 原义 vs 现实现「快照=可变副本的引用复制」）。
- O3 快照不复制 base variables：源 base 2 变量（含 secret 1）→ 所有快照副本 nc_base_variables 0 行（DuplicateBase 不复制变量），restore 产物同样无变量。删除路径钩子链有效：`models/Base.ts:453` `Base.softDelete → BaseVariable.deleteByBaseId`，实测删快照/删 base 后变量行 0。判定：清理 PASS 无泄漏；「快照应冻结变量」为语义缺口，与 O2 同类，交裁决。
- O4 restore 异步 job 无在飞保护：restore 立即返回 base_id，duplicate job 异步执行；期间删快照 → job 导出阶段崩 `TypeError: Cannot read properties of undefined (reading 'id')`（`helpers/dataHelpers.ts:50` ← `export.service.ts:920`，日志 `!! JOB FAILED !!`），失败清理把产物 base 置 deleted=true（DB 实证 status='job'）。产物不残留（好）；API 层无 restore 进行中状态。判定：低。

## PASS 项（证据）

- 404 族：restore/delete/get 不存在 snapshotId（随机 nanoid）→ 404 `Snapshot not found`；跨 base（baseId=A + B 的 snapshotId）restore/delete → 404。实现：`getSnapshotWithBaseCheck`（base_id 比对）。全过。
- 状态机：restore processing → 400 `Snapshot is not ready for restore (status: processing)`，信息明确；create-while-processing → 400 守卫生效（未被 delete 绕过时）。过。
- 删快照清理：DELETE 200 → snapshot GET 404；副本 base GET 404 `ERR_BASE_NOT_FOUND`；DB nc_bases_v2 deleted=true（4 个副本逐一验证）；nc_snapshots 0 残留。过。
- 大 base：10 表×5 行快照 completed（空载 ~4s；并发 job 期间 120s+ 属排队非缺陷）→ restore 产物 10 原生表、f07r1b_t01 恰 5 行（`row0-f07r1b_t01`…）。过。
- 权限：无 token GET/POST → 401；workspace viewer（f07r1b-viewer@ce-ee.local，invite 实证入 workspace）list/create 快照 → 403 精确信息 `You do not have permission to perform the action "baseSnapshotList" with the roles: Viewer`（baseSnapshotCreate 同）；viewer 仍可读 base 表（200，符合 viewer 语义）。过。
- ACL 注册：后端 `utils/acl.ts:274-277`（base scope，creator+）、前端 `nc-gui/lib/acl.ts:143-146` 齐备。过。

## 残留

- viewer 账号 `f07r1b-viewer@ce-ee.local` + workspace membership 无法程序化移除（workspace-users.controller 无 DELETE 路由），遗留在 nocodb-dev。
- 期间后端两次自动 restart（rspack watch "Restarting app..."，type-check 0 errors），非本功能崩溃；未重启/未杀任何进程。
