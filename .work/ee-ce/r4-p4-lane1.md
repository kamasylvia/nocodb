# F09 P4 R4 — lane 1（站位回归 + R3 小修收尾验证）报告

**结论：PASS / 0 error + 1 minor**

审查基线 = 840c4218aa（R3 后零代码功能变更核验：`git diff 840c4218aa HEAD` 仅 `.work/ee-ce/r3-p4-lane-prompt.md` 一个流程件；工作树无非 .work 改动）。后端 :8080 存活（pid 38535，`GET /api/v1/health` → 200），dist 双条件核验：`~/.nocodb-run` dist mtime 2026-09-22 01:34 < 进程启动 01:41:12 ✓，且运行 dist 内 grep 命中守卫特征串（`manage the links in the source table` ×2、`F09 P4-R2(lane3 E1)` ×1、`ERR_SYNC_TABLE_OPERATION_PROHIBITED` 族 ×7）→ **:8080 运行的确含 R2 E1 修复，与 R3 同一 dist/进程**。账号前缀 `f09p4r4l1-*`（owner/editor API 账号 + ui/uied UI 账号 + pr/pn 探针账号，UI/API 分离）；camoufox session `f09p4r4l1`。脚本：`f09p4r4l1-run1.sh`（三层+v3 守卫，ALL PASS）、`f09p4r4l1-run2.sh`（updateSync 级联+双 shadow，ALL PASS）、`f09p4r4l1-run3.sh`（AUTO+窗口收敛+mark_deleted 两档，ALL PASS）、`f09p4r4l1-run4.sh`（paste 面+E1 六格+ACL，ALL PASS）、`f09p4r4l1-ui-setup.sh`（UI 环境）。

## E 系列

无。

## R3 验证项同规格复跑（全部通过）

**1. v3 通道守卫活体（run1，三层 sync：mirror+shadow+junction，junction 初始配对 2）**

| # | 断言 | 实测 |
|---|---|---|
| 1 | owner 对镜像 `POST/DELETE /api/v3/data/{dest}/{modelId}/links/{colId}/{rowId}` | **422** `ERR_SYNC_TABLE_OPERATION_PROHIBITED`（Link operations ... prohibited）✓ |
| 2 | **editor** 对镜像 v3 POST/DELETE | **422** 同码，症状 200/201 不复现 ✓ |
| 3 | 拦截后 junction 配对数 | 仍 = 2，无部分写入 ✓ |
| 4 | 合法路径：owner 源表 v3 POST；editor dest 普通表 v3 POST/DELETE | 200 / 200 / 200，无误伤 ✓ |
| 5 | 读路径：owner v3 GET 镜像 links | 200（返回 shadow 关联数据）✓ |
| 6 | owner v3 PATCH 镜像标量 | 400 `Column "Title" is readonly...`——P1 镜像 readonly 既有语义 ✓ |
| 7 | P2 站位：editor junction 直写 / editor bulk 删镜像行 | 422 / 422 ✓ |
| 8 | 引擎通道：源加配对 → resync | junction 2→3，raw-knex 通道照常 ✓ |

**2. updateSync link 级联 + 双 shadow 共享（run2，源同 RT 双 link 列 T2s/T2sAlt）**

- createSync selected_fields 含 link（不含 T2sAlt）→ mapping main×1 + linked_shadow×1 + junction×1，full-create 后 junction 配对=2 精确。
- **keep-link PATCH**（乱序同集合）→ 200；镜像 link 列 id 不变（无拆毁重建）、junction=2 不变、mapping 稳定。
- **加腿 PATCH**（+T2sAlt 同 RT）→ junction mapping 1→2，**shadow 共享同一张表**（id 不变）；**自动 full-resync 回填** junc2 配对=1（R1「静置 junction=0」不复现）；原 junc1=2 不变。
- **删腿 PATCH**（-T2sAlt）→ 镜像列删、junction2 mapping 撤、**共享 shadow 被保留 link 引用不误删**（引用计数语义）、junc1=2 不变。
- **null PATCH**（显式 `selected_fields:null`）→ T2sAlt 列+junction mapping 补齐 + 自动 resync 回填配对=1（null=全字段含全部 syncable links）。
- **`[]` PATCH → 400**（`selectedFields must be a non-empty array or null`）。
- editor PATCH sync → 403。
- 备注：updateSync 接受 camelCase `selectedFields`（P2-R3 别名归一，service `updateSync` 入口规范化），与「createSync 蛇形不认」已知遗留是不同入口，无新问题。

**3. AUTO 双档 + 窗口收敛 + mark_deleted 两档（run3，双 realtime sync 同源：SyncM=mark_deleted / SyncA=delete，各含 link 层）**

- **AUTO realtime**：源插 p5+建 link → SyncA 镜像 ≤2s 出现 p5；SyncM junction 经 full-resync 同步至 3 配对。
- **mark_deleted 增量档**：源删 p1（realtime tap 增量路径）→ SyncM 镜像 p1 行保留且 `RemoteDeleted=true`、junction 配对 3→2（p1-n1 清理）；SyncA（delete 档）同事件镜像行删除、junction 同步清理——**两档一致** ✓。
- **Syncing 窗口**：删 p3 后立即插 p6 → p3 删净 + p6 回填（增量直入或 run 后 catch-up 兜底，终态收敛）✓。
- **paused 窗口**：freeze → 删 p2（有配对）+ 插 p7 → resume（resume 自带 catch-up 再入队）→ **catch-up 全量 pass 含 sweep**：p2 刷除、p7 回填、junction 清到 1（p2-n2 配对随 sweep 清理）✓。
- **freeze 档**：paused 期间源插 p8 不进镜像（免疫）→ resume 后 catch-up 回填 p8 ✓。

**4. paste 面（run4）**

- resolve-link：合法共享视图 URL → 200；假 uuid → 400。
- paste sourceSchema **不列 link 列**（columns=[Title,Qty]，无 Bs）。
- **paste 纯标量 createSync**（显式 `selectedFields:["Title","Qty"]`）→ 200，full-create 镜像 3 行。
- **paste+link createSync → 400**，消息含 browse-mode 指引（凭据单视图暴露，link 同步拉全相关表——P4-R1 安全裁定语义不变）。
- 密码三态：无密码 → `{passwordProtected:true}`；错密码 → 400 `Invalid shared view password`；对密码 → 200 ✓。
- createSync / getSync 响应零命中 `source_uuid` / `source_password_hash`。

**5. E1 六格 + 四象限站位（run4，探针 pr=ws editor / pn=ws 无关系）**

- 四象限（无显式 no_access）：非私有+零 base 行+ws 可读 → 200；非私有+零关系+ws no-access → 404；非私有+显式 editor+ws no-access → 200 ✓。
- **E1 六格**（显式 base no_access，F09 source-schema / 平台 GET base 对照）：
  ① 非私有+no_access+ws 可读：**404 / 403** ✓
  ② 非私有+no_access+ws 不可读：**404 / 403** ✓
  ③ 私有+no_access+ws 可读：**404 / 404** ✓
  ④ 私有+no_access+ws 不可读：**404 / 404** ✓
  ⑤ 私有+no_access → createSync：**404**（`ERR_BASE_NOT_FOUND`，数据面不落镜像）✓
  ⑥ 非私有+no_access → createSync：**404** ✓
- 恢复正路径不误伤：pr 改回 editor 后 source-schema → 200 ✓。
- 操作勘误（供后续 lane）：base 用户 role 的服务端校验字面量是**连字符** `no-access`（`no_access` 下划线拼写 POST/PATCH 均 400——即 P1 已裁定的 legacy fail-closed 项，本轮实测与之一致，不另立项）；base users 列表响应嵌套在 `.users.list`。

**6. ACL（run4）**

editor 对 table-syncs **11 端点**（list / get / create / source-schema / update / resync / freeze / resume / detach / delete / resolve-link）→ **全 403** ✓。

**7. UI 活体（camoufox session f09p4r4l1，ui 账号 owner / uied 账号 editor）**

- **向导三层**：Browse 三步向导（base 可搜索下拉 → 源表 → All fields 默认全选含 link → 触发/策略步）→ Create sync → 树出现 mirror `f09p4r4l1_ui_t1` + shadow `f09p4r4l1_ui_t1 f09p4r4l1_ui_t2`（junction 按设计不入树）✓（截图 f09p4r4l1-wizard-created.png）。
- **树菜单三态 + 新鲜度**（不刷新页面）：active 菜单 = 立即同步/暂停同步/转换为普通表/删除同步（截图 f09p4r4l1-menu-active.png）→ 暂停同步后重开 = 恢复同步（f09p4r4l1-menu-paused.png）→ 恢复后回到暂停同步；立即同步后重开菜单无 Syncing 卡态 ✓。
- **zh-Hans 弹窗**：语言切简体中文后菜单全中文（重命名 表格/立即同步/暂停同步/转换为普通表/删除同步…，f09p4r4l1-zh-menu.png）；**convert 确认弹窗全中文**——标题「转换为普通表」+ 正文 `f09p4r4l1_ui_t1 — "f09p4r4l1_ui_t1"` + 按钮「取消 / 转换为普通表」，DOM 全文 ASCII 词扫描 = 空（**8de55d0b24 zh-Hans `labels.convertToRegularTable` 修复活体验证通过**）。取消路径实测不动数据。
- **editor 卡 gate**：uied 登录打开 synced 镜像 → aria snapshot 抓到 **`button "新增记录" [disabled]`**（真实 DOM 证据，与 API 422 守卫互证）✓（f09p4r4l1-editor-gate.png）。
- **删除流**：owner 删除同步 → 确认弹窗（f09p4r4l1-delete-confirm.png）→ 确认后**不刷新页面** mirror 与 shadow 即时从树消失、视图自动跳离已删表 ✓。
- 环境态（非缺陷，维持 R3 判定）：dev 前端 :3000 grid 行数据在本 session 仍不渲染（API 200 正常），gate 断言以 DOM aria 为准。

## R3 小修验证

1. **zh-Hans `labels.convertToRegularTable`（8de55d0b24 已落）**：zh-Hans.json:1432 在库 + SyncMenuOptions.vue 三处引用 + UI 活体弹窗全中文（见上）——**收尾确认通过**。
2. **processor/realtime 注释腐化清理后无新问题**：realtime helper 注释内容准确（loadRealtimeTargets 无状态过滤注释与实现一致、watermark catch-up 语义、P4 role 分派）；`watermarkStart` 死导出零引用。**但 processor 侧有一处清理漏网**（见 M1）。

## M 系列（minor）

- **M1（新，comment-only）**：`packages/nocodb/src/modules/jobs/jobs/table-sync/table-sync.processor.ts:246-249` 的 pull-shape 注释仍写「incremental runs without ids (catch-up) run a full upsert pass **WITHOUT the disappearance sweep**」，与同文件 339-347 行 P3-R2(lane4 E1') 实现注释及代码直接矛盾（现行为：无 ids 的 incremental **落入全量 pass 含 sweep**）。该处正是 8de55d0b24「stale watermark/sweep comment rot cleaned in the processor and the realtime helper」声称清理的文件——实测该 commit 对 processor 的 diff 为 **0 行**（只改了 realtime helper），注释腐化在此漏网。零功能影响，仅误导后续维护者；建议下轮顺手改一行。同源化妆问题：realtime helper `table-sync-realtime.ts:86-88` 清理改写后句间换行错位（一句接在上句行尾），内容准确，仅格式。
- （行为记录，不计 minor）**paste 缺省选择（selectedFields 缺省=null=全含 links）在含 link 源表 → 400**：run4 §6a 实测。语义上 null 选择含当前+未来 links，与 paste 凭据安全裁定（P4-R1 lane3b E2「reject」）自洽，属 fail-closed 方向；向导始终显式传字段白名单不受影响。纯标量 paste 须显式 selectedFields，与 R2/R3「paste 纯标量不误伤」结论不冲突（彼时源表无 link 列）。

## 已知遗留（维持，不重复报）

i18n 死键 `msg.warning.syncPasteLinkUnsupported`；spec 缺 v3 通道用例；createSync 蛇形 `selected_fields`；源 link 列删除孤儿；bulkUpdateAll 不 tap；paste resync 不复验 hash；afterBulkRestore CE 无调用方；`no_access` 下划线拼写服务端多拒（本轮在 base-users PATCH 路径再次印证，fail-closed 方向）。

## 质量门

- `npx tsc --noEmit`（packages/nocodb）：**exit 0**。
- `npx jest --testPathPattern 'Fork'`：**60/60，3 suites 全过**（166.9s）。
- Vite URL 门：`npx vitest run test/formula-url-xss.test.ts --config test/vite.config.ts --hookTimeout 60000`：**5/5 过**。

## 未覆盖（环境/范围限制，非「通过」）

1. UI grid 行数据渲染（dev 前端环境态，R3 同）；UI link cell 422 toast 文案展示（后端 422 与 editor gate 已由 API 活体 + DOM disabled 覆盖）。
2. Syncing 窗口的 CAS-miss 日志级观测（API 层以终态收敛断言；DB 级观测 R3 轮已完成，本轮无代码变更）。
3. 删除用户账号：NocoDB 无删除用户 API，`f09p4r4l1-{owner,editor,ui,uied,pr,pn}` 六账号保留（全前缀可辨，历轮同惯例）。

## 纪律

只读审查（`git status` 无非 .work 源码改动；本 lane 仅新增 `.work/ee-ce/f09p4r4l1-*.sh` 脚本、7 张截图与本报告）；未构建/未重启/未 pkill/未跑 `dev-backend*.sh`；无 psql、未提权；隔离未读他路 R4 报告（对照材料 r3/r2/r1 lane-prompt 与 r3-p4-lane3.md 为任务书指定）；测试 base 全部删除（清零核验：`f09p4r4l1*` bases 计数 = 0，run1-4 由 trap 自清、UI 双 base 手动删除），测试记录随 base 删除；camoufox session 已 close --all；无凭证写入 git 跟踪文件（账号口令仅存 `.work` 白名单脚本，历轮同惯例）。
