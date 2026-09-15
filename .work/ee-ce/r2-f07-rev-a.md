# r2-f07-rev-a(第 3 路:后端代码复审,F07 第 2 轮)

## 裁决:NOT PASS — 2 issues

---

### Issue 1(必修)deriveStatus 超时分支先于实际状态探测 → 已完成快照被永久误标 error

`packages/nocodb/src/services/base-snapshots.service.ts:206-212`(deriveStatus)

问题:`created_at` 超 15min 的分支排在 `Base.get(snapshot_base_id)` 状态探测**之前**。status 行只在 createSnapshot 时写 'processing',之后完全靠 list/get 懒刷新派生。

可达链(API):
1. `POST /api/v2/meta/bases/:baseId/snapshots` → 200,status=processing;DuplicateBase job 于 T+3min 正常完成(副本 base status 置 null)
2. T+16min 首次 `GET /api/v2/meta/bases/:baseId/snapshots` → 超时分支先命中,返回 'error' 并持久化(terminal)
3. `POST .../snapshots/:id/restore` → 永久 400 `Snapshot is not ready for restore (status: error)`
4. 后续任何 GET 派生 null(terminal 不再刷新),无自愈,只能改库

附带场景(任务指定的阈值判定):慢大 base / BullMQ 排队 >15min 时副本仍 'job' → 同样误标 error;job 之后完成也无济于事。**15min 阈值本身对大 base 确实偏紧**(duplicate.processor 的 importModelsData 逐表逐行拷贝,百万行级超 15min 现实),但根因是排序:探测先行则「已完成永不误标」,阈值只影响「仍 'job' 且超时」的判定面。建议:① 排序对调——先探测,副本存在且非 job → 'completed'(与 age 无关),`!snapshotBase` → 'error',仍 'job' 且超时 → 才走 error(或改 BullMQ job 存在性判定);② 阈值调大或改 job 心跳,记录为后续项。

### Issue 2(必修)R1 声称的「Base.delete 挂 BaseSnapshot.deleteByBaseId」未落地,零调用点

`packages/nocodb/src/models/BaseSnapshot.ts:158-175`(deleteByBaseId 定义存在,全 src 无调用);`packages/nocodb/src/models/Base.ts`(grep snapshot 0 命中,Base.delete/softDelete 均无挂接)

可达链(API):
1. `DELETE /api/v2/meta/bases/:baseId` → bases.service.ts:218 `Base.softDelete`
2. nc_snapshots 该 base 的行永留孤儿(无任何清理路径);该 base 的快照副本 base(全量数据副本)同样不清理——原 base 已删,数据副本仍以普通 base 形式留在工作区可访问

注意:Base.delete(hard)在 src 内本就无调用点,只挂它盖不住可达的 softDelete 路径。建议:`BaseSnapshot.deleteByBaseId` 双挂 `Base.softDelete`(Base.ts:453 `BaseVariable.deleteByBaseId` 同位)与 `Base.delete`(Base.ts:700 同位);挂钩本身幂等(metaDelete 条件删除 + deepDel list key,重复调用无害)。

---

## R1 修复逐项终核(读码记录)

| 项 | 结论 |
|---|---|
| deleteSnapshot 副本缺失守卫 | ✓ service L174-189:`Base.get` null → 跳过 softDelete 只删行,不再 500 |
| title string+512 校验 | ✓ service L32-37;DB 列 title 512 匹配(nc_097_unify_schema.ts:526) |
| insert get→append | ✓ BaseSnapshot.ts L104-114:先 `this.get` 物化再 appendToList;metaInsert2 自动注入 fk_workspace_id/base_id(meta.service.ts:337,345),restoreSnapshot 依赖的 snapshot.fk_workspace_id 有值 |
| 15min 超时派生 error | 存在但排序错 → Issue 1 |
| Base.delete 挂 deleteByBaseId | 缺失 → Issue 2 |

## 实跑记录

- `npx tsc --noEmit` → exit 0,无输出
- `npx jest`(= pnpm test 同套件)→ Suites 2/2,Tests **26/26 passed**(baseVariableValidators.Fork 12 + uniqueConstraintHelpers.Fork 14)
- 注:F07 本身无后端 jest spec(两 Fork 桶均为 F05);非运行时 bug,不计 issues,提请实现侧关注 TASK.md「补单测」工作流要求

## 攻击性找茬(排除项,均有排除依据)

- 标题拼接溢出:base title swagger `ProjectReq.title` maxLength=150,copy base title ≤ 32+150=182 < projects.title 255;restore title ≤ 161 < 255 → 无溢出
- 越权:metaGet2/metaList2 contextCondition 按 workspace+base 双重过滤,service 再校验 `snapshot.base_id === baseId`;restore 的 duplicateBase 限定 snapshot.fk_workspace_id → 无跨 base/跨 workspace 读写
- ACL:四端点齐挂(acl.ts:274-277,base scope creator+),getSnapshot 复用 List 权限合理;MetaApiLimiterGuard + GlobalGuard 在
- check-then-insert 竞态:代码注释已声明 residual risk(R1 已接受),不重复报
- sandbox base 快照:duplicateBase 自带 400 拒绝,行为合理
- listSnapshots N+1 派生:perf 非错误,不报
