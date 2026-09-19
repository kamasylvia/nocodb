# F09 P3 R5 修复回归（冲刺轮）— lane 2 报告

**结论：PASS — 0 error + 0 minor**

审查基线 = 45032e45b0（R4 修复批，HEAD）；活体口径成立：工作区 dist 与运行 dist md5 一致（10c3469c62997b30e26f90adffc71dca），进程 72234（05:55:03 起）晚于 dist mtime（05:31），health 200 全程。
账号 f09p3r5l2-{api,ui,ed,grid}@lantest.local（UI/API 账号分离，UI 活体用 ui/ed 账号）；workspace 授予经 f01e2e@ce-ee.local（历轮口径，base 由 infra 建、lane 账号邀为 owner）。

---

## 1. 质量门（全过）

| 门 | 结果 |
|---|---|
| `npx tsc --noEmit` | exit 0（`f09p3r5l2-tsc.log`） |
| `npx jest --testPathPattern 'Fork'` | **44/44**（3 suites，`f09p3r5l2-jest.log`） |
| Vite URL 编译法 | CreateNewSync.vue 200 (59KB) / Sync/index.vue 200 / Permissions.vue 200 / useEeConfig.ts 200 / useTableSync.ts 200 / **SyncMenuOptions.vue 200（实际路径 dashboard/TreeView/Table/，36KB，编译产物含 `isConvertConfirmOpen`×7、`convertToRegularTable`×3、`labels.convertToRegularTable` 消费点）** |
| zh-Hans.json | `labels.convertToRegularTable=「转换为普通表」`(:1432)、`convertToPlainTablesDesc`(:1435)、`general.cancel=取消` 全在 |

## 2. R4 error（E1 resync 凭据回显）修复回归（活体）

**修复确认，全部收敛：**

- **响应形态**：`POST .../table-syncs/:id/resync` 响应体 = 恰 `["id","name","status"]` 三键，**69 字节**（R4 泄漏时 ~35KB）
- **凭据零回显**：调用者 xc-auth token 尾 12 字符在响应体 grep **0 命中**；`rawHeaders`/`socket`/`_readableState`/`cookies`/`xc-auth`/`authorization`/`password` 全部 0 命中
- **resync 功能本体不受影响**：响应 `status=syncing`；`sync_job_id == 响应.id`（job 真实入队）；运行完状态机翻转 syncing→active、`sync_job_id` 清 null、`last_synced_at` 置位、`last_error=null`；幂等（mirror 5→5）；带新行 resync 拉数（6 行）
- **守卫链**：paused 时 resync 400 / allow_sync off 时 400 / **Syncing 窗口内 resync 400**（big 表 full-create 中实测）/ 不存在 id 404

源码面：`table-syncs.service.ts:1132-1135` 固定返回 `{ id, name, status: Syncing }`；realtime 路径 `claimAndEnqueue` 本就只投最小 req shim（table-sync-realtime.ts:146-148）。**观察（不计数）**：service 侧 `enqueueSyncJob`（:839）仍把完整 Express req 放进 job.data——但队列 Provider 恒为 fallback 内存队列（jobs.module.ts:82 `useClass: FallbackJobsService`，无 Redis 变体），job 模型只持久化 id/job/status/result/fk_user_id（Job.ts:34-40），完成后 `removeJob`；jobs-meta controller 只吐 Job 元行不吐 queue job.data。即 req+JWT 仅存活于本进程内存的运行窗口，无第二 HTTP 回显面（全仓 grep 复核）。R4 裁定的返回形态修复已消解 error 本体，此为纵深防御余量，不构成暴露面。

## 3. P1+P2+P3 全矩阵站位（活体）

### run1（E1 回归 + resync 本体）29/30，唯一 FAIL 为脚本 jq 断言缺陷
见 §2。`sync_job_id` 清理断言误用 `jq //`（null→"x" 永不等于 "null"），事后直查确认产品行为正确（原子置 null）。

### run2 — realtime 四写 + 防环 9/9
单插 r7 / 单改 r1(Qty=111) / 单删 r2 / **数组体 bulk 插 r8+r9** / bulk 删 r8+r9——五腿全 8s 内传播；稳定窗口 src=mirror=6 精确持平，源 r1 仍 111（无镜像→源回流）。

### run3 — paused/Syncing 窗口 9/9
- **paused 窗口**：freeze → 三写（插 p1 / 改 r3=777 / 删 r4）→ 镜像冻结 6 行不动、值不变 → resume → **三腿 1s 内全部追平**（count=6 精确）
- **Syncing 窗口**：big 表（1005 行）full-create 中三写（插 big_win / 改 big_1 / 删 big_2）→ 窗内 resync 400 → 收敛：big_win 在 / big_1 更新在 / big_2 消失扫除 / **mirror=1005=src 精确持平**（markSkipped→catch-up 全量 pass 含 sweep 生效）

### run4 — paste/AUTO/selected_fields/漂移/detach/mark_deleted 25/25（7 个初判 FAIL 全为脚本伪影，已修复复测）
- **paste 全链**：无密码 → 响应恰 `{"passwordProtected":true}` 单键；错密码 → 400（resolve-link 与 source-schema 双路）；对密码 → 200 坐标；source-schema 列正确、零凭据键；share PATCH 密码位 `__NC_PASSWORD_MASKED__`
- **paste createSync**（selectedFields=[Title]）→ 镜像仅 Title+系统列 + 3 行；源插 t4 → 8s 内传播
- **AUTO 双档**：manual sync 源写 8s 不自播 → Sync now 追平；realtime 对照组自动传播
- **selected_fields**：camelCase `selectedFields:["Name"]` PATCH 生效（Qty 列删）；snake_case 恢复 → 列回来且数据随下次 resync 回填（updateSync 列手术设计为 active+idle 即时、数据随 run——代码路径 :972-1024 无入队，确认设计）
- **类型漂移**：源 Qty Number→SingleLineText → resync → 镜像 uidt **2s 跟随**，数据完好（r1=111）；还原后跟随回 Number。（初测 FAIL 系脚本列 PATCH 打错路由 404——源列从未变型，镜像保持 Number 是正确行为）
- **mark_deleted 腿**：专建 sync（onDeleteAction=mark_deleted）→ 源删 p1 → resync → 镜像行保留、`RemoteDeleted=true`、count 不变
- **detach**：`{ok:true}` → sync 从 list 移除（list 为数组，sync2 不在）→ 镜像可写 200 → 源再写不传播（count 稳定）

### run5 — editor 守卫链 + 六格 ACL 17/17
- **editor 11 端点全 403**：list/get/create/source-schema/resolve-link/patch/delete/resync/freeze/resume/**detach**；editor 直写镜像 400（readonly 守卫链）
- **六格**（caller=grid 账号自有 GRIDDST，探源 base 角色）：非私有+editor 200 ✓ / 非私有+no-access 404 ✓ / 非私有+无行 404 ✓ / 私有+editor 200 ✓ / 私有+no-access 404 ✓ / 私有+无行 404 ✓（`ERR_BASE_NOT_FOUND` 短路活体，与 R4 终版口径一致）

## 4. UI 活体（camoufox-cli session f09p3r5l2，实机点击）

注：browser-use MCP 在子代理不可用（"Browser is not available in subagent"，与 R4 lane3 同因），但 **camoufox-cli 本轮实测可用**，UI 活体以实机完成（R4 lane3 的静态补偿路径本轮升级为活体）。

- **向导双模式三档**：新建→表同步向导（中文）；模式 radio「浏览/粘贴链接」双档；**三组选择档**——字段（所有字段/特定字段）、同步方法（自动—实时/手动—立即同步）、删除策略（镜像删除/镜像保留）。浏览模式全链（选 base→表→设置→建 realtime sync，镜像入树）；粘贴模式全链（贴 U5 uuid URL→解析→建 sync，镜像 `f09p3r5l2_ui_t_1` 入树）。浏览列表正确排除当前 base（`b.id !== destBaseId`）
- **树菜单三态**：active=立即同步/暂停同步/转换为普通表/删除同步 四项；paused=恢复同步 替换暂停项；syncing 态 Convert/Delete v-if 隐藏（源码 :181,208 + API 层窗内 resync 400 已活体，UI 瞬态未捕捉，静态成立）
- **删除流三腿**：删除弹窗（标题「删除同步」+「取 消」/「删除同步」）→ Cancel 腿弹窗关节点在 → 重开确认腿 → 节点从树消失、无空白帧
- **editor 卡 gate**：editor 开 DST，**「新建」按钮整体缺席**（creator+ gate）；镜像表 context menu 仅剩「表格编号」，**零同步项**；镜像「新增记录」禁用（readonly UI 层联动）
- **zh-Hans 弹窗**：Convert 确认弹窗标题「转换为普通表」、按钮「取 消」+「转换为普通表」——**零英文回退**（R4 增量活体实锤）

## 5. 测试脚本伪影记录（全部当场甄别修复，非产品问题）

1. `declare -A` macOS bash 3.2 不支持 → 平铺重写
2. base users 列表响应为 `{users:{list:[…]}}` 嵌套，jq 路径首测为空 → 修正后六格过
3. 列类型 PATCH 误打 `/meta/bases/:id/meta/columns/:id`（404 静默）→ 正确路由 `/api/v2/meta/columns/:id` 后漂移跟随实锤
4. share POST body 密码被忽略（密码须 PATCH view 设置）→ 修正后 passwordProtected 三态全过
5. `jq '//'` 对空串/null 的真值语义两处误判（sync_job_id、镜像 Id 列 system 标记）→ 直查纠正

## 6. 清理记录

- 5 个 base（SRC/DST/UIBASE/GRIDDST/SRCP-private）经 infra 账号全部 DELETE=true；api/ui/grid/ed 四账号视角 `f09p3r5l2-*` base **0 残留**；探针 sync/镜像随 base 级联
- `.f09p3r5l2-*` token 文件（4 账号 + infra）与 id/响应缓存文件全部删除；/tmp 无残留（smo 编译转储、camoufox pid/sock 已清，session 已 close）
- 保留：`f09p3r5l2-{setup,run1..run5}.sh`（仅含本地 dev 测试账号口令，红线允许项）+ tsc/jest 日志
- f09p3r5l2-* 账号行保留于 dev 实例（无用户删除 API，历轮口径一致）

## 7. 产物

- 脚本：`.work/ee-ce/f09p3r5l2-setup.sh` / `f09p3r5l2-run1.sh` … `f09p3r5l2-run5.sh`
- 日志：`f09p3r5l2-tsc.log`（exit 0）/ `f09p3r5l2-jest.log`（44/44）
