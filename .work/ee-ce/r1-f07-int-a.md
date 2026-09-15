# r1-f07-int-a — F07 Manage Snapshots 集成测试（正向+边界）第 1 路

- 实测环境：dev backend http://127.0.0.1:8080（f01e2e owner token 实测；f07r1a 仅 signup，org-level-viewer 无法建 base，按预案回落）
- 源 base `p6871kv1yfa3nfu`（f07r1a_src，2 表 × 2 行）；DB 直查 nocodb-dev（pg8000，nc_snapshots / nc_bases_v2），未触生产库
- 测后已清理（4 base 删除 200；nc_snapshots 残留 2 行经 DB 清除）

## 逐项结论

| # | 任务项 | 结论 |
|---|---|---|
| 1 | 创建快照 200 / processing→completed / title 格式 / 副本 base 存在 | PASS |
| 2 | 副本完整性 2 表 2 行 | PASS |
| 3 | processing 并发 create 400；completed restore 200 | PASS |
| 4 | restore 产物 title=\<orig\> (restored)、含数据、重复 restore | PASS |
| 5 | 删除快照 200；副本 base 404；快照 404 | PASS |
| 6 | 跨 base 隔离 404 | PASS |
| 7 | editor 5 端点全 403 | PASS |

证据摘要：

1. `POST .../snapshots {}` → 200，`{id: snapgaota7hekivws7, snapshot_base_id: prmsop3izt3f4by, status: processing, title: "Snapshot 2026-09-12T03-03-37"}`；轮询 0s/0s/3s → processing/processing/completed（≤60s）。title 匹配 `Snapshot \d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}`。副本 base：bases 列表含 + `GET /api/v2/meta/bases/prmsop3izt3f4by` → 200，title `Snapshot 2026-09-12T03-03-37 of f07r1a_src`。
2. 副本表清单精确 = [f07r1a_t1, f07r1a_t2]，各 2 行、Title 逐条与源一致（API 读副本）。nc_snapshots 行入库核实（id/base_id/snapshot_base_id/status/created_by）。
3. processing 中再 create → 400 `{"msg":"Another snapshot is still being created. Try again once it completes"}`。completed 后 restore → 200 `{base_id: prftmnici03avcr}`。
4. restore1 → 200，新 base title = `f07r1a_src (restored)`，2 表 × 2 行数据完整（逐行核对）；restore2 → 200 新 base_id `p6ang3ziu5hnlsr` ≠ 第一次，title 同、数据同。DB：两 restored base `nc_bases_v2.deleted=false`。
5. `DELETE .../snapshots/{id}` → 200 true；GET 快照 → 404 `Snapshot not found`；GET 副本 base → 404 `ERR_BASE_NOT_FOUND`；DB `nc_bases_v2.deleted=true`（软删）、nc_snapshots 行已删。
6. A base 快照 id 走 B base（`pg0vn09650y9wyj`）路由：GET / restore / DELETE 全 404；B base 快照列表 → 200 `[]`。
7. 真实 editor 用户（signup + base users 邀请 roles=editor）：create/list/get/restore/delete 5 端点全 403，报文含 `permission "baseSnapshotCreate/List" with the roles: Editor`。与读码一致（utils/acl.ts EDITOR 为 include 白名单，baseSnapshot* 仅 permissionScopes.base，CREATOR/OWNER 走 exclude 全量放行）。

附加边界（超出任务清单，均实测）：

- processing 中 restore → 400 `Snapshot is not ready for restore (status: processing)`（干净）。
- processing 中外部删副本 base → 快照派生 status=error；error 后 restore → 400（干净）。
- **例外见 Issue-1/Issue-2**（completed 后副本被删的场景）。

## Issues

1. `packages/nocodb/src/services/base-snapshots.service.ts:160`（配合 `packages/nocodb/src/models/Base.ts:444`）：删除「副本 base 已被软删」的快照（status=error 场景）→ 500。实测：`DELETE /api/v2/meta/bases/{src}/snapshots/snap925cp8vtyw4owp` → 500 `innerError: TypeError: Cannot read properties of undefined (reading 'fk_workspace_id')`，栈指向 `Base.softDelete (Base.ts:444:42)` ← `BaseSnapshotsService.deleteSnapshot (base-snapshots.service.ts:160)`。根因：service 无条件调 `Base.softDelete`；`softDelete` 内 `base = await this.get(...)` 对已软删 base 返回 undefined，仅别名缓存段有 `if (base)` 守卫，444 行 `DataReflection.revokeBase(base.fk_workspace_id, ...)` 未守卫即解引用。建议：service 侧删快照前若派生 status=error/副本 base 不存在则跳过 `Base.softDelete` 直接 `BaseSnapshot.delete`；或 `Base.softDelete` 对 `base` 为空提前返回（防御性修复惠及全部调用方）。
2. `packages/nocodb/src/services/base-snapshots.service.ts:172-191`（deriveStatus）+ `:100-143`（restoreSnapshot）：status 派生仅在 processing 态生效，completed 为终态后副本被删不会派生 error——与任务规格「副本被删→error」不符。实测：快照 snap925cp8vtyw4owp completed 后 `DELETE /api/v2/meta/bases/p3ehgw15y1n1mmm`（副本，200），随后 GET 快照 → status 仍 `completed`（DB nc_snapshots 同值，副本 `nc_bases_v2.deleted=true`）；restore 该快照 → 404 `{"error":"ERR_BASE_NOT_FOUND","message":"Base 'p3ehgw15y1n1mmm' not found"}`（裸内部 id，非规格化错误）。建议：completed 终态也轻量校验副本 base 存在性（Base.get 命中缓存，成本可控），缺失时派生 error 并落库；restoreSnapshot 对副本缺失返回 400/404 快照级错误信息，不透传内部 base id。
