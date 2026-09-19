# F09 P3 R1 — lane3 安全审计报告(f09p3r1l3)

**结论:1 error + 3 minor**

基线 f6a9314b5e(P3 实现批);:8080 活体 = P3 dist(全程只读,未触碰进程)。质量门:tsc 0(exit 0)+ jest Fork 桶 44/44(3 suites,含 3 个 P3 新用例)+ 改动面 Vite URL 200×4(CreateNewSync / SyncMenuOptions / SyncStatusBadge / useEeConfig)。

---

## E-1( error):realtime tap 漏 `afterBulkInsert` —— 源表 bulk 多行插入不触发增量同步(静默失同步)

- **静态根因**:tap 只挂在 5 处 `BaseModelSqlv2.ts` afterInsert(:5644)/ afterDelete(:5774)/ afterBulkDelete(:5816)/ afterBulkUpdate(:5976)/ afterUpdate(:6120)。而标准写路径的分发是:**多行插入走 `afterBulkInsert`,不走 `afterInsert`** ——两处分发:`BaseModelSqlv2/insert.ts:710`(bulkInsert 的 readback 分支)与 `BaseModelSqlv2.ts:4200`(bulkUpsert 插入分支,单行→afterInsert / 多行→afterBulkInsert)。`afterBulkInsert`(:5689)体内只有 webhook handleHooks + audit,**零 tap**。GOAL-STATE「P3 realtime 设计定案」的「五处 tap」清单本身漏了 afterBulkInsert,实现照设计落地 → 设计期遗漏,非实现走样。
- **活体坐实**:realtime sync(实时建)源表 v2 records API 数组体插 3 行(`POST /api/v2/tables/:id/records` 200,即 grid 粘贴多行/bulk import 的标准通路)→ **+6s、+12s 镜像均无这 3 行**;对照单行插入 +4s 即镜像跟随。E2E 对照组:单行插/改/删、bulk 删除全部秒级传播正常 → 缺口精确锁定在 bulk-insert 分支。
- **同根附加面**:`afterBulkRestore`(:5885,软删恢复)同样零 tap —— 恢复的源行在 realtime 下不传播,直到下一次水位/手动跑(低频路径,与 E-1 同根,修 tap 清单时一并补)。
- **影响**:realtime 承诺「源写秒级跟随」,bulk 写静默失同步且无任何 UI 提示(状态仍 Active、last_synced_at 照常刷新),用户无从察觉。任务书 P3 验证范围第 1 条「源表插/改/删行(API 写)→ 亚秒~秒级自动跑」对 bulk 写不成立。
- **修法建议**:afterBulkInsert 补第六处 tap(`data.map(extractPksValues(d,true))`,守卫/try-catch 同款);afterBulkRestore 同理。注意 bulkUpsert 的 update 分支已由 afterBulkUpdate 覆盖,勿重复投递(insert.ts 与 bulkUpsert 两处分发点都要核)。

## M-1(minor):CAS 占有后进程崩溃 → sync 永卡 Syncing,无自愈

`table-sync-realtime.ts:119-123` 先 CAS `active→syncing` 再 `jobsService.add`;enqueue 失败有回滚(catch :148-158),但**两步之间进程崩溃/硬杀则 status 永久 Syncing**(sync_job_id 也可能为空),无 watchdog。用户侧表现为 perpetual "Syncing"(updateSync/resync 全被 400 挡),只能 freeze→resume 解卡。建议:processor job 启动时按 sync_job_id 空值+超时回收,或 resume 允许从 Syncing 恢复。可用性 minor,非安全面。

## M-2(minor):resync 检查-入队窗口与 realtime CAS 可双入队(竞态残留)

`table-syncs.service.ts` resync 是 check(status=active)→ add → update(syncing)三步非原子;realtime 侧 CAS 是原子的但 resync 不是。两者交错时可对同一 sync 双投 job(一个 full 一个 incremental)。CE fallback queue 并发执行下,两个 job 同时跑对 dest 的 find-then-insert upsert 存在重复插行竞态窗(RemoteId 无唯一约束兜底时)。低概率、后果限于镜像重复行,建议 resync 改同款 CAS(一条 `UPDATE ... WHERE status='active'` 看返回行数)。P1 双 resync 亦有同窗,非 P3 新引入。

## M-3(minor):afterBulkUpdate 的 bulkUpdateAll 形态(按筛选批量改)无 rowIds 不 tap

impl 自述已声明(newData=计数无 ids)。该形态下源改动同样静默不传播且无 catch-up 标记(skippedDuringSync 只在 CAS miss 时置)。与 E-1 同属「tap 覆盖缺口」,合并修时可考虑 bulkUpdateAll 改为投空 affectedIds 水位 job。已知级偏低,单列存档。

---

## 安全重点四项 — 全部 PASS

### 1. realtime tap 防环守卫(镜像写不触发 tap)✓
- 五处 tap 全部 `!this.model.synced` 守卫 + 外层 try/catch 吞错(fire-and-forget,`void` 不 await);tapTableSyncRealtime 兜底 `context || ROOT` 不抛。
- 引擎写三通道核验:bulkInsert/bulkUpdate `skip_hooks:true` 在 `BaseModelSqlv2.ts:4731`(:4948)短路 after*;**bulkDelete 无 skip_hooks 参数、dest 侧 afterBulkDelete 确会触发**(:5506/:5514 无条件调用)——由 synced 守卫挡住,与 impl 自述一致,双保险成立。
- 活体:realtime e2e 全程无 job 风暴(单写单 job、status 恒 active、last_synced_at 单调、镜像行数无重复增殖)。级联止于一跳为文档化 fork 简化。
- tap 只匹配 `source_table_id`(mapping join),dest model id 天然不命中,双键防环成立。

### 2. affectedIdsBySource 注入面 —— HTTP 不可达 ✓
- 全仓 `TableSyncRun` 入队仅两处:realtime helper(ids = 引擎从真实行 extractPksValues 所得,非用户输入)与 `enqueueSyncJob`(mode 硬编码 'full-resync',resync/freeze 路径)。
- 通用建 job 端点不存在:`POST /jobs`、`POST /api/v1/jobs` 均 404(活体);JobsController 只有 `/jobs/listen` 轮询。
- 活体注入探针:resync body 塞 `{"mode":"incremental","affectedIdsBySource":{...:[999999]}}` → 200 但注入体被忽略(mode 硬编码,body 不进 jobData),镜像无变化、无误删。
- 水位路径无注入:`watermarkStart` 走 `Date.parse`,NaN → '' → 回退全量;where 子句由 meta 列名 + ISO 串拼(`:338`),源列名经建表校验。
- `TableSyncJobData` 类型已声明 `affectedIdsBySource?: Record<string,string[]>`,processor 只取 `mainMapping.source_table_id` 键,跨源键忽略。

### 3. AUTO 解锁 manual/realtime 权限同权 ✓
- `useEeConfig.ts:167` `blockTableSyncAuto = computed(() => false)`([CE-EE] 标记;blockCustomSync 保持 true);向导 step2 Manually/Automatically 单选,radio 绑定 `syncTrigger`,create 体透传,关窗重置(:219)。
- 服务端 `createSync` 只接受 manual|realtime,其余 400(活体:hourly→400,realtime→200);落库 sync_trigger。
- **无任何新端点/新 ACL op**:realtime sync 与 manual sync 完全共用同一组 11 端点 op(tableSyncCreate/Resync/Freeze/…),服务端按 trigger 分支权限的逻辑为零 → 同权成立。realtime 建出的 sync 的 resync/freeze/resume/delete 与 manual 行为一致(活体 resync 200)。
- 向导 SFC 未见 R8 类裸解构(useBases 已 storeToRefs)。

### 4. paste 凭据面 + P1/P2 回归 ✓
- list/getSync 双路径 `delete m.source_uuid / m.source_password_hash`(:283-284/:300-301)——活体核实 list 响应 mapping 仅含 role/src/dst id,无 uuid/hash。
- resolve-link 四态活体:错密码 400「Invalid shared view password」/ 缺密码 `{passwordProtected:true}` / 正确密码 200 仅回 schema 七键(无任何 password/hash 回显)/ 非法 uuid 400。bcrypt compare 服务端比对。
- resync 复检活体 200(allow_sync + browse 源读权限);「paste resync 不复验 hash」为已知遗留不重复报。
- 引擎白名单通道(allowSystemColumn+skipPermissionCheck+skip hooks)仍在 processor 内部构装,controller 面零暴露;readByPk 排除软删行(:477 softDeleteFilterReadByPk)→ 源软删 → affectedId readByPk null → on_delete 策略删/标记,语义闭合(jest 44 用例含 3 个 P3 用例通过)。

## 测试数据清理

- base `f09p3r1l3-src` / `f09p3r1l3-dst`(含 realtime sync 与镜像表)已删,base 列表零残留,已删 base API 404。
- 账号 `f09p3r1l3-owner@saest.test` / `f09p3r1l3-o2@saest.test`(signup 即 org-level-viewer,无任何 base 权限,无数据)无法自删,留档报备。
- 全程未动源码/未构建/未重启/:8080 进程零触碰。

## 环境注记(致 orchestrator)

f01e2e@ce-ee.local 是跨轮共享 creator 账号,**多路并行使用时 token_version 互踢**(本路中途 401 即此因,每批重 signin 规避)。建议后续轮为 5 路分发独立 creator 账号,或在任务书中注明「每次 API 批次前重新 signin」。
