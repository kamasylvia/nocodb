# r4-f07-lane2 — F07 第 4 轮收敛确认(独立第 2 路)

## 裁决:issues(非 PASS)

---

## issues

### E1(P0,必修)src 丢失 R4 修复:getCopyBaseRow 未用 RootScopes.WORKSPACE,快照功能将整体回归

- `packages/nocodb/src/services/base-snapshots.service.ts:258-270`(getCopyBaseRow):问题。
- 现象:src 工作区版本 `metaGet2(context.workspace_id, context.base_id, MetaTable.PROJECT, snapshotBaseId)`;而运行中 `dist/main.js`(22:58 编译)同一函数是修复版 `metaGet2(context.workspace_id, RootScopes.WORKSPACE, ...)` 并带注释 `[CE-EE] F07 R4 fix: base_id must be RootScopes.WORKSPACE — metaGet2's contextCondition maps a plain base_id to WHERE id = base_id on the PROJECT table, which contradicts the snapshotBaseId lookup (always null)`。src 与 dist 不一致 = 修复丢失(该文件 git untracked,无历史可追,mtime 22:58:05)。
- 危害(按当前 src 构建/提交即复现):metaGet2 走 `contextCondition`(`meta.service.ts:286-290` 对 PROJECT 表追加 `WHERE id = context.base_id`),与 metaGet2 主查询 `id = snapshotBaseId` 叠加成 `id=源base AND id=副本id` 恒空 → getCopyBaseRow 恒 null → deriveStatus 恒 'error' → 所有快照永久 error、restore 恒 400、deleteSnapshot 跳过副本清理。SQL 已在 nocodb-dev 复现:`select ... where fk_workspace_id='w9qi3ljd' and id='pixoyl0bstpfry4' and id='pdxegmnofxhplli'` → 0 行(副本行实际健康)。
- 实证:运行旧构建期间创建的快照 1/2/3 全部 error;22:58 新构建(含 fix)后的快照 4/5/6 全链正常。
- 建议:把 dist 中的 R4 修复合回 src(getCopyBaseRow 第二参改 `RootScopes.WORKSPACE`,保留注释);并排查该 untracked 文件为何回退(是否有进程/流程在覆盖工作区)。

### E2(中,建议修)deriveStatus 把 error 持久化为终态,瞬时故障导致快照永久损坏

- `packages/nocodb/src/services/base-snapshots.service.ts:224-226`(deriveStatus 开头 `if (snapshot.status === 'error') return null`)。
- 现象:status='error' 后永不复查。快照 1 在旧构建误判期被持久化为 error(副本行 `pdxegmnofxhplli` 至今健康 deleted=false),修复版部署后仍 error,不可恢复。快照 3 的副本 job 因 dev server 重启竞态 failed(processor 失败清理把半成品副本软删),同样固化。
- 建议:error 状态派生时仍探测副本行——副本行恢复健康(或重新出现)则降回正常派生;至少把「探测失败型 error」与「job 确认失败型 error」区分,前者不持久化终态。

### E3(低,上游文件,酌情)duplicate job catch 内清理失败覆盖原始错误

- `packages/nocodb/src/modules/jobs/jobs/export-import/duplicate.processor.ts:339-346`:catch 分支中 `baseSoftDelete` 自身抛错(`Base 'pgf79j2fz4m3504' not found`)直接取代原始 err,JOB FAILED 日志只剩二次错误,快照 3 的真实首错不可考(观测于 `.work/ee-ce/logs/backend.log` 6679-6688)。
- 建议:清理动作包 try/catch,保留并记录原始 err。非 fork 改动文件,与 E1 修复同批顺手处理即可。

---

## int 集成测试(对抗收敛;均在含 R4 fix 的运行构建上实测通过)

1. 非法输入矩阵:PASS。create title=123 / null → 400 `Snapshot title must be a string`;601 / 513 字符 → 400 `exceeds 512`;512 字符(合法边界)→ 200;不存在 base create → 404;restore/delete/GET 不存在 snapshotId → 404;跨 base GET/restore/delete 他 base 快照 → 404;跨 base list → []。
2. 状态机:PASS。processing 期 restore → 400 `(status: processing)`;completed 后 restore ×2 → 两个独立新 base(`f07r4b_src (restored)`,id 存在、deleted=false);副本 DB 手动软删(deleted=true)后 GET 派生 error → restore 400(非 404)`(status: error)`。
3. 删除链:PASS。副本 base 预置 F05 变量后删快照:API 200;副本 GET 404 且 DB deleted=true;`nc_base_variables` 零残留;`nc_snapshots` 行删除。源 base 软删:HTTP 200 → 该 base 的 `nc_snapshots` 清零、快照副本 base 同步软删(cleanupByBaseIdWithCopies 级联生效)。
4. 权限矩阵:PASS。无 token GET/POST/DELETE/restore → 401;workspace viewer 四端点 → 403(create 报 `baseSnapshotCreate with the roles: Viewer`);owner → 200。

## rev 实跑门:PASS

- `npx tsc --noEmit` → 0 错误(exit 0)。
- `npx jest src/helpers/baseVariableValidators.Fork.spec.ts` → 12/12 passed。

## 环境事件(非违反,供 orchestrator 参考)

- 任务书指定账号 f07r4b@ce-ee.local 原本不存在于 `nc_users_v2`,本次 signup 重建并提权 org-level-creator + workspace-level-owner(密码同任务书);账号保留供后续轮使用。测试用临时 viewer(f07r4b_v@ce-ee.local)已删。
- f01e2e 回落账号多路并发共用存在 signin token_version 轮换互踩(后登者使先登者 token 失效);本路全程改用 f07r4b 专用账号规避。
- 23:00 前后 dev server 重启窗口(RSPack 重编译)造成:快照 3 副本 job failed(重启竞态)、快照 1 被旧构建误标 error 持久化。均为旧构建产物污染,非当前 src 行为;相关测试数据已按现状如实计入 E2 论据。
- 测试资源已清理:f07r4b_ 前缀 base 全部软删、nc_snapshots 清零、变量零残留、临时账号已删(遗留的 `f07r3a_src (restored)` / `f07v_y (restored)` 属其他路资源,未动)。
