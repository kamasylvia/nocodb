# r4-f07-lane3 — F07 第 4 轮收敛确认(第 3 路:int + rev)

## int(集成抽验)

环境:nocodb-dev(qnap.elf-balance.ts.net:5432,PG 18.2)pg8000 直查 + dev server :8080 API 实测;专用测试账号 lane3@ce-ee.local(super),测毕清理。

实测序列:

1. signin 200 → 建 base `lane3_f07_src`(pj34zdxuxkodafh)+ 表 t1 → 200
2. POST snapshots → 200,`snap372ikf88zlazmz`,status=`processing`,副本 `ph6qb4j8rvc11w1`
3. 2s 后 GET snapshots → **status 已翻为 `error`(poll0 即 error)**;DB 证实副本行存活:`status=''`、`deleted=false`(job 已正常完成)
4. POST restore → **400 `Snapshot is not ready for restore (status: error)`** — restore 全路径不可用
5. DELETE snapshot → 200,快照行删除;但副本 `ph6qb4j8rvc11w1` **仍 deleted=false → 孤儿 base 遗留 workspace**(删快照守卫失效)
6. 二轮:建快照 → DELETE 源 base → 200;核验:源 base deleted=true ✓,nc_snapshots 行 0 ✓,二轮副本 deleted=true ✓(cleanupByBaseIdWithCopies 正常,因它直调 Base.softDelete 不经 probe)
7. 边界:title=12345 → 400 ✓;title 513 字符 → 400 ✓;title 512 → 200 ✓;GET 不存在 snapshot → 404 ✓;list 不存在 base → 404 ✓
8. ACL 静态核验(acl.ts):ProjectRoles.VIEWER/COMMENTER/EDITOR 均 include-only,不含 `baseSnapshot*` → deny;CREATOR 为 exclude 型(仅排 baseDelete/migrateBase)→ allow;四权限注册于 permissionScopes.base(utils/acl.ts:274-277)✓ creator+ 语义正确

删源 base 清理核验(第 6 步)PASS;全生命周期(create→list→restore)因下述 E1 FAIL。

## rev(后端终审)

实跑:`cd packages/nocodb && npx tsc --noEmit` → exit 0(0 error);`npx jest baseVariableValidators --runInBand --forceExit` → 12/12 passed(F05 既有守护,非回归)。

R3 修复逐项终核:

- ensureCopyExists:逻辑本身成立,但依赖 getCopyBaseRow → 受 E1 影响恒触发 400(restore 已实测)
- cleanupByBaseIdWithCopies:实测 PASS(Base.ts 两处 hook 调用点核对,softDelete 递归经副本自身 cleanup 为 no-op,终止安全)
- 删快照守卫:**FAIL**(见 E1 表现 c)
- title 校验:实测 PASS
- getCopyBaseRow 缓存 free 探测:**FAIL**(E1 本体)
- 其余:controller 路由 v1/v2 双注册 ✓、noco.module.ts 装配 ✓、models/index.ts 导出 ✓、dataHelpers.ts base 空守卫 ✓(tsc 证实 NcError 已导入)、BaseSnapshot 缓存 key 与 NocoCache getList/deepDel 约定核对一致 ✓、insert 后先 get 再 appendToList 顺序 ✓

issues:

- E1(critical,R3 回归)`packages/nocodb/src/services/base-snapshots.service.ts:258-270` `getCopyBaseRow`:`Noco.ncMeta.metaGet2(context.workspace_id, context.base_id, MetaTable.PROJECT, snapshotBaseId)` 中 metaGet2 的 `contextCondition`(meta.service.ts:266-294)对 PROJECT 表强加 `WHERE id = context.base_id`,与 idOrCondition 生成的 `WHERE id = snapshotBaseId` AND 叠加 → `id=A AND id=B`(A≠B)恒空,probe 永远返回 null。建议:改走 workspace scope——`metaGet2(context.workspace_id, RootScopes.WORKSPACE, MetaTable.PROJECT, snapshotBaseId)`(contextCondition 对 base_id===RootScopes.WORKSPACE 不加 id 条件,仅余 `fk_workspace_id=ws AND id=snapshotBaseId`),或直接 knex 条件查询。实测证据(见 int 第 3/4/5 步):活副本被误标 error、restore 恒 400、删快照跳过副本清理致孤儿 base。表现汇总:
  - (a) deriveStatus(service.ts:220-252)对新快照首次 GET 即置 `error` — 状态机瘫痪
  - (b) restoreSnapshot(service.ts:138-183)恒 400 — restore 功能整体不可用(回归:R2 及之前用缓存探测时可正常 restore,DB 中 r3a2 时代 `(restored)` base 与 22:40 前的历史 completed 行为证)
  - (c) deleteSnapshot(service.ts:185-218)守卫恒判"副本不存在"而跳过 Base.softDelete → 每次删快照遗留活副本孤儿
  - 连带:createSnapshot 的 processing 互斥(service.ts:44-52)因状态全被自愈为 error 而永不触发,duplicate job 进行中可无限堆快照

## 攻击性找茬

除 E1 外:无。跨 base 枚举被 `getSnapshotWithBaseCheck`(404)+ ACL base scope 双重挡;restore 的 context 以 snapshot 行为准无越权链;title 回显经 API JSON 输出无注入链。

## 裁决

- int:FAIL(E1 实测复现:a/b/c 三链)
- rev:FAIL(E1,R3 修复「缓存 free 探测」引入 context 条件矛盾)
- 总裁决:**FAIL — R3 的 getCopyBaseRow 修复为 critical 回归,F07 不能收敛,必修后重开一轮**
