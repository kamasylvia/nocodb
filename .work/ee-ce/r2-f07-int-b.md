# r2-f07-int-b — F07 第 2 轮会审报告（集成测试-对抗面，独立第 2 路）

账号：f07r2b@ce-ee.local（workspace-level-creator，经 f01e2e PATCH 授权——新注册账号在 Default Workspace 默认 workspace-level-no-access，baseCreate 直接 403，与 F07 无关）；后端 http://127.0.0.1:8080（nocodb-dev）；DB 直查 pg8000 @ qnap.elf-balance.ts.net/nocodb-dev（严禁生产库，未触碰）。资源前缀 f07r2b_，测完已删（残余 0 base / 0 变量）。

## 裁决：error × 1

- `packages/nocodb/src/services/bases.service.ts:198`（baseSoftDelete）+ `packages/nocodb/src/models/Base.ts:402`（softDelete）: 源 base 软删后 nc_snapshots 源行不清零（R1 钩子回归/未接线）: `BaseSnapshot.deleteByBaseId`（`packages/nocodb/src/models/BaseSnapshot.ts:158`）全仓零调用点（grep 实证），`Base.softDelete` 只清 `BaseVariable.deleteByBaseId`（Base.ts:454）不清 snapshot。实测：建 f07r2b_del（pdhff7bx9cslmh4）+1 snapshot（snapukmmox43pyjxth，completed），DELETE base → 200；DB `nc_snapshots where base_id='pdhff7bx9cslmh4'` 删前 1 行 → 删后仍 1 行（含 snapshot_base_id=pdtt2l0u3825s51，且该副本 base `nc_bases_v2.deleted=false` 仍为活 base）。建议：`Base.softDelete`（或 baseSoftDelete 事务内）加 `await BaseSnapshot.deleteByBaseId(context, baseId, ncMeta)`，与 BaseVariable 清理并列；同时决策副本 base 是否随源删除（当前副本成孤儿活 base，仍占 workspace 列表）。

## 分项结果

- PASS T1 非法输入：`POST /snapshots {}`→200（合法）；`{"title":123}`→400 "Snapshot title must be a string"；`{"title":{}}`→400 同上；`{"title":"x"×600}`→400 "exceeds 512 characters limit"；边界 512 字符→200（首次因 processing 互斥 400，互斥解除后复测 200）；restore/delete/GET 不存在 id（snapnonexist0000）→404 "Snapshot not found"；不存在 base 上 create→404 ERR_BASE_NOT_FOUND；跨 base 混用（src 快照 id 经 aux base URL GET/restore/delete）→全部 404，aux 快照列表无外源快照。
- PASS T2 状态机：processing 中 restore→400 "Snapshot is not ready for restore (status: processing)"（200ms 轮询实测捕获 processing 窗口）；completed 后 restore 两次→200×2，base_id 独立（pnmg0ubfda8slq4 ≠ pbiyzq9tteyhr93），两 base 均 GET 200 且 title=`f07r2b_src (restored)`。processing 中 delete（记录项）：DELETE→200，快照行即时消失（GET 后续 404），副本 base 被软删；副作用：在途 DuplicateBase job 随后服务端报 `!! JOB FAILED !! Base not found`（backend.log，duplicate.processor.ts:341）——无数据损坏，仅 job 失败日志噪音，判定可接受并记录。
- PASS T3 副本数据完整性：源 2 表（f07r2b_t1/t2）各 2 行 + secret 变量 F07R2B_SECRET（POST /api/v2/meta/bases/{src}/variables 200）；快照 completed 后副本 base（py48s3u0me2g228）GET 200、status 非 job，2 表名一致，行值逐行一致（t1r1/t1r2、t2r1/t2r2）；restore 出的两个新 base 数据同样逐行一致。副本 variables（记录判定）：GET /variables→keys=[]，duplicate 不复制 variables（options:{} 不含变量面）；restore 产物同样无变量。判定：非 error——变量不随快照复制是安全默认（避免 secret 静默扩散），一致性成立；建议在 fork 设计说明里写明。
- PASS T4 删快照后：给副本 base（pvp9xv9hp1hqr18）先加 secret 变量 F07R2B_COPYVAR（API 200；DB nc_base_variables 可见，值为 `U2FsdGVkX1/...` 密文，NC_CONNECTION_ENCRYPT_KEY 生效）；DELETE snapshot→200；副本 GET→404；DB `nc_bases_v2.deleted=true`（id=pvp9xv9hp1hqr18）；`nc_base_variables where base_id=pvp9xv9hp1hqr18`→0 行（零残留）；`nc_snapshots` 该行及对已删副本的引用均 0。
- FAIL→error T5：见裁决。
- PASS T6 大小压力：f07r2b_big 6 表各 3 行→快照 completed（3.1s）；副本 6 表 18 行逐值一致；restore→200，新 base 6 表 18 行逐值一致。记录：restore 异步，返回 base_id 时副本 job 未完（首次查 0 表，数秒后齐）——行为合理但调用方需轮询，UI 若不轮询会看到空 base。
- PASS T7 权限：无 token：create/list/get/restore/delete 全 401（逐项实测）；editor（f07r2b_ed@ce-ee.local，base 级 Editor）：create/list/get/restore/delete 全 403（"You do not have permission to perform the action "baseSnapshotCreate/List" with the roles: Editor"）；sanity：同 editor 对 base /tables GET 200（账号角色链路正常，403 来自 ACL 而非账号损坏）。

## 环境噪音（非 F07 error，不计）

- dev backend rspack 周期性 "Restarting app..."，两次打断测试进程（T6/T7 首跑 Connection refused）——重跑即过，属 dev 环境行为。
- 新注册账号默认 workspace-level-no-access 致 baseCreate 403——实例默认策略，非 F07 引入；测试经 f01e2e PATCH workspace 角色解决。
- backend.log 有他路/历史快照 base 的 job failed 记录（pt4w3f9cv3gn087，非 f07r2b_ 资源），未触碰。

## 残余清理确认

- 活 base 含 f07r2b 标记：0；F07R2B* 变量行：0；T5 孤儿 nc_snapshots 行已 DB 手工清除（该行为 error 证据，清理属测试后卫生，非掩盖）。
