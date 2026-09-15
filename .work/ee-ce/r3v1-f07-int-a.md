# r3-f07-int-a — F07 Manage Snapshots 第 3 轮收敛确认（集成测试-正向+边界）

账号：f01e2e@ce-ee.local（owner，f07r3a 专用号注册后 baseCreate 403 roles:No Access，按任务书回落）；editor=f07r3a_ed@ce-ee.local。
资源前缀 f07r3a_，测完已全部删除（DB 复核 live bases=0，nc_snapshots 无本会话残留行，仅余 3 行他轮历史数据）。

## 测试结果逐项

### T1 快照全生命周期 — PASS
- POST /api/v2/meta/bases/{bid}/snapshots → 200，status=processing（snapz00agoc4s6q2db）。
- 轮询 GET → completed，耗时 2.2s。
- 副本 base `pled0jbvr8jx412` title=`Snapshot 2026-09-12T04-15-51 of f07r3a_src`，表 f07r3a_t1 数据 5 行逐条一致（row0..row4 / Qty 0..4）。
- POST .../restore → 200 `{base_id: p0upc1vxwkiyvmo}`，title=`f07r3a_src (restored)`，轮询后表+5 行数据一致。
- DELETE snapshot → 200 true；副本 base GET → 404；快照 GET → 404。

### T2 删源 base → nc_snapshots 源行清零 — PASS（附孤儿副本发现，见 issue 2）
- 独立 base f07r3a_t2src（pu6dklrthcobkf7）建快照 snapsovr736k2j6705 → completed。
- pg8000 直查 nocodb-dev（qnap.elf-balance.ts.net:5432，**未触碰 nocodb 生产库**）：`SELECT ... FROM nc_snapshots WHERE base_id='pu6dklrthcobkf7'` 删前 1 行。
- DELETE /api/v2/meta/bases/pu6dklrthcobkf7 → 200（API 软删，src GET 404）。
- 复查：同 WHERE → **0 行**。R2 双挂（Base.softDelete:457 / Base.delete:707 → BaseSnapshot.deleteByBaseId）生效。

### T3 删「副本已不存在」的快照 — PASS
- 快照 snapcarxflgz6jzz4b（completed）副本 pun516acv3k6v0r 经 DB `UPDATE nc_bases_v2 SET deleted=true` 软删后，DELETE snapshot → **200 true**（非 500）；后续 GET → 404。守卫（service Base.get 判 null 跳过 softDelete）生效。

### T4 title 校验 / processing 互斥 / 跨 base 隔离 — PASS
- title=12345（非 string）→ 400 `Snapshot title must be a string`。
- title 513 字符 → 400 `Snapshot title exceeds 512 characters limit`；512 字符边界 → 200 接受。
- processing 互斥：create 后立即二次 create（race window 实测两次，T1 两轮均命中）→ 400 `Another snapshot is still being created. Try again once it completes`。
- 跨 base：用他 base id 访问 sid512 的 GET/DELETE/restore → 全 404 `Snapshot not found`。

### T5 completed 后副本被 DB 软删 → GET 派生 / restore 行为 — 不符任务书预期（见 issue 1）
实测：GET 快照 → 200，status 仍 `completed`（未派生 error）；restore → **200**，新 base p7n031312th0i2i title=`f07r3a_src (restored)`，表+5 行数据完整；副本未被复活（deleted 仍 true），无 500、无数据损坏。

### T6 权限 editor 403 — PASS
f07r3a_ed（base editor 角色）对 baseSnapshotCreate/List/Get/Restore/Delete 五个操作全 403（`Forbidden ... with the roles: Editor`），ACL（src/utils/acl.ts:274-277 base scope creator+ only）生效。

## issues

1. `packages/nocodb/src/services/base-snapshots.service.ts:195-201(deriveStatus),:126-131(restoreSnapshot):副本被删后的 completed 快照：GET 不派生 error、restore 不返 400，与任务书验收预期（「GET 派生 error → restore 400 明确」）不符:实测 GET 仍 completed、restore 200 且产物完整（title/表/5 行数据全对，副本不复活、无 500）。根因：deriveStatus 对 terminal（completed/error）短路返回 null，R2 注释明示此设计；任务书预期未随 R2 设计修订。建议：裁决方二选一——(a) 修订任务书预期，接受现状（restore 从 trash 软删副本复制出完整新 base，语义可辩护）；(b) 若要求严格探测，restore 前对 completed 快照补副本存在性检查返回 400。非 500/安全/数据一致性缺陷，severity 低。
2. `packages/nocodb/src/models/Base.ts:457(smartDelete 路径 deleteByBaseId):删源 base 后快照副本 base 成孤儿活 base:BaseSnapshot.deleteByBaseId 只删 nc_snapshots 登记行，不软删副本 base——实测删 f07r3a_t2src 后副本「Snapshot 2026-09-12T04-16-20 of f07r3a_t2src」仍 deleted=false、可在 base 列表可见，成为无快照记录的孤儿。建议：deleteByBaseId（或 Base.softDelete 挂钩处）顺带软删该 base 名下全部 snapshot_base_id 副本；或裁决接受（副本视为用户数据不硬清）。severity 低（数据卫生，非崩溃/越权）。

## 环境噪音（非 F07 issue）
- f07r3a@ce-ee.local 新注册号 baseCreate 403 roles:No Access（无 workspace 角色种子），按任务书回落 f01e2e。
- 会话中途 owner token 一次 401（T5 之后 T3 前），signin 刷新即恢复；疑 dev rspack 热重启轮换 JWT secret，与被测功能无关。

## 裁决结论

issues 列表：2 项，均为低 severity 行为/设计预期差（非 500、非越权、非数据损坏）；其余 T1/T2/T3/T4/T6 全部 PASS，R2 修复点（deriveStatus 探测先行+超时兜底未触发误判、删源 base 清登记行、删快照守卫、title 校验、互斥）实测全部生效。
