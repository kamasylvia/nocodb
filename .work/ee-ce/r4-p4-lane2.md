# F09 P4 R4 — lane 2（站位回归独立审查）报告

**结论：PASS / 0 error + 2 minor**

审查基线 = 840c4218aa（R2 修复批）。HEAD = 8431d4ed8c，`git diff 840c4218aa..HEAD` 仅 +1 流程件（r3-p4-lane-prompt.md），**零功能代码变更** ✓。后端 :8080 存活（pid 38535，`GET /api/v1/health` → 200），dist 双条件核验：dist mtime 2026-09-22 01:34:28 < 进程启动 01:41:12 ✓，dist 内 grep 命中守卫特征串（`manage the links in the source table` ×2、`ERR_SYNC_TABLE_OPERATION_PROHIBITED` ×7、`linked_shadow` ×9）→ 运行的确含 R2/R3 修复。账号前缀 `f09p4r4l2-*`（API owner/editor/g1-g6 + UI 专用 ui/uie 两账号，UI/API 分离）；camoufox session `f09p4r4l2`。脚本：`.work/ee-ce/f09p4r4l2-run1.sh`（三层+守卫+级联+detach）、`run2.sh`（deleteSync+paste+ACL+realtime）、`run3.sh`（窗口收敛+漂移+E1 六格）、`probe-detach.sh` / `probe-upd.sh`（两个失败定性探针，均为本 lane 脚本 bug 非引擎）、`ui-setup.sh`。三轮 RUN 全部 ALL PASS。

## E 系列

无。

## R3 小修验证（本轮新增检查点）

1. **zh-Hans `labels.convertToRegularTable`**：静态核验 en.json:1890 / zh-Hans.json:1432 两键在 `labels` 域、SyncMenuOptions.vue 三处消费一致。**UI 活体**（camoufox，ui-owner 账号切简体中文）：树菜单全中文（立即同步/暂停同步/**转换为普通表**/删除同步），Convert 确认弹窗标题「转换为普通表」+ 按钮「取消 / 转换为普通表」**零英文回退**（截图 `/tmp/f09p4r4l2-convert-modal.png`）；点确认后转换真实生效——树菜单同步项（立即同步/暂停同步/转换为普通表/删除同步）全部消失，转为普通表菜单（重命名/删除表格等）。**8de55d0b24 修复活体确认，不复现英文回退** ✓
2. **processor/realtime 注释腐化清理**：8de55d0b24 对 table-sync-realtime.ts 的 loadRealtimeTargets 注释改写与现状逐字一致；processor 的 sweep/watermark 注释与现行为（全量 pass 含消失扫描、Syncing 跳过当轮补齐）一致；三个 sync 核心文件零 TODO/FIXME 残留 ✓

## R3 验证项同规格复跑（全部通过）

### v3 LTAR 通道守卫（活体，run1 §5-6）

三层 sync（mirror+shadow+junction，junction 初始配对 2）：

| # | 断言 | 实测 |
|---|---|---|
| 1 | owner 对镜像 v3 `POST/DELETE /api/v3/data/:destBase/:modelId/links/:colId/:rowId` | **422** `ERR_SYNC_TABLE_OPERATION_PROHIBITED` ×2 ✓ |
| 2 | **editor** 对镜像 v3 POST/DELETE（R2 症状 200/201） | **422** ×2，不复现 ✓ |
| 3 | 拦截后 junction 配对数 | 仍 = 2，无部分写入 ✓ |
| 4 | 合法路径不误伤：owner 源普通表 v3 POST（200）；editor dest 普通表 v3 POST/DELETE（200/200） | ✓ |
| 5 | 读路径 owner v3 GET 镜像 links → 200 | ✓ |
| 6 | P2 站位：editor junction 直写 → 422；editor bulk 删镜像行 → 422 | ✓ |

### 三层 link sync + resync 复检（run1 §3-4、§7）

- createSync（selected_fields 含 link）→ main + linked_shadow + junction 三 mapping 齐，junction mapping `source_*=null` ✓；三表 `synced=true`（includeM2M）✓
- full-create 后 junction 配对精确 = 2 ✓
- 源加配对 → resync → junction 2→3；源删配对 → resync → 3→2 ✓

### updateSync link 级联（run1 §8-11，R1 E1 修复回归）

- **keep-link PATCH**：mirror link 列 id 不变、junction 数据在、`last_synced_at` 不变（不投 resync）✓
- **双 link 加腿（同 RT 共享 shadow）**：源加 T2s2 + PATCH 双 link → shadow mapping 仍 = 1（共享）、junction mapping = 2、镜像双 link 列并存、**结构变更后自动 full-resync 回填** T2s2 配对（=1）✓
- **删腿**：PATCH 去 T2s2 → 该 junction mapping 拆除 + junction 表 meta 404 + 镜像列删除；shadow 保留（仍被 T2s 引用）✓
- **`[]` → 400** ✓；**null → 全字段含全部 syncable links**（T2s2 回归、shadow 仍共享 1）✓

### detach / deleteSync（run1 §12、run2 §3）

- **detach**：`{ok:true,tableId}`；mirror 插行 200 + v2 link 写 201（转正可写）。事后探针（probe-detach.sh）定性：detach 后 mirror/shadow/junction×2 四表全部在 bases tables list 且 `synced=false` ✓
- **deleteSync 级联**：DELETE 后 sync GET 404 + mirror/shadow/junction 三表 meta 全 404 + bases tables list 零残留 ✓

### AUTO 双档 + realtime 全链（run2 §6）

- realtime **含 link** sync 直接建成 active（AUTO 实时档解锁不回归）✓
- 标量传播：源插行 → mirror ~2s 出现 ✓
- **link 传播（P4 简化档）**：源加 junction 配对 → `updateLastModified` tap → 自动 full-resync → dest junction 2→3 **~2s** ✓

### 窗口收敛（run3 §3、§5，R2/R3 error 族修复活体）

- **paused 窗口三写**：freeze → paused（期间写不传播：pa-new 未出现 ✓）→ resume → 自动 catch-up **~2s 三腿全追平**（改 p1-upd ✓ / 插 pa-new ✓ / 删 p2 ✓）；删腿 junction 配对同步清理 2→1 ✓（两档一致性）
- **Syncing 窗口 delete 收敛**：realtime 大表 sync（2200 行）resync 中删 r1500 → 状态回 active 后 ~30s 内镜像收敛 2199 行、r1500 ghost 消失（markSkipped → 当轮结束 catch-up 全量 pass 含 sweep）✓

### P1-P2 站位抽查（run2 §4-5、run3 §4）

- **paste 面**：password gate（无密码 → `passwordProtected:true`；错密码 → 400 Invalid shared view password）；paste sourceSchema **不列 link 列**（columns=["Title","Qty"]）；**paste+link createSync → 400**（消息含 browse-mode 指引）；paste 纯标量成功不误伤；createSync/GET 详情/GET list 三响应零 `source_uuid`/`source_password_hash` ✓
- **ACL**：editor 对 table-syncs list/create/resync/detach/delete 五端点全 **403** ✓
- **类型漂移**：源 Qty Number→SingleLineText → resync → 镜像列 uidt 跟随 ✓

### E1 六格（run3 §6，sourceSchema browse 探针 = assertSourceReadAccess；R5 修复回归）

| 格 | ws 角色 | base 角色（源） | 结果 | 判定 |
|---|---|---|---|---|
| g1 | editor | editor | 200 | allow ✓ |
| g2 | 无 | editor | 200 | allow ✓ |
| g3 | editor | no-access | **404** | deny ✓（R5 E1 修复不复现） |
| g4 | 无 | no-access | 404 | deny ✓ |
| g5 | editor | 无行 | 200 | allow（ws 继承）✓ |
| g6 | 无 | 无行 | 404 | deny ✓ |

### UI 活体（camoufox session f09p4r4l2，ui/uie 账号）

- 树菜单三层表条目 + 同步徽标渲染正常；zh-Hans 全覆盖（见 R3 小修节）
- **editor gate**：uie（editor）打开 synced 镜像 uigatesync 网格——数据渲染正常（hello 行 + Links 徽章 =1），**`New record` 按钮 `disabled=true`**（DOM 断言 + 截图 `/tmp/f09p4r4l2-editor-gate.png`）✓

## M 系列（minor，不阻塞）

- **M1（新增，观察级）infra 共用账号 token_version 互踢窗口**：`f01e2e@ce-ee.local` 是历轮脚本共用 infra 账号，任意 lane 每次 signin 轮换 token_version 使他路已发 token 全部失效——本轮 run3 第 6 步（距 signin ~4min）因他路并发 signin 而 401 连锁（脚本未校验 ITOKEN 静默失败，表现为 E1 邀请全 403）。lane 侧已在步骤内现取现用规避；建议任务书层面把「infra 账号 signin 即踢」补进 lane 纪律（UI/API 账号分离条款的 infra 版），或为各路建专属 infra 级账号。
- **M2（维持）spec 无 `updateForColumn` 通道用例**：`table-syncs.Fork.spec.ts` 60/60 中 LTAR guard 用例仍只覆盖五入口单测，v3 `nestedLink`（单列档）通道的 422 无单测回归锁，仅靠活体（本轮 run1 #1-2 再次实测 422）。与 R3 lane3 M2 同源，任务书已知遗留清单未列（清单列的是「spec 缺 v3 通道用例」同一项）——维持不新增计数。

## 已知遗留（按任务书勿重报，本轮复核均维持现状）

i18n 死键 `msg.warning.syncPasteLinkUnsupported`（组件零引用、400 为后端英文——run2 活体同旧貌）、spec 缺 v3 通道用例（=M2）、createSync 蛇形 `selected_fields` 不认、源 link 列删除孤儿、bulkUpdateAll 不 tap、paste resync 不复验 hash、afterBulkRestore CE 无调用方。

## 勘误 / 方法注记（供后续 lane 参考）

1. v2 records **无单行 PATCH 路由**：`PATCH /api/v2/tables/:id/records/:rowId` → 404；更新行走批量 `PATCH /records` body `[{"Id":..,...}]`（probe-upd.sh 实证：批量 200 → realtime catch-up 2s 内追平）。此前 lane 若用单行路由测「改腿」，404 会被误判为引擎不回写。
2. 窗口 delete 收敛测试**必须用 realtime 档**：manual sync 不吃 realtime tap，窗口内删行要等下次 resync 才收敛（P1 既有语义，非缺陷）。本轮先用 manual 档测得「ghost 不收敛」假象，改 realtime 后按规格收敛。
3. base 邀请角色枚举为**连字符** `no-access`（`no_access` 下划线 → 400 Validation failed，行未落 → 静默改变 E1 网格前提）。
4. workspace id 取法：无 `/api/v1/workspaces` 列表路由；从任意 base 的 `fk_workspace_id` 取（本实例恒 `w9qi3ljd`）。
5. base tables list（`?includeM2M=true`）在 detach 完成后**立即**查询可能短暂缺席个别 junction 表（run1 观察一次，2s 后探针复测四表齐 + synced=false）——瞬时缓存态，非缺陷；判 detach 以 meta 直查/稍后 list 为准。

## 质量门

- `npx tsc --noEmit`（packages/nocodb）：**exit 0**。
- `npx jest --testPathPattern 'Fork'`：**60/60，3 suites 全过**。
- Vite URL 门：`npx vitest run test/formula-url-xss.test.ts --config test/vite.config.ts`：**5/5 过**。

## 未覆盖（环境/范围限制，非「通过」）

1. editor 触发守卫后的 **422 toast 展示**（UI 面只验了 disabled 按钮 + API 422；toast 截图属 UI 细节分工项，历轮同样以 API 活体 + DOM disabled 覆盖）。
2. Syncing 窗口 catch-up 的**重复幂等复跑**只做单轮（多轮交替交替档 R3 已四路锁过，本轮按站位抽查单轮）。
3. 测试账号不删（NocoDB 无删除用户 API）：`f09p4r4l2-{owner,editor,ui,uie,g1..g6}` 九账号保留，全前缀可辨（历轮同惯例）。

## 纪律

只读审查：`git diff -- packages/` 零改动、index 零源码残留（本 lane 仅新增 `.work/ee-ce/f09p4r4l2-*.sh` 六脚本与本报告）；未构建/未重启/未 pkill/未跑 `dev-backend*.sh`（:8080 pid 38535 全程未扰动）；无 psql、未提权；隔离未读他路 R4 报告（对照材料 = 任务书指定链：r4-p4/r3-p4/r2-p4/r1-p4 lane-prompt + r3-p4-lane3 + f09-p4-impl-report + GOAL-STATE）；测试 base 全删（owner + infra 双视角 `f09p4r4l2*` 计数 = 0 清零核验）；camoufox session 已 close；无凭证写入 git 跟踪文件（口令仅存 `.work` 白名单脚本）。
