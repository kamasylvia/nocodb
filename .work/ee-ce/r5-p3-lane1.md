# F09 P3 R5 修复回归（冲刺轮） — lane 1 报告

**结论：PASS — 0 error + 0 minor**
审查基线 = 45032e45b0（R4 修复批）；`git diff 45032e45b0..HEAD`（33a13db54a dispatch）仅 .work 流程文件，src/nc-gui **零行变更**。后端 :8080 活体口径成立：pid 72234（05:55AM 起）加载 `~/.nocodb-run/.../dist/main.js`（mtime 05:31，dist 内 grep 到修复注释 `never echo it over HTTP`），进程晚于 dist、dist 含修复。
账号 f09p3r5l1-{api,ui,ed,p1..p5}@ce-ee.local（账号行保留于 dev 实例，历轮口径）；测试数据 5 base 残留全部 DELETE=200，bases 列表 0 残留，/tmp 物料全清。

---

## 1. 质量门（全过）

| 门 | 结果 |
|---|---|
| `npx tsc --noEmit` | exit 0（`f09p3r5l1-tsc.log`） |
| `npx jest --testPathPattern 'Fork'` | **44/44**（3 suites，与基线一致；`f09p3r5l1-jest.log`） |
| Vite URL 编译门（`/_nuxt/` 前缀） | CreateNewSync.vue 200（59KB）/ SyncMenuOptions.vue 200（36KB，编译产物含 `isConvertConfirmOpen`×7、`convertToRegularTable`×3）/ useEeConfig.ts 200（gate 键全在）/ useTableSync.ts 200 |

## 2. R5 核心：R4 E1 修复回归（活体）

### 源码
`table-syncs.service.ts:1132-1135` — `resync()` 返回净化形态 `{ id: job?.id, name: job?.name, status: Syncing }`，job 对象不再进 HTTP 序列化。`createSync` 走 `getSync` 净化返回（:772）。全仓 `TableSyncRun` 投递点仅 service `enqueueSyncJob` 与 realtime helper `claimAndEnqueue`；jobs 路由仅内部 listen，无 job.data→HTTP 其它通路（复核 R4 lane3 结论仍成立）。

### 活体（run1 §4 + 定点探针）
| 项 | 结果 |
|---|---|
| resync HTTP 200，响应体 **69 字节**（修复前 ~35KB） | ✓ |
| `keys` 恰为 `["id","name","status"]` | ✓ |
| 调用者 xc-auth JWT **尾 16 字符 grep 0 命中** | ✓ |
| `rawHeaders`/`socket`/`cookies`/`_readableState`/`headers`/`req` 键 0 命中 | ✓ |
| 响应 `status=syncing`（状态机翻转入响应） | ✓ |
| resync 本体不受影响：`sync_job_id` 在 Syncing 窗口 = 响应 `id`（`job92wi...` 精确一致 = job 真实入队）→ 终态回 `active` → 镜像拉数 mirror=3 | ✓ |
| manual sync 走同一 resync 端点，响应同净（token 尾零命中） | ✓ |

## 3. 站位全回归（P1+P2+P3 矩阵）

### 活体① run1（20 PASS / 1 伪影）
- realtime 四写：单插/单改/单删收敛/bulk 数组体插 3 行 — 全部秒级传播 ✓
- 防环稳定性：连续 5 写后 src=11=mirror=11，无自激无级联 ✓
- AUTO 双档：realtime 自动传播；manual 8s 不自播 → Sync now 追平 ✓
- 幂等复跑：resync 后 mirror=11 不变 ✓

### 活体② run2/2b/2c（paste 全链 + 窗口 + 字段 + 漂移 + detach）
- paste 全链：resolve-link 三态（无密码=仅 `{passwordProtected:true}` 单键 / 错密码 400 / 对密码 200）+ source-schema 无密码零泄漏 ✓；createSync(paste) → 镜像仅 Name 列 + 3 行 + 凭据剥离（无 source_uuid/hash 出参）✓；paste realtime 传播 ✓
- selected_fields：camelCase `selectedFields` 加 Qty 列出现+数据传播；snake_case 删 Qty 列消失；收窄后增量仍走 ✓
- 类型漂移：源 Qty Number→SingleLineText → resync → 镜像 uidt 跟随 ✓
- resync 复检：allow_sync 关→400 / 开→200 ✓
- mark_deleted：删源行 → 镜像行留 RemoteDeleted=true、行数不变 ✓
- detach：synced=false + 镜像可写 200 + 源再写不传播（realtime 截断）✓
- **Syncing 窗口收敛（历轮口径，realtime sync）**：700 行大源 resync 中窗内三写（插 win_new/改 big_1=99999/删 big_2）→ t+12s 收敛：win_new 在/big_1 改在/big_2 sweep 无 ghost/src=703=mirror=703 ✓（run2c 打点全过程在案）
- **paused 窗口（realtime sync）**：freeze → 三写 → 镜像冻结 → resume → 三腿全追平 ✓（run2 §7，paste+realtime）
- **manual sync 窗口语义**：freeze 窗内写 → resume 后 8s 不自动追平（设计语义，源码 :91 `sync_trigger=realtime` 硬过滤 + :35/:78 注释明言）→ **Sync now 一次收敛**（窗内写不丢失）✓（run2c §3）

### 活体③ ACL + 守卫链（run3，11 PASS / 0 FAIL）
| 格 | 象限 | 结果 |
|---|---|---|
| 1 | 非私有 + editor | 200 ✓ |
| 2 | 非私有 + no-access | 404 ERR_BASE_NOT_FOUND ✓ |
| 3 | 非私有 + 无 base 行 | 404 ✓ |
| 4 | 私有 + editor | 200 ✓ |
| 5 | 私有 + no-access | 404 ✓ |
| 6 | 私有 + 无行 | 404 ✓ |

- editor 11 端点（list/get/source-schema/create/patch/delete/resync/freeze/resume/resolve-link/**detach**）= **11/11 403** ✓
- editor 直写镜像 = 400（readonly 守卫链，非 200）✓
- 防环七处 tap 为 R4 已详审面，基线后零代码变更（diff 空），不重审

### 活体④ UI（camoufox session f09p3r5l1，本轮子代理环境可用）
- **向导双模式**：「浏览/粘贴链接」radio 双 tab ✓；paste 档切出「共享视图链接」URL 输入 ✓
- **向导设置双档**：「同步方法」自动（realtime）/手动 双 radio + 「源删除记录」双策略，全中文 ✓；UI 走 browse+realtime 全链创建成功（API 复核 trigger=realtime、status=active、镜像建立）✓
- **树菜单三态**：普通表=重命名/复制/删除（无 sync 项）；active 镜像=**同步入口/立即同步/暂停同步/转换为普通表/删除同步** 五项中文；paused 镜像=**「已暂停」标记 + 恢复同步**（替代暂停）——截图 `/tmp` 已随清理删除，文本证据在案 ✓
- **删除流三腿**：菜单删除→确认弹窗（标题「删除同步」、按钮 取消/删除同步）→ Cancel 腿 sync 保留（API count=1）→ 确认腿 sync=0 + 树节点移除 ✓
- **Convert 确认弹窗 zh-Hans**：标题「转换为普通表」+ 按钮「取消/转换为普通表」+ body `ui_src_t — "ui_src_t"`，零英文回退 ✓；Cancel 后 sync 仍 active ✓
- **editor 卡 gate**：editor 打开空 base 引导页「无可用操作」，无「表同步」卡片（owner 对照有）——`isUIAllowed('sourceCreate')` gate 活体成立 ✓

## 4. 发现（0 error + 0 minor；以下为观察，不计数）

- **O1** `enqueueSyncJob`（service :839）仍将完整 `req` 对象放入 `job.data.req`，未按 realtime helper 先例（table-sync-realtime.ts:146-148 minimal shim）收敛。HTTP 响应面已关（E1 主修复成立），残留面仅在队列内部内存对象；建议后续轮把 req 替换为 shim 一行加固。
- **O2** manual sync 的 paused/Syncing 窗内写不自动追平、靠下次手动 run 收敛——与源码注释（realtime helper :35、:78）设计一致，run2c 活体证实「Sync now 一次收敛不丢数据」。语义记录在案，防后续轮误判。
- **O3 流程教训**：UI 会话存活期间用同一账号做 API signin 会触发 token_version 互踢致前端掉登录（本轮两次 Network Error 均此因，非产品问题）。已改 infra 账号做 API 检查。「UI/API 账号分离」纪律含 API 侧 signin 也不得共用 UI 账号。
- **O4** 本轮 5 个 FAIL 均归因为测试脚本伪影并复核澄清：①resolve-link 传 `url` 应为 `sharedViewUrl`（2a/2c）；②mark_deleted 语义下 paused 判据误把既有行当泄漏、误期望行消失（7b/7d）；③Syncing 窗口场景误用 manual sync（run2 #9、run2b #4，realtime 口径 run2c 全过）；④sync_job_id 在 job 完成后清空，轮询到 active 才读必然 null（4.8，定点探针证实入队真实）。

## 5. 清理记录
- 5 个残留 base（含首轮 ACL 脚本跑挂遗留 2 个）全部 DELETE 200；`f09p3r5l1` 前缀 bases 列表 0 残留。
- /tmp 下 id/token/响应转储（含 token 尾指纹物料）、bulk payload、截图全部删除；脚本内仅含本地 dev 测试账号口令（红线允许项）。
- camoufox session `f09p3r5l1` 已 close。
- f09p3r5l1-* 账号行保留于 dev 实例（无用户删除 API，历轮口径一致）。

## 6. 产物
- 脚本：`.work/ee-ce/f09p3r5l1-run1.sh` / `f09p3r5l1-run2.sh` / `f09p3r5l1-run2b.sh` / `f09p3r5l1-run2c.sh` / `f09p3r5l1-run3.sh`
- 日志：`f09p3r5l1-tsc.log`（exit 0）/ `f09p3r5l1-jest.log`（44/44）
