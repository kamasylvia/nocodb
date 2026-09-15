# r6-f07-lane3 — F07 第 6 轮收敛确认（int 抽验 + rev 后端终审）

## 裁决：PASS

---

## rev（后端终审）：PASS

### R4 修复终核（逐项，均源码核验）

1. **unified deriveStatus 重推导** — `base-snapshots.service.ts:220-252`：create/list/get/restore 四入口全部经 deriveStatus 无缓存重探测；copy 消失→'error'（含 terminal completed 降级），copy 回归→'completed' 自愈，persisted='error' 且 copyRow=null 时返回 null 避免重复写。restore 路径 `?? snapshot.status` fallback 语义正确。实测佐证：残留 processing 快照经一次 GET 自愈 completed（lane3_t4）；DB 中 error 行（失败副本 deleted=true → getCopyBaseRow null）推导链闭环。
2. **getCopyBaseRow RootScopes.WORKSPACE** — `base-snapshots.service.ts:258-273`：对照 `meta.service.ts:266-296`（contextCondition）与 `:634`（metaGet2）语义验证：workspace_id≠base_id → `WHERE fk_workspace_id=<ws>`，base_id=RootScopes.WORKSPACE 早退不加 id 条件，再 `WHERE id=<snapshotBaseId>`。修复前写法（plain base_id）对 PROJECT 表生成 `WHERE id=<base> AND id=<snapshotBase>` 恒空——修复必要性成立，修复正确。
3. **ensureCopyExists** — `:121-136`：restore 前置 copy 存在性校验，缺失→行 status 落 'error' + 400，无 404 内部 id 泄漏。
4. **cleanupByBaseIdWithCopies** — `BaseSnapshot.ts:182-208`：Base.softDelete（453 区）与 Base.delete（660-715 区）双挂点；copy softDelete 失败 try/catch 容错、行清理仍执行；copy 侧 cleanup list 为空、递归安全。实测：删源 base 后 nc_snapshots 行=0、copy base deleted=true。
5. **删快照守卫** — `base-snapshots.service.ts:185-218`：copy 缺失跳过 softDelete 仍删行（200），copy 存在走 Base.softDelete（trash 语义）。实测 delete 后 GET 404、copy 进 trash。
6. **title 校验** — `:33-39`：非 string 400、>512 400（DB 列 varchar(512)，`nc_001_init.ts:1032` 匹配）；空串回落默认 title。

### service/model 全文再扫

- 缓存键：list key `snapshot:<baseId>:list`（CacheMgr.getList 构造）与 `deleteByBaseId` deepDel PARENT_TO_CHILD 匹配；`BaseSnapshot.delete` CHILD_TO_PARENT 同步摘除父 list 引用；insert 先物化对象再 appendToList（R1 修复保持）。
- `metaInsert2` 自动填 fk_workspace_id/base_id（`meta.service.ts:334-347`）→ restore 依赖 `snapshot.fk_workspace_id` 成立。
- duplicate job status 生命周期闭环：baseCreate 设 'job'（duplicate.service.ts:107）→ 成功 baseUpdate status=null（duplicate.processor.ts:327）/ 失败 catch baseSoftDelete（:340，deleted=true → deriveStatus 'error'）。job 崩溃未进 catch 的窗口由 15min timeout 兜底（'job' + created_at 超时 → 'error'）。
- ACL：4 个 scope 挂 base 组（`acl.ts:273-277`，与 baseVariable* 同级 creator+），controller 全部 @Acl 接线，noco.module 注册齐。
- tsc --noEmit：0 错（TSC_EXIT=0）。jest baseVariableValidators：12/12（JEST_EXIT=0）。

### 攻击性找茬（有 API 可达链的）

**无。** 复核过的非违反项（均有明确归因）：
- restore/duplicate 异步 job 运行中删源 copy → job 失败静默（restored 进 trash、status 停 'job'）——本 lane 实测触发一次，日志证据链完整（JOB FAILED: `Base 'posjm04g8s43uw2' not found` @ export.service.ts:920 → processor catch softDelete）。归因：**上游 DuplicateBase job 固有行为**（普通 duplicate 删源同样触发，log 12:51:47 另一实例印证），非 F07 引入；deriveStatus 对 copy 消失的防御已做。产品残余风险：restore 完成前删快照 → restore 静默失败无通知，与上游 duplicate 一致，不计违反。
- create mutex check-then-insert 竞态、insert 失败孤儿 copy——代码注释已声明 residual risk，无可靠 API 触达链。
- listSnapshots N+1 derive 探测——meta 量级小，非缺陷。
- editor 403 本轮未 API 复测（历轮已验）；本轮静态核对 ACL 挂载正确，unauth 401 实测过。

## int（抽验）：PASS

运行环境：dev server :8080（dist/main.js 编译时间晚于全部源码 mtime，确认含本轮全部修复）；nocodb-dev（凭证 Infisical KDL 运行时拉取，未触生产库）。

1. **全生命周期 1 轮**（lane3_t1.py，15 项全过）：title 非字符串 400 / title 513 字符 400 / create→processing / mutex 二次 create 400 / poll→completed / GET single / restore→`<src> (restored)` 新 base / 跨 base GET 快照 404 / DELETE 快照 200 / 删后 GET 404 / restore 已删快照 404 / 删源 base 200 / 删后 snapshots 404。
2. **干净 restore 序列**（lane3_t4_restore.py）：残留 processing 快照自愈 completed → restore → 轮询异步 job 完成（status 'job'→空）→ restored base 存活 → 完成后删 snapshot，restored 仍活 → unauth 401。
3. **删源 base 清理核验**（pg8000 直查 nocodb-dev，lane3_t2db/t5db.py）：删源 base 后 `nc_snapshots` 行=0；快照 copy base deleted=true（进 trash）；restored base 初始存活；全局孤儿快照行=0；测试产物全部 trash 收尾，无残留污染。

## 运行时观测（不判违反，供 orchestrator 参考）

- nc_snapshots 全局有 3 行 processing 状态停留（属其他 lane/历史轮的源 base 仍存活场景，非孤儿、非本 lane 产物）；按设计 GET 时会重推导。
