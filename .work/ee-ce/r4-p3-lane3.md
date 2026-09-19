# F09 P3 R4 站位回归 — lane 3 报告（安全审计重点路）

**结论：1 error + 1 minor**（E3 一项：子代理无浏览器工具，UI 活体点击以静态验证补偿，不计错误）
**审查基线 = 8de55d0b24**（R3 后零代码功能变更，仅 i18n 键补齐与注释清理）；:8080 运行 dist 与工作区 dist md5 一致，进程 75970（02:21 起）晚于 dist mtime（02:10），活体口径成立。
账号 f09p3r4l3-{api,ui,ed}@lantest.local；测试数据（3 base / 4 sync / 全部视图共享）已全部删除，token 落盘文件已清除。

---

## 1. 质量门

| 门 | 结果 |
|---|---|
| `npx tsc --noEmit` | exit 0（`.work/ee-ce/f09p3r4l3-tsc.log`） |
| `npx jest --testPathPattern 'Fork'` | **44/44**（3 suites，与基线一致；`.work/ee-ce/f09p3r4l3-jest.log`） |
| Vite URL 编译法 | SyncMenuOptions.vue 200 (36KB) / CreateNewSync.vue 200 (59KB，实际路径 project/Action/) / useEeConfig.ts 200 / useTableSync.ts 200；SyncMenuOptions 编译产物含 `isConvertConfirmOpen` 与 3 处 `convertToRegularTable` |
| zh-Hans.json | JSON 合法；`labels.convertToRegularTable=「转换为普通表」`、`convertToPlainTablesDesc`、`general.cancel=取消` 全在 |

## 2. 源码安全审计

### 2.1 realtime tap 防环七处（BaseModelSqlv2.ts）— 全部就位
1. `afterInsert` :5643 — `data && this.model && !this.model.synced` + try/catch
2. `afterBulkInsert` :5696 — `data?.length && … && !synced` + try/catch
3. `afterDelete` :5787 — 同型守卫
4. `afterBulkDelete` :5829 — 同型守卫（引擎 dest sweep 无 skip_hooks 参数，靠此守卫拦截——实测 processor `bulkDelete` 调用确实只传 `allowSystemColumn`，见 :432-437，链条闭合）
5. `afterBulkRestore` :5908 — 同型守卫（R1 lane3 后补位，本轮复核仍在）
6. `afterBulkUpdate` :6003 — `Array.isArray(newData) && length && … && !synced`（bulkUpdateAll 计数形态无 ids 不 tap）
7. `afterUpdate` :6148 — 同型守卫

环路二重保险复核：引擎 dest 写 bulkInsert/bulkUpdate 带 `skip_hooks:true`（processor :219-225, :427-428）短路 after*；tap 仅在 `loadRealtimeTargets` 命中 `source_table_id = 触发表` 时分发，镜像表永不命中（自身是 dest）。镜像作他 sync 之源时级联止于一跳（已知遗留，不重报）。活体 T1.8：连续写后 src=mirror=7，无自激。

### 2.2 affectedIdsBySource 注入面 — 关闭
- 全仓只有两处投递 TableSyncRun：service `enqueueSyncJob`（mode 只取 `'full-create'|'full-resync'` 硬编码，payload 不含 affectedIdsBySource 字段）与 realtime helper `claimAndEnqueue`（ids 来自 `extractPksValues`，服务端派生）。
- API body 经 controller 显式字段解构 → service 再解构，`mode/affectedIdsBySource/syncId/status` 等杂散字段无通路入 job data。活体 T2.2：create body 夹带以上字段，创建成功且字段全部未持久化/未生效。
- processor 消费端按 `affectedIdsBySource[mainMapping.source_table_id]` 取本 sync 之源，异键忽略；ids 走 `readByPk` 参数化路径。

### 2.3 paste 凭据面 — 关闭
- `extractSharedViewUuid` 正则 `^[0-9a-f-]{36}$` 白名单；bcrypt.compare 比对；落库存 `view.password`（本身已是 bcrypt hash）非明文。
- resolveLink / sourceSchema paste 路径无密码时只回 `{passwordProtected:true}`，零泄漏（活体 S2.1/S2.4 实测响应即该单键）；错密码 400（S2.2）。
- 无 public-metas 旁路：paste resolve 全部在 GlobalGuard + Acl 之后。

### 2.4 detach ACL / 十一端点 — creator+ 全对
- 10 个权限名注册于 `permissionScopes.base`（acl.ts :318-330），exclude 模型下 editor/commenter/viewer include 列表均无 tableSync* → creator+；detach 复用 `tableSyncDelete`。
- 活体 S4.2：editor 打全部 11 端点（list/get/source-schema/create/patch/delete/resync/freeze/resume/resolve-link/**detach**）= **11/11 403**。
- S4.3：editor 直写镜像 400（readonly column 守卫链，非 200）。

### 2.5 响应凭据剥离 — sync/mapping 响应干净；**resync 响应泄漏（见 E1）**
- listSyncs/getSync 显式 `delete m.source_uuid / m.source_password_hash`（service :283-288, :301-305）；toType 白名单不含凭据字段；createSync/updateSync/freeze/resume/detach 均经 getSync 或固定形态返回。活体 S1.1/S2.6：browse+paste 两类 sync 的 list/get mapping keys 均 0 命中。
- share PATCH 响应密码位为 `__NC_PASSWORD_MASKED__`（上游遮罩）。

## 3. 活体回归（P3 站位全矩阵）

| 项 | 结果 |
|---|---|
| realtime browse 建镜像（syncTrigger=realtime）+ full-create 5 行 | OK |
| realtime 插 r6 / 改 r1(Qty=111) / 删 r2 / bulk 数组插 r7+r8 | 全部 2s 内传播 |
| 防环稳定性：连续写后 src=mirror=7 | OK，无自激/级联 |
| **paused 窗口**：freeze → 插 r9/改 r1=999/删 r3 三写 → 镜像冻结 → resume | 三写 2s 内全部追平（R1 lane4 run5 ghost 场景不复现） |
| **Syncing 窗口**：1000 行 bulk 触发长跑 + 窗内删 wdel → 收敛 | CONVERGED：wdel 消失、wave2-999 到达，src=mirror=2006 精确持平（catch-up 全量 pass 含消失扫描生效） |
| 注入探针：syncTrigger=hourly 400；on_delete_action=nuke 400；selectedFields 未知列 400 | 全拒 |
| paste 全链：resolve-link 三态 / source-schema / uuid+password 建 realtime sync / 传播 p4 | 全过 |
| detach：paste sync detach → 镜像可写（200）→ 源再插 p5 不传播（realtime 截断） | 全过；DST 剩余 sync=2 符合 |
| AUTO 双档：realtime/manual 均 200（T2.2 manual + T1.1 realtime） | OK |
| R4 增量 zh-Hans 键：labels.convertToRegularTable 存在且被菜单项/弹窗标题/确认按钮三处 `$t` 消费（SyncMenuOptions.vue :180,228,249）；Vite 编译产物含全部引用 | 静态过（活体点击见 E3） |

## 4. 发现

### E1（error）resync 响应回显调用者活体凭据 + 内部对象图
- **位置**：`packages/nocodb/src/services/table-syncs.service.ts:1132` `return this.enqueueSyncJob(...)` 将 Bull job 对象原样交给 HTTP 序列化；job.data.req 为整个 Express req（fallback 队列 `fallback-queue.service.ts:186` 以内存对象返回，`jobs.service.ts:51` 的 getTrueCircularReplacer 只去真环，`rawHeaders`/`cookies`/`socket` 等无环字段全部幸存）。
- **实测**：POST `/api/v2/meta/bases/:baseId/table-syncs/:id/resync` 响应 `.data.req.rawHeaders` 含调用者当次请求的**活体 xc-auth JWT**（token 尾 12 字符在响应体精确命中 1 次）；响应体 ~35KB，含 `_readableState`/`socket`/`_sessionManager` 等内部对象转储。`headers` 键为 null（环被摘除），`cookies` 为 `{}`（本次经 header 认证）。
- **定级依据**：凭据进响应体违反本 fork 已确立标准（同文件 P2-R3「never expose the share credential」先例）；JWT 有效期内可被日志/网关/浏览器侧信道留存。**无跨用户通路**：resync 为 creator+（S4.2 editor 403），回显是调用者自己的 token；全仓无其它把 job.data 吐给 HTTP 的端点（jobs 相关路由仅内部存在性检查）。P1 起即如此，非 R4 回归——属历轮漏检，本轮按「响应凭据剥离」重点路捕获。
- **建议修复**：`resync()` 返回净化形态 `{ id, name, status }`（或 `sync_job_id` 回读 getSync），一行改动；同时 `enqueueSyncJob` 入队前把 `req` 替换为 realtime 同款最小 shim `{ user: { id } }`（table-sync-realtime.ts :145-147 已有先例）。

### M1（minor）f09-p3-impl-report.md 水位描述已过时
- 该自述「空 affectedIds → RemoteUpdatedAt 水位拉（last_synced_at−30s 重叠）」为 R1 时点语义；R2/R3 起 catch-up 已改**全量 pass 含消失扫描**（table-sync.processor.ts :320-329 注释明确记载改判）。实现报告未随 R3 修订，误导后续维护者。建议在 GOAL-STATE 或报告头部补一行勘误（文档级，无代码动作）。

### E3（外部限制，不计错误）UI 活体点击不可行
- 子代理环境：camoufox-cli skill「not allowed for subagent」、browser-use 报「Browser is not available in subagent」（诊断在案）。R4 增量的 zh-Hans 验证以静态链补偿：键存在（zh-Hans.json）→ 消费点三处 `$t` 正确 → Vite 编译产物含引用。活体视觉确认留主会话或下轮有浏览器工具的路复核。

### 观察（不计数）
- detachSync 先翻转 synced/readonly 后删 mapping（service :1232-1289），中途异常的窄窗口内镜像已转正但 sync 行残留，realtime tap 仍可能对「普通表」投引擎写。纯静态推理（故障注入需 DB 干预，越权），窗口极窄，记观察。

## 5. 清理记录
- 3 个 base（f09p3r4l3-SRC/DST/UIBASE）全部 DELETE = true；bases 列表 0 残留；探针 sync 随 base 级联。
- `.work/ee-ce/.f09p3r4l3-*` id/token 文件、/tmp 下响应转储（含 token）与批量 payload 全部删除；脚本内仅含本地 dev 测试账号口令（红线允许项）。
- f09p3r4l3-{api,ui,ed}@lantest.local 账号行保留于 dev 实例（无用户删除 API，与历轮口径一致），workspace 成员授予经 f01e2e@ce-ee.local（实现自述脚本公开的 dev 账号）执行。

## 6. 产物
- 脚本：`.work/ee-ce/f09p3r4l3-setup.sh` / `f09p3r4l3-run1.sh` / `f09p3r4l3-run2.sh`
- 日志：`f09p3r4l3-tsc.log`（exit 0）/ `f09p3r4l3-jest.log`（44/44）
