# R4 P3 lane2 — F09 Sync data P3 生命周期站位回归（R4 冲刺轮）

**结论：0 error + 2 minor —— PASS**

- 审查员：lane 2（账号 f09p3r4l2-api / f09p3r4l2-ed / f09p3r4l2-ui，UI/API 账号分离；camoufox session f09p3r4l2）
- 基线：8de55d0b24 = 本轮开工时 HEAD（复审期间前移的 4f13fd293f 为纯 .work 派单提交，`git diff 8de55d0b24 4f13fd293f -- packages/` 为空，代码基线不变）；后端 :8080 = pid 75970（`~/.nocodb-run` dist，mtime 02:10 + 进程 02:21，R3 修复批部署；8de55d0b24 对后端仅注释改动，不在 dist 内 = 零行为差）。:3000 Nuxt dev 服务 UNITEK 工作树源码（= HEAD，zh-Hans 键已入库）。全程零构建/零重启/零 psql/零源码改动。
- 质量门：`npx tsc --noEmit` exit 0；jest Fork 桶 **3 suites 44/44**；Vite URL 编译法 **4/4 = 200 真产物**（CreateNewSync.vue / SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts，正文含 `__vite__createHotContext` transform 产物，非 HTML 兜底）。
- 活体脚本：`/tmp/f09p3r4l2-{setup,run1,run2,run3,run4,run5,run6,run7,run7b,run8b,cleanup}.sh`；共享后端日志 `/private/tmp/nocodb-internal.log` 按 sync-id 归因（本轮在飞多 lane 并发，未依赖他路流量）。
- 测试数据清理：3 个剩余 sync 全删 200、4 个 base（srcA/baseA + 2 个建向导探针期孤儿对）全删 200、bases 列表 4 页（pageSize=100）`f09p3r4l2` 残留 **0**；我名下 5 个 sync id 日志 `run failed` 命中 **0**。账号 f09p3r4l2-api/-ed/-ui 保留供后续轮次（前轮先例），api/ui 已授 workspace-level-creator（ed 保持 base editor + workspace no-access）。探针期曾设 source 视图 uuid（36 位格式，前缀纪律不兼容故用 hex 假 uuid）随 base 删除一并消除。

---

## 0. R4 增量验证（本轮两专项）

### 0.1 zh-Hans Convert 键（R4 增量 1）✓ 活体

- 源：`zh-Hans.json:1432` `labels.convertToRegularTable: "转换为普通表"`；en.json:1890 对应键在位；消费点仅 SyncMenuOptions.vue 三处（菜单项/弹窗 title/确认按钮）。
- UI 活体（camoufox，zh-Hans locale，经 localStorage `nocodb-gui-v2.lang` 切换 + reload）：同步表树菜单项「转换为普通表」→ 弹窗 **title「转换为普通表」、正文 `-syncB — "-syncB"`、按钮 [取消, 转换为普通表]**（截图 `/tmp/f09p3r4l2-convert-modal.png`）。英文回退零复现。
- 弹窗行为：取消 → 弹窗关、无动作；**真实 Esc keydown → 弹窗关、无动作**（后续确认步成功反证 Esc 未误转换）；确认 → sync 记录删除、镜像表 `synced:false`、数据保留（12 行，mark_deleted 旗标行在内）、转正表可写（POST 200）。

### 0.2 站位全回归总览

| 站位 | 结果 | 关键证据 |
|---|---|---|
| realtime 全链（插/改/删） | ✓ | 单插 wall 331ms、单改 1019ms、单删 661ms（ghost 消失）；日志恰每事件一条 tap |
| bulk 全链（paste 同形态） | ✓ | 数组插 463ms、数组改 1051ms、数组删 1277ms（3 ids 单 tap 非 3 事件）；静默窗 8s 零 churn |
| **窗口 delete 三腿之 realtime 直删** | ✓ | 上行 T3/T6 |
| **窗口 delete 三腿之 Syncing 窗** | ✓ | 2000 行 full-create 中窗内三写（upd/ins/del 全 200）→ run 末 `enqueued watermark catch-up run jobiy95us2jwh8pq1` → catch-up 日志 `[incremental]: source rows=2000 inserts=1 updates=1999 deletes=1` → **c0001 ghost 0 行、镜像=源=2000**（R2 E1' 修复=catch-up 全量 pass 含消失扫描，活体+日志双实锤） |
| **窗口 delete 三腿之 paused 窗（delete 策略）** | ✓ | freeze→三写（a1 改/p-ins 插/p-del 删，全 200）→ 暂停期镜像零泄漏（a1=1、p-del 仍在）→ resume → **三写全追平（a1=777、p-ins-paused 进、p-del ghost 0 行）**、status active |
| **paused 窗变体（mark_deleted 策略）** | ✓ | syncB：freeze→删 a2（200）→ resume 前 RemoteDeleted=false → resume 后 **RemoteDeleted=true**（sweep mark 路径）；realtime 直删路径 ~1s 置 flag |
| manual resync 复检 | ✓ | resync 200 → active，跑前后镜像行数一致（5=5）零重复 |
| AUTO 双档 API | ✓ | `syncTrigger:"manual"` 建成 200 + 手动 Sync now 200；`"realtime"` 200；`"hourly"` 400 `Invalid sync trigger: hourly` |
| AUTO 双档 UI（向导） | ✓ | step3「同步方法」双 radio 在位可选（自动使用/手动操作，截图 `/tmp/f09p3r4l2-step3.png`）；选「自动使用」→ 创建 → API 复核 `sync_trigger=realtime` |
| selected_fields 增删传播（camelCase） | ✓ | PATCH `{"selectedFields":["Title"]}` 200 持久化 → 下一增量新行 Qty=null（字段过滤生效）→ 恢复 `["Title","Qty"]` → 新行 Qty 回填 |
| 源列类型漂移 | ✓ | 源 Qty Number→SingleLineText → 下一增量日志 `propagated column type change Qty: bigint -> SingleLineText`、镜像列型变 SingleLineText、字符串值进镜像 |
| detach 转正（API 腿） | ✓ | detach 200 → sync 消失、镜像 `synced:false`、行保留、可写可删（UI 腿 = 0.1 Convert 流，同 detach 语义） |
| paste 模式 sync（uuid+密码凭据） | ✓ | resolve-link 错密码 400 `Invalid shared view password`、无密码仅回 `passwordProtected:true`（零泄露）、正确凭据建成 200；getSync 响应 `source_uuid/password_hash/明文密码` 三查零泄露；full-create 9 行 + realtime 传播正常；镜像 RemoteId 零重复（双插探针残留下 16/17 双行均独立 RemoteId） |
| ACL 十一端点（editor） | ✓ | editor 对 list/get/create/PATCH/DELETE/resync/freeze/resume/detach/source-schema/resolve-link **全 403**（读端点亦 403 = acl.ts creator+ exclude 段设计，历轮同判 fail-closed）；sync title 未被改动 |
| 守卫链（镜像写拒绝） | ✓ | 单插 400 / bulk 插 400 / bulk 改 400 / bulk 删 422 / v2 bulkUpsert 400（readonly 列拒）/ v1 bulkUpsert（按表 id）owner 400 + editor 400 |
| UI 活体（树菜单/删除流） | ✓ | 树菜单五项中文（同步表/立即同步/暂停同步/转换为普通表/删除同步）；删除流：确认弹窗（取消/删除同步）→ 确认 → sync 删 + 镜像表删 + 树刷新 + 自动跳转（R6/R8 修复保持）；detached 表树图标变普通网格（截图） |
| E1 六格（assertSourceReadAccess） | 未重复全跑 | `git diff f6a9314b5e..HEAD` 证实谓词零触碰（服务层仅 camelCase 归一 + resume catch-up 挂点两处）；本轮以 11 端点 ACL 扫 + 双 base 协作者邀请流复验执行面；谓词逐字矩阵维持 P1 pass + 历轮回归结论 |

---

## 1. Minor

### M1 — 「注释腐化清理」不彻底且 commit message 言过其实（零功能影响）

- 8de55d0b24 自述 "stale watermark/sweep comment rot cleaned **in the processor** and the realtime helper"，但 `git show 8de55d0b24 --stat` 证实 processor **完全未触碰**（该提交只改 zh-Hans.json + table-sync-realtime.ts 一处注释）。三处 stale/自相矛盾注释残留至今：
  1. `table-sync.processor.ts:30-32`（头注释）：「an incremental run with no ids without touched ids falls back to the full pass (upsert + sweep) **and skips the disappearance sweep**」——同句前后矛盾（R2 修复后 catch-up 恰恰**要** sweep，见同文件 321-327 的 R2 修复注释）；
  2. `table-sync.processor.ts:227-230`（pull-shape 注释）：「incremental runs without ids (catch-up) run a full upsert pass **WITHOUT the disappearance sweep**」——与实际 else 分支代码（393-408 无条件 sweep）相反；
  3. `table-sync-realtime.ts:103-104`（claimAndEnqueue docstring）：「the processor falls back to the **RemoteUpdatedAt watermark pull**」——水位机制已整体移除（死导出 watermarkStart 已删），现行为 = 全量 pass + sweep。
- 影响面：纯文档腐化，零运行时行为差；但 R3 lane1 M1 的修复声明只落地了 1/4 处，且提交信息声称的范围与实际 diff 不符——下轮顺手清一处即可（约 6 行注释），非阻塞。

### M2 — 多 base 删除并发窗 503（环境噪声级，记录备查）

- 清理阶段 4 个 base DELETE 首轮集中连发时 3 个 503（无响应体），间隔重试后全部 200（最后一例第 6 次重试成功）；同期 bases list 亦偶发同型失败。判定为多 lane 并发负载/限流窗的环境噪声（本轮 5 lane 共享 :8080），非 F09 代码路径问题（base delete 非 F09 改动面）；重试即收敛，最终 4 页零残留。仅记录，供后续轮清理脚本加退避。

---

## 2. 方法学注记

- **探针缺陷两例（非产品回归，同 R1/R2 lane 教训）**：①初版用 `Authorization: Bearer` 打 JWT 面——本仓 JwtStrategy 只读 `xc-auth` header / `nc_token` cookie（jwt-strategy.provider.ts:17-20），Bearer 进 AuthTokenStrategy 的 ApiToken 查找必得 401 "Invalid token"（authtoken.strategy.ts:20-24），改 `xc-auth` 后全通；②paste-rt 双行疑云复判：run8 首版探针在 createSync 失败后仍向源表 POST 了该行，两次独立源行（Id 16/17）经 realtime 各自正确进镜像（RemoteId 零重复）——产品无恙。
- 窗口腿时序证据：Syncing 窗三写落于 full-create 在飞段（createSync +0.3s 起、run ~7s 后回 active），claim miss → markSkipped → run 末 catch-up 链条在日志完整闭环（`claim missed (syncing/paused)` debug 行 + `enqueued watermark catch-up run`）。
- 共享 :8080 多 lane 并发流量在日志可见，本 lane 全部结论按自有 sync id（tssx4f7ja311d0fv0 / tsscmw32nd5czk57m / tsspstqjz7he3t6pl / tss00uqvcmiiawdof / tss5fmt5jc2lqv2zp）归因。
- 向导 browse 模式源选择器（NcSelect show-search）对合成 eval 点击不稳（rc-select 虚拟列表），改走粘贴链接腿完成向导全流程——UI 组件对真实鼠标工作正常（截图为证），非缺陷；browse 腿的源列表本身渲染正常。
- 未覆盖（他路站位或本轮裁剪）：editor Overview 卡 gate 的 UI 腿（ACL 已 API 面 403 全拦）、Syncing 中 convert/delete 菜单隐藏项（模板 v-if，P1 已验）、E1 六格全矩阵重复跑（谓词零触碰，见 §0.2 末行）。
