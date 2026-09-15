# r3-f07-int-a2 — F07 Snapshots R3 会审报告（第 1 路，int + rev）

测试窗口：2026-09-12 22:15–22:55（UTC+8）。构建版本注意：测试期间源码被并行修改两次
（service 22:36、22:38；Base.ts/BaseSnapshot.ts 22:10），本报告按实测时实际运行构建 + 最
终 22:38 源码读码出具。

## issues

### E1（error，阻断）：getCopyBaseRow 向 metaGet2 传 null base_id → 快照全部五个端点 500

- 位置：`packages/nocodb/src/services/base-snapshots.service.ts:258-272`（getCopyBaseRow，
  22:38 源码仍在）；调用于 deriveStatus(:231)、ensureCopyExists(:125)、deleteSnapshot(:202)。
- 根因：`Noco.ncMeta.metaGet2(workspace_id, null, MetaTable.PROJECT, id)` ——
  `packages/nocodb/src/meta/meta.service.ts` 的 metaGet2 要求 base_id 必传（校验分支
  `if (!base_id) NcError.metaError({ message: 'Base ID is required' })`）；且对
  MetaTable.PROJECT，contextCondition 会把 base_id 映射为主键过滤（`where id = base_id`）。
  传 null 既过不了校验，语义上也不成立。
- 实测（运行中 22:36 构建，HTTP 状态码逐项验证）：
  - `GET  /api/v2/meta/bases/:baseId/snapshots` → **500** "Base ID is required"
  - `GET  /api/v2/meta/bases/:baseId/snapshots/:sid` → **500**（两次复现）
  - `POST /api/v2/meta/bases/:baseId/snapshots` → **500**（create 内部先 listSnapshots 派生）
  - `POST .../snapshots/:sid/restore` → **500**（deriveStatus 先行探测）
  - `DELETE .../snapshots/:sid` → **500**（22:38 源 deleteSnapshot 也改走 getCopyBaseRow）
- tsc --noEmit 为 0（strictNullChecks 不拦），jest 不覆盖此路径——只有实测能暴露。
- 建议：改为 `metaGet2(context.workspace_id, snapshotBaseId, MetaTable.PROJECT, snapshotBaseId)`
  （PROJECT 分支下 base_id 参与主键过滤，传副本自身 id 即得正确 scope），或 base_id 传
  RootScopes.WORKSPACE；保留 `row.deleted === true → null` 的人工判定。

### E2（error，逻辑，被 E1 阻断未实测）：快照 completed 后副本被 DB 直改软删时，旧构建
（22:36 前）派生仍 completed 且 restore 成功

- 实测（旧构建）：DB `update nc_bases_v2 set deleted=true where id=<copy>` 后立即
  `GET /snapshots/:sid` → status 仍 completed；`restore` → **200 并产出新 base**——对已进
  trash 的副本执行了 restore。这正是 22:36 "cache-free probe" 重构要修的 F1 问题（缓存遮
  蔽库外删除），重构方向正确，但新实现落进 E1。E1 修复后须回归本场景（API 软删路径在旧
  构建已验证：derive error + restore 400 + 持久化 error，通过）。

## 已验证通过项（实测，早先构建 22:10 源；新源码这些路径未回退，但被 E1 阻断复测）

1. 生命周期：create(processing) → completed；副本 base 表结构 + 3 行数据与源一致；restore
   返回新 base 且含同表同 3 行；delete snapshot 200 → 行消失 + 副本软删（DB 验证）+ GET 404。
2. R2 回归（cleanupByBaseIdWithCopies）：`DELETE /api/v2/meta/bases/:baseId`（源 base，软删）
   200 → nc_snapshots 源行清零（含 stuck processing 行）+ 全部快照副本 base deleted=true
   （DB 直查验证）。动态 import Base 无静态循环（BaseSnapshot.ts 无 Base 静态 import），运行时验证通过。
3. 删「副本已不存在」快照：API 软删副本后 DELETE snapshot → 200（不 500）。
4. title 校验：非 string → 400；601 字符 → 400。processing 互斥：completed 前第二发 create → 400。
5. 跨 base 隔离：GET/DELETE/restore 他人 base 的 snapshot id → 全部 404（HTTP 404 验证）。
6. 权限：editor 对 list/create/restore/delete 全部 403（acl base scope，错误信息含权限名）。
7. 实跑门：`npx tsc --noEmit` = 0（22:36、22:38 两个源版本各跑一次）；
   `npx jest baseVariableValidators --runInBand --forceExit` = 12/12（两次）。

## rev 读码终核（22:38 源）

- deriveStatus：探测先行（copyRow 存在性 → status JOB → 15min 超时仅 stuck-in-job 兜底 →
  否则 completed；error 恒终态）——结构与 R2/R3 要求一致；因 E1 无法实测。
- 删快照守卫：副本不存在仍删登记行，旧构建实测 200；现版本同路径（除 E1）。
- service/model 再扫：除 E1/E2 外，无其它有 API 可达链的洞。

## 环境记录（非代码问题）

- f07r3a2@ce-ee.local 登录 401（账号未建/失效），按预案回落 f01e2e@ce-ee.local。
- rspack dev 重启轮换 JWT secret（dev-backend.sh 未固定 NC_JWT_SECRET）→ 会话中多次 401，
  重登即恢复；一次重建窗口产生中间态构建 500（getCopyBaseRow is not a function），为 E1
  重构落盘过程态，非最终源码问题。
- 测试资源已清理：8 个 base 全部 API 软删、8 个孤儿 schema 已 DROP、nc_snapshots 测试行 0、
  editor 测试账号（usd12q19fk1cdujr）各表已删。

## 裁决

**issues：E1（阻断必修）、E2（E1 修复后回归）。不 PASS。**
