# R4 P3 lane4 — 引擎重点路（窗口 delete 收敛 / bulk / 幂等 / 风暴）站位回归报告

**结论：PASS — 0 error + 2 minor**

- 审查员：lane4（f09p3r4l4-*）；camoufox session `f09p3r4l4`
- 基线：8de55d0b24（R3 后零功能变更）= HEAD 4f13fd293f 的功能面；:8080 = pid 75970（起 02:21:11）运行 `~/.nocodb-run/.../dist/main.js`（mtime 02:10 < 进程启动；dist 内 grep 到 R3 特征串 `catch-up could not see in-window` 等）——确为修复后 dist。全程零构建/零重启/零 dev-backend 操作/零 psql 提 super。
- 质量门：`npx tsc --noEmit` **exit 0**；jest Fork 桶 **44/44**（3 套件）；Vite URL 编译法 **4/4 = 200 text/javascript 真 transform 产物**（CreateNewSync.vue / SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts）。
- 活体脚本：`.work/ee-ce/f09p3r4l4-run1.sh`～`run7b.sh`；后端日志 `/private/tmp/nocodb-internal.log` 按 sync-id 归因。

---

## 0. PASS 面（引擎重点四项 + R4 增量 + 站位全回归）

### 0.1 Syncing 窗口 delete 收敛（本轮引擎重点，R2 E1' 四路同判的修复验证）

- 1623 行源表（8 批×200 bulk inflate，5s 内全进镜像）→ POST resync（status=syncing 实证）→ **窗口内三写全 200**：DELETE×2（big-1-5 / big-2-7）+ PATCH（big-3-9 Qty=919）+ INSERT（win-ins）→ resync run 结束即自动 `enqueued watermark catch-up run joblojdrnsmny7l8y` → catch-up 日志 `[incremental]: source rows=1622 inserts=1 updates=1621 deletes=2` —— **deletes=2 = 消失扫描（sweep）把窗口内删除的行清了**。
- 终态：镜像 totalRows=**1622 精确**（1623−2+1）、双 ghost 行 `null`、win-ins 在、big-3-9 Qty=919、status=active、last_error=null。**R2 四路同判的 E1'（窗口 delete 静默发散）症状零复现**。
- 关键时序证据：resync 当轮 `updates=1623 deletes=0`（快照拉取在删除前）→ 补齐轮 deletes=2 收敛——「窗口事件不丢」全链闭合。

### 0.2 paused 窗口三腿收敛（含 delete 腿）

- freeze → 三写（PATCH a1 Qty=4242 / INSERT paused-ins / DELETE bulk-3，全 200）→ 行级零泄漏实证：镜像 a1 Qty=1（旧值）、paused-ins `null`、bulk-3 活行 RemoteDeleted=false。
- resume → **955ms 内三腿全追平**：bulk-3 ghost gone、paused-ins 进、a1 Qty=4242、count=23 精确；日志 `enqueued watermark catch-up run joby5k07t2dfzmbex` → `[incremental]: source rows=23 inserts=1 updates=22 deletes=1`。

### 0.3 mark_deleted 策略腿（第二 sync 同源 1622 行）

- freeze → DELETE big-4-4 → 窗口内行级零泄漏（RemoteDeleted=false ×3 连测，受控复现）→ resume → **~2s RemoteDeleted=true**（catch-up `updates=1622 inserts=0 deletes=0` = 全 pass 保行打 flag）。

### 0.4 bulk 数组体传播 + 事件风暴队列行为

- v2 数组体 POST 3 行 → 日志**恰一条** `enqueued incremental run (insert, 3 ids)` → 镜像 5→8 亚秒级；静默窗 8s 零 churn。
- 风暴：15 连发单 insert → **15/15 进镜像**、RemoteId 重复组=0、status=active、`run failed`/`catch-up enqueue failed` 均 0 条；收敛形态 = 1 增量 job + 1 次 catch-up full pass（非 15 排队 job）。

### 0.5 补齐幂等复跑

- 两轮「freeze→无写→resume」空窗后：镜像行内容逐字节一致（win-ins 行 JSON 三次相同）、count 1622→1622 稳定、无重复行/无 churn。

### 0.6 R4 增量：zh-Hans Convert 弹窗键

- `zh-Hans.json:1432` `labels.convertToRegularTable = "转换为普通表"`（R3 8de55d0b24 补入）。
- `SyncMenuOptions.vue:228/:249` 弹窗标题与确认按钮均消费该键，cancel/confirm 双 data-testid；Esc/Cancel 流程 R3 lane5 已活体验证（含真实 Esc 键）。
- 运行时证据链：zh-Hans.json 经 Vite 编译 URL 可达 + **运行时 fetch 该 JSON 返回 `convertToRegularTable=转换为普通表`**（camoufox 内 eval 实测）；UI 全局中文渲染实证（「字段/筛选/分组/排序」「新增记录」中文且 disabled = synced 只读 UI 层同时可见）。
- 方法学注记：树菜单 Convert 活体点击本轮不可达——深链/首页点入均遇**树骨架空**（R1 已记录的框架级 backlog 同族；API 面 tables/synced:true/mappings 全健康）；增量验证降级为上述五点证据链，非产品回归。

### 0.7 站位回归（API 活体）

- **AUTO 双档**：manual sync 建成（`sync_trigger=manual`）、hourly 400 `Invalid sync trigger: hourly`、realtime ×4 建成即 full-create。
- **paste 全链**：share view（uuid+密码）→ resolve-link 错密码 400（`Invalid shared view password`）→ 对密码 200（回 sourceTableId 等，无 hash）→ paste+realtime createSync 建成 → getSync 无 `source_uuid`/`source_password_hash` 泄露。
- **类型漂移**：源 Qty Number→SingleLineText + realtime 写触发 → 镜像列 `uidt:SingleLineText, dt:text` 跟随、drift-probe 字符串值进镜像；**传播后镜像全列 readonly:true 完好**——引擎 bypass 通道不拆守卫链（专项复现验证）。
- **守卫链**：镜像 insert 400（readonly 列拒）/update 400/delete 422 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`（两套独立镜像活体一致）；UI「新增记录」disabled。
- **ACL**：editor resync/detach/freeze/PATCH/createSync 全 **403**、getSync 403（fail-closed 无泄露，R1 裁定的既有观察）；owner 全 200。
- **detach**：200 → getSync **404**、再 detach **404**（幂等无僵尸）、listSyncs 归零、镜像表 insert **200**（synced/readonly 解除即时生效）。
- **resync 复检**：手动 resync 后 src=1621=mirror **EXACT**。
- **R3 注释清理复核**：`watermarkStart`/`WATERMARK_OVERLAP` src 0 hits；processor 头注释与 helper 注释已对齐「full pass (upsert + sweep)」实现。

---

## 1. Minor（不阻塞）

- **M1** `table-sync-realtime.ts` `loadRealtimeTargets` 每事件一次 join 查询且逐 sync 串行 enqueue——风暴下 15 事件 = 15 次相同 join。正确性无损（本轮 15/15 @亚秒收敛），负载线性放大与 R2 M1「大表 catch-up O(N)/次」同族，观察级；可考虑 sync 目标清单短 TTL 缓存。
- **M2** `table-sync-realtime.ts:277-279` 文件尾多余空行（格式/lint 级，随下次改动顺手清）。

## 2. 方法学注记（供裁决）

- 脚本 `req_json` 的 LAST_RC 经 `$()` 子 shell 赋值丢失，脚本内 `rc=` 打印不可靠（会打印残留值）——本轮所有关键断言均以**响应 body + 原始 `curl -w`** 复核定案；报告中凡引 HTTP 码处均经 raw curl 二次验证（如 detach 后 404/404、editor 403×5、守卫链 400/400/422）。
- run5 首次 FLAG0=GONE 为共享 :8080 瞬时异常（探针级），受控复现三次全 false 定案为非产品回归（同 R2 lane3 探针缺陷注记类型）。
- psql 提测试账号时遇 NocoCache 进程内伪影（角色/email stale 回写），以 super 的 `DELETE /api/v2/meta/cache` 清缓存解决——测试环境操作注记，非产品问题；no-redis 部署下进程内缓存对外部 DB 直改不敏感是已知特性（GOAL-STATE F08 已记）。
- UI 树骨架受限期间 grid 深链渲染正常（synced 只读层可见），与 API 面零矛盾。
- 清理口径：f09p3r4l4 前缀 base **API 列表 0**（11 行软删进 trash = 平台统一删除语义，上游既有）、users 0、workspace_user 0；软删 base 内 sync/model 行随 trash 保留属产品语义未硬删。

## 3. 覆盖面声明

本轮覆盖：引擎重点四项全活体 + R4 增量 + 站位回归 API 面。未覆盖（他路站位）：paste 凭据矩阵全量、E1 六格矩阵、UI 向导三步全流程、UI 删除流三腿——本 lane 焦点为引擎与回归收敛面。
