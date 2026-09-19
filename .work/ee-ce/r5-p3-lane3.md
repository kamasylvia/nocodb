# F09 P3 R5 修复回归（冲刺轮）— lane 3 报告（安全审计重点路）

**结论：PASS（0 error + 0 minor）**（外部限制 E3 一项，不计错误）
**审查基线 = 45032e45b0**（R4 修复批）；工作区 `packages/` 与基线 `git diff` 为空（零漂移）；运行 dist（`~/.nocodb-run`）与工作区 dist **md5 一致**（10c3469c62997b30e26f90adffc71dca），进程 72234（05:55 起）晚于 dist mtime（05:31），活体口径成立；dist 内含修复标记 `never echo it over HTTP`（grep 1 命中）。
账号 f09p3r5l3-{api,ui,ed}@lantest.local（workspace 级 creator/creator/editor，经 f01e2e infra 账号 invite）；测试数据（3 base / 6 sync）已全部删除，token/id 落盘文件与 bulk payload 已清除。

---

## 1. 质量门

| 门 | 结果 |
|---|---|
| `npx tsc --noEmit` | exit 0（`f09p3r5l3-tsc.log`） |
| `npx jest --testPathPattern 'Fork'` | **44/44**（3 suites，与基线一致；`f09p3r5l3-jest.log`） |
| Vite URL 编译法（:3000） | SyncMenuOptions.vue 200(36KB) / CreateNewSync.vue 200(59KB) / project/Sync/index.vue 200(42KB) / useEeConfig.ts 200 / useTableSync.ts 200 |
| zh-Hans.json | `labels.convertToRegularTable=「转换为普通表」`、`convertToPlainTablesDesc` 中文在；SyncMenuOptions.vue 三处 `$t` 消费（:180 菜单项 / :228 弹窗标题 / :249 确认按钮）；编译产物含 convert/isConvertConfirmOpen 10 处引用 |

## 2. E1 修复回归（本轮核心，活体）

`POST /api/v2/meta/bases/:baseId/table-syncs/:id/resync` 响应实测：

- **响应体精确收敛**：raw body **69 字节** `{"id":"jobjbqf0q3cgnjyao","name":"table-sync-run","status":"syncing"}`，`jq keys` = 恰好 `["id","name","status"]`
- **token 尾 16 字符 grep = 0 命中**；`rawHeaders/_readableState/socket/xc-auth/authorization/cookie/jwt/_sessionManager` 全部 0 命中（R4 泄漏体 ~35KB → 现 69B）
- **功能本体无损**：resync 前源插 e1row → resync 后 status 翻转 syncing→active、`last_synced_at` 更新、镜像 **2s** 拉到 e1row；realtime 镜像 1s 同步到达
- **守卫不变**：paused 下 resync 400「Sync is paused. Resume it before syncing」；Syncing 下 detach/delete 均被 running 守卫拦截（活体触发，见 §3 detach 腿）
- **源码面**：`table-syncs.service.ts:1132-1136` 显式挑 `{ id: job?.id, name: job?.name, status: Syncing }`；**全仓 job.data 回显面复查**——仅两处投递 TableSyncRun（service `enqueueSyncJob` :825 / realtime helper `claimAndEnqueue` :135，后者已用最小 req shim `{user:{id}}`，:146-148 注释在案）；上游 job 控制器（data-export / duplicate / source-delete / at-import）返回形态均为 `{id...}` 最小体，无第二回显点。`sync_job_id: null` 为 processor 设计终态（processor :81/:88 成功/失败两路置 null），非缺陷。

## 3. P1+P2+P3 全矩阵站位（活体）

| 项 | 结果 |
|---|---|
| realtime 四写传播 | 插 r6 / 改 r1(Qty=111) / 删 r2 / **bulk 数组体** r7+r8 — 全部 2s 内 |
| 防环稳定性 | 连续写后 src=mirror=8 精确持平；静态七处 tap 守卫（BaseModelSqlv2 :5643/:5696/:5787/:5829/:5908/:6003/:6148）+ realtime 最小 shim 复核全在位，无自激 |
| paused 窗口 | freeze → 插 r9/改 r1=999/删 r3 → 镜像冻结（r9=0/r1=111/r3 在，status=paused）→ resume → **三写 2s 追平**（r9 入/r1=999/r3 消失） |
| Syncing 窗口 | **真 1000 行 bulk**（HTTP 200）压 sync3 入 syncing → 窗内删 wdel + 窗后插 wave2b → **CONVERGED ~20s**：wdel 消失（sweep 生效）、wave2a/wave2b 到达、w0/w999 首尾行在、status=active |
| paste 全链 | resolve-link 四态：browse uuid=`passwordProtected:false`+坐标 / 密码 uuid 无密码=**单键零泄漏** / 错密码=400 `Invalid shared view password` / 路径穿越形 uuid=400；source-schema 无密码=`passwordProtected:true` 单键；uuid+密码建 paste sync（响应**零明文密码回显**，mode=paste）；full-create + p4 实时传播 1s |
| detach 三腿（干净重跑） | active 下 detach=`{ok:true,tableId}` → 镜像可写（PATCH 200）→ 源再插 p6 **不传播**（realtime 截断）；二次 detach 404；DST 剩 4 sync 符合 |
| detach 运行守卫 | syncing 窗口内 detach 400「Cannot detach a sync while it is running」（守卫正向验证） |
| AUTO 双档 | realtime（sync1/sync3）+ manual（sync2 建+resync 驱动）均 200 全链 |
| selected_fields camelCase | PATCH `selectedFields:["Name"]` 接受；get 回 `selected_fields:["Name"]`；镜像列收敛为 Name+系统列+RemoteId/RemoteDeleted |
| 类型漂移 | 源表 Number 列插文本 = 400（CE 列型守卫在源头拒绝，与 R4 同型；同步层无 API 可达漂移通路） |
| 删除流 | DELETE sync → 镜像入回收站（404，`deleteSync` :1073-1081 trash 语义设计如此）+ sync 行移除；二次 404；syncing 中删除 400 守卫 |
| 注入探针 | syncTrigger=hourly 400；夹带 `mode/affectedIdsBySource/syncId/status` 建单成功且全被弃（status=syncing/trigger=manual 正确）；`on_delete_action:"nuke"` 400；未知 selectedFields 400 |
| **editor ACL（安全重点）** | editor 打 **11 端点 = 11/11 403**（list/get/source-schema/create/patch/delete/resync/freeze/resume/resolve-link/detach）；editor 直写镜像 400（readonly 守卫链）；ACL 注册复核 acl.ts :320-329 十权限名，detach 复用 `tableSyncDelete`（controller :193） |
| **响应凭据剥离（安全重点）** | list（裸数组形态）+ get：mapping keys 全集 13 键，`source_uuid`/`source_password_hash` **0 命中**（browse 与 paste sync 各查）；paste 密码设置响应 `__NC_PASSWORD_MASKED__` 上游遮罩在位 |

## 4. 静态安全审计清单（源码级）

- **resync 收敛**：service :1132-1136 修复体在位；UI 两侧不消费响应体（useTableSync.syncNow 仅 await；project/Sync/index.vue 经 jobs-list 轮询跟踪，:158）
- **paste 凭据面**：`extractSharedViewUuid` uuid 白名单正则（:125-135，path/hash-route 双形态）；bcrypt.compare 三处（:342/:527/:1208）；落库仅 bcrypt hash（:811-814）；无密码 resolve 全路径单键 `passwordProtected` 零泄漏
- **realtime tap 防环**：七守卫 + try/catch 全在位（行号与 R4 一致）；引擎 dest 写 skip_hooks 二重保险；镜像永不命中 loadRealtimeTargets
- **enqueueSyncJob**：job.data 内嵌活体 req 仅存于队列侧（fallback 队列内存对象），HTTP 面已断（E1 修复），job 复查无第二吐出点

## 5. 发现

**0 error + 0 minor。**

### E3（外部限制，不计错误）UI 活体点击不可行
- 本子代理环境 browser-use 报「Browser is not available in subagent」（诊断在案，与 R4 同）。UI 项以静态链补偿：Vite 编译门 5×200、zh-Hans 键与三处消费点、向导双模式（browse/paste 字段组）双档（realtime/manual radio :371-374）、树菜单三态（syncNow/freeze-resume/convert :130-170）全部编译产物可见。活体视觉确认留主会话复核（历轮口径一致）。

### 观察（不计数）
- setup 期瞬态：一次 sync 创建请求返空（重试即成），infra token 一次「Token Expired」（重签即成）。均为 dev 环境瞬时现象，非功能路径，不复现。
- workspace 邀请端点角色串为 SDK 枚举全值（`workspace-level-creator` 等），裸 `creator` 拒绝——上游行为，非 fork 面。

## 6. 清理记录
- 3 base（f09p3r5l3-SRC/DST/UIBASE）全删 true；api/ui/infra 三视图 bases 残留 **0**
- `.f09p3r5l3-*` token/id 文件、bulk payload、/tmp 响应转储全部删除；脚本内仅含本地 dev 测试账号口令（红线允许项）
- f09p3r5l3-{api,ui,ed}@lantest.local 账号行保留于 dev 实例（无用户删除 API，历轮口径）；workspace 授予经 f01e2e@ce-ee.local infra 账号执行

## 7. 产物
- 脚本：`f09p3r5l3-setup.sh` / `f09p3r5l3-grant.sh` / `f09p3r5l3-run1.sh` / `f09p3r5l3-run2.sh`（格式误报轮，被 run2b 取代）/ `f09p3r5l3-run2b.sh`
- 日志：`f09p3r5l3-tsc.log`（exit 0）/ `f09p3r5l3-jest.log`（44/44）
