# r3-f07-rev-a.md — 第 3 路后端代码复审(F07 第 3 轮收敛确认)

## PASS

### R2 修复终核(逐项)

1. **deriveStatus 探测先行+超时兜底**(base-snapshots.service.ts:195-227)
   - 探测:`Base.get`(条件 `deleted:false`)返 null → 'error';status=`job` 且未超时 → 'processing';否则 'completed'。终端态(completed/error)短路返 null,不误降级。
   - 超时兜底仅命中 stuck-in-job 场景(status 仍 'job' 且 >15min):进程被 kill -9、job 队列丢失类。
   - **时间解析链实测无坑**:CustomKnex.ts:25-27 将 PG `timestamp`(1114)解析为 `dayjs.utc(val).format('YYYY-MM-DD HH:mm:ssZ')` 字符串(带 +00:00 offset);`new Date("2026-09-12 10:00:00+00:00")` 经 node 实测正确解析为绝对时间(offset 生效),15min 窗口数学正确,非 UTC 服务器不偏斜。
   - job 成功路径 `projectsService.baseUpdate(status:null)` → `Base.update` 同步刷新 PROJECT 缓存(CacheMgr key `project:<id>`,context base_id:null,与 Base.get 读缓存一致)→ 无「永远 processing」。
   - job 失败路径 catch → `baseSoftDelete` 副本 → `Base.get`(deleted:false)返 null → deriveStatus 立即 'error',无需等 15min。
2. **Base.ts 双挂钩**(Base.ts:456-457 softDelete / 706-707 delete):均调 `BaseSnapshot.deleteByBaseId(context, baseId, ncMeta)`,ncMeta 透传;metaDelete 条件 `{base_id}` + contextCondition(`fk_workspace_id`+`base_id`,meta.service.ts:266-291)双重过滤一致;trash 软删与彻底清除两条路径全覆盖,与 F05 BaseVariable 模式一致。
3. **deleteSnapshot 守卫**(base-snapshots.service.ts:174-189):`if (snapshotBase)` 先探测,副本已被清(失败 job / 手动清 trash)时跳过软删,仅删登记行,不再 500;用 `Base.softDelete` 而非 `Base.delete` 避开 "cannot delete first source" 守卫 ✓。
4. **insert 顺序**(BaseSnapshot.ts:104-114):先 `this.get()` 物化缓存对象,再 `appendToList`。已核 CacheMgr.appendToList(:500-558):append 时会用 prepareValue 把 listKey 写入子键 parentKeys;若顺序颠倒(先 append)会命中 `!rawValue` fallback 分支(R1 原始 bug:logger.error + 全列表失效)——顺序修复正确。`delete`(CHILD_TO_PARENT)能经 parentKeys 反查父列表摘除自身;`deleteByBaseId`(PARENT_TO_CHILD)删列表+子键,语义核对无误。
5. **title 校验**(base-snapshots.service.ts:32-37,49-51):非 string → 400(NcError.badRequest 签名 `never`,必抛,无缺 return);>512 → 400,与迁移列 `title varchar(512)`(nc_001_init.ts:1032)精确对齐;纯空白/空串回落默认标题。emoji 码元过计仅导致过严,方向安全。

### service/model 全文再扫(R1-R2 叠加后)

- 缓存:list/setList/appendToList/deepDel 键构造与 `snapshot:<baseId>:list` 逐一核对;NONE list、update 合并、跨 context 隔离均正确;listSnapshots 派生写入幂等(status 相同不写、写一次后终端态短路),无写放大。
- ACL:后端 permissionScopes.base 注册 4 项(:274-277);EDITOR/VIEWER/COMMENTER 为 include 型未含 → 拒;CREATOR/OWNER 为 exclude 型未排除 → 允(creator+ 语义成立);前端 lib/acl.ts:141-146 creator 块一致;@Acl 默认 scope='base' 匹配;v1+v2 路由注册无上游冲突,与 Snapshots.vue 调用路径(/api/v2/meta/bases/:baseId/snapshots*)逐条对齐。
- metaInsert2 自动注入 fk_workspace_id/base_id/created_at(meta.service.ts:339-351)→ deriveStatus 的 `snapshot.fk_workspace_id` 非空保证;SnapshotType/ProjectStatus.JOB/MetaTable.SNAPSHOT 均存在;nc_snapshots 迁移列与 extractProps 字段集匹配。
- getSnapshotWithBaseCheck:base_id 不匹配 → 404,且 metaGet2 contextCondition 再兜一层,跨 base 越权不可达。

### 实跑

- `npx tsc --noEmit`:**0 error**(exit 0)。
- `npx jest`:**26/26**(2 suites:baseVariableValidators.Fork / uniqueConstraintHelpers.Fork)。

### 攻击性找茬(逐条含可达链评估;均非 error 级)

无 error 级问题。以下为已评估的残余观察项,均不构成 bug/安全问题(不破坏数据、可自愈、或属上游代码微竞态):

- createSnapshot 互斥读的是原始存储 status(未经 derive):真卡死的 'processing' 行会挡新快照,但任意一次 list/get 即派生翻转 'error' 自愈(UI 建列表先于创建);R1 已注明 mutex 残余风险。
- 持久化 'completed' 后副本被 purge → restore 走 duplicateBase 得干净 baseNotFound(非 500),删快照可正常收尾。
- 并发双 restore → 产生两份 restored 副本,不破坏数据。
- Base.softDelete:445 `base.fk_workspace_id` 在 base 为 null 时会抛(上游代码);fork 调用点已有 `if (snapshotBase)` 前置守卫,仅剩微秒级 TOCTOU 窗口,且上游同类型调用(baseSoftDelete)有 baseNotFound 守卫。
- nuxt.config.ts `allowedHosts: true` 仅影响 nuxt dev server,无生产面。
