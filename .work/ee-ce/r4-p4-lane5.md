# F09 P4 R4 — lane 5（UI 验证重点路）报告

**结论：PASS / 1 error + 0 minor**
（R3 回归全项同规格复跑全过；1 error = 本轮新发现「共享 shadow 删 link」缺陷，单路实测确定性复现，按全局 §11.2 属实必修但不入当轮计数，清洁轮维持。）

审查基线 = 840c4218aa（R3 后仅 i18n/注释/流程件；zh-Hans `labels.convertToRegularTable` 已落 8de55d0b24）。dist 双条件核验：dist mtime 2026-09-22 01:34 < :8080 进程启动 01:41:12 ✓，dist 内守卫特征串命中（`manage the links in the source table` ×2、`F09 P4-R2` ×2、`prohibitedSyncTableOperation` ×7）→ :8080（pid 38535）运行的确含 R2/R3 修复。账号 `f09p4r4l5-{owner,editor,ui,uied}`（API/UI 分离）；camoufox session `f09p4r4l5`。脚本：`f09p4r4l5-run1.sh`（三层+v3 守卫）、`f09p4r4l5-run2.sh`（级联/paste/AUTO/收敛）、`f09p4r4l5-ui-setup.sh`（UI 环境）；截图 16 张 `.work/ee-ce/ui-shots-f09p4r4l5/`。

## E 系列

### E1（本轮新发现）：updateSync 在「双 junction 共享 shadow」配置下删 link → 404 + 部分拆除 + 重试后永久孤儿 mapping

- **复现条件**（合法产物配置）：源主表 ≥2 个 mm link 列指向同一 RT（P4「同 RT 共享 shadow」语义），updateSync `selectedFields` 移除全部 link 列。
- **症状**（3 个独立环境确定性复现：run2 步骤 5b 两次 + 独立 probe）：首次 PATCH → **404 `ERR_FIELD_NOT_FOUND: Field 'c…' not found`**；此时 shadow + 第一个 junction 已删（含 mapping/列映射），第二个 junction mapping 行残留、mirror 第二 link 列残留、`selected_fields` 未持久化——部分拆除态。
- **重试同 PATCH → 200**（幂等恢复路径存在），full-resync 投放，但终态 `roles = ["main","junction"]`：**第二个 junction mapping 永久残留**（僵尸 synced junction 表，FK 悬挂到已删 shadow），仅 deleteSync/detach 全量清理可达。
- **根因（代码定位）**：`table-syncs.service.ts` updateSync drop 循环（~L1454-1501）逐 link 调 `dropMirrorLinkColumn` 后**立即**调 `dropShadowForRelated`（`keptLinkRtIds` 在全部 link 落选时为空集，第一个 link 的 drop 即删共享 shadow）→ 第二个 link 的 `columnDelete` 撞已删结构抛 ERR_FIELD_NOT_FOUND 中断循环；重试路径 `dropMirrorLinkColumn` 因 dest 列已不存在而跳过 junction mapping 清理 → 孤儿。
- **判定**：违反 P4 契约「真掉线 link 全级联 + 投 full-resync」在共享 shadow 配置下的正确性。R1 族2 只修了**加腿**共享（drop 腿从未被 R1-R3 活体与 spec 覆盖）；不属任务书已知遗留清单（「源 link 列删除孤儿」指源侧列删除，与本例不同根因）。
- **修复建议**：共享 shadow 的 drop 延迟到循环外——先逐列 `dropMirrorLinkColumn` 收集落选 RT，循环结束后对「未被 keptLinkRtIds 引用」的 RT 再 `dropShadowForRelated`；`dropMirrorLinkColumn` 对已删结构幂等跳过。
- **计数**：单路发现 + 实测确定性复现 → 属实必修、不入当轮计数（§11.2）。

## R3 小修收尾验证（本轮重点之一）

- **zh-Hans `labels.convertToRegularTable`（8de55d0b24）活体**：zh-Hans locale 下树菜单项 = 转换为普通表；Convert 弹窗标题/正文/按钮（取消 / 转换为普通表）**全中文零英文回落**（截图 11）。convert 实际转正：确认后 sync 清零（list=0）、表保留树中可编辑（截图 12）。
- processor/realtime 注释腐化清理后无新问题（dist 特征串命中正常，realtime 链路活体全过，见下）。

## R3 全部验证项同规格复跑（活体，全部通过）

1. **v3 通道守卫**：owner/editor 对 synced 镜像 `POST/DELETE /api/v3/data/{base}/{model}/links/{col}/{row}` → **422** `ERR_SYNC_TABLE_OPERATION_PROHIBITED`；拦截后 junction 配对不变；合法路径不误伤（owner 源表 / editor dest 普通表 v3 POST/DELETE = 200）；读路径 GET 200；v3 PATCH 镜像标量 400 readonly（P1 既有语义）。
2. **三层 link sync**：createSync 三 mapping（main/linked_shadow/junction，junction `source_*=null`）；full-create junction 配对精确（2）。
3. **updateSync 级联**：keep-link PATCH 三层不拆毁（mappings=3、shadow id 不变、mirror link 列 id 不变、junction=2、无 resync——`last_synced_at` 不变）；加腿 shadow **共享**（双 junction 1 shadow）+ 结构变更自动 full-resync 回填（2/1=源 junction 镜像）；删 link（单 link 环境）全级联 mappings=1；null=全字段含 link（4）；`[]`→400。
4. **paste 面**：browse sourceSchema 列 link（T2s、T2s2，`link:true`）；paste sourceSchema **不列** link；paste+link createSync → 400（browse-mode 指引文案）；paste 纯标量不误伤。
5. **AUTO realtime**：标量 p4 插入秒级传播 mirror；link 配对经 `'link'` tap → full-resync 自动回填（无手动 resync）。
6. **窗口收敛**：realtime delete 档 mirror 行删 + junction 孤儿清（总配对 4→3，合法配对保留）；manual catch-up sweep（p2 删 → resync → mirror 无 p2）；**mark_deleted 档** mirror 保行 + `RemoteDeleted=true` + junction 总配对 2→0（两档一致清配对）。
7. **ACL**：editor 对 list/create/resync/detach/delete 五端点全 **403**；P2 守卫链：editor junction 直写 422、editor 删镜像行 422。
8. **引擎通道**：源加配对 → resync → junction 2→3（raw-knex 通道照常，无 bypass 亦无误伤）。

## UI 活体（camoufox session f09p4r4l5，本路重点）

- **向导三层 link 建同步全链**（截图 01-06）：owner Overview 可见 NocoDB Sync 卡（`proj-view-btn__create-new-sync`）→ browse 选 base/table → specific 字段列表**含 link 列 T2s**（向导零改动自然可选）→ step2 双设置组 → Create → 树出现主镜像 + shadow 表 → API 交叉核验 `roles=[main,linked_shadow,junction]`、status=active。
- **树菜单三态 + Syncing 守卫**（截图 07-10）：Synced（状态行+立即同步/暂停同步/转换为普通表/删除同步全项）→ Sync now 触发后重开菜单 = **Syncing 且五项全隐**（守卫实锤，后端确认期间任务真在跑）→ 完成后回 Synced（R5 reload-on-open 生效）；Freeze → **Paused**（Resume 现、Freeze 隐）→ Resume 回 active。
- **删除流三腿**（截图 15-16）：leg1 删非 active 同步表 → active 不变；leg2 删 active 同步表 → **重定向 remaining[0]**；leg3 删唯一表 → **base home**（No tables）。
- **editor gate**：editor 打开 base 被上游路由直送 grid（`projectOverviewTab` 为 creator-only ACL，editor 根本不到 Overview 页）；即便到页，sync 卡另叠 `isUIAllowed('sourceCreate')` 门（P2-R3 修复维持，双保险，ACL 静态闭环 lib/acl.ts L126 + Overview.vue L138）；editor 打开 synced 镜像 grid **「新增记录」按钮 `disabled:true`**（截图 14，E1 六格 DOM 证据）。

## 质量门

- `npx tsc --noEmit`（packages/nocodb）：**exit 0**。
- `npx jest --testPathPattern 'Fork'`：**60/60，3 suites 全过**。
- Vite URL 门：`npx vitest run test/formula-url-xss.test.ts --config test/vite.config.ts --hookTimeout 60000`：**5/5 过**。

## M 系列（minor：0 新增；维持项见下）

- **M1（维持）** i18n 死键 `msg.warning.syncPasteLinkUnsupported`（组件零引用，400 后端英文）——维持 R2/R3 判定，本轮未涉。
- **M2（维持）** spec 仍无 `updateForColumn` v3 通道用例（60/60 未新增）——v3 守卫仍靠活体锁定。
- （观察，非判定项）Paused 态菜单保留「立即同步」（菜单 v-if 仅排除 Syncing）；paused 下 resync 的后端行为本轮未复核，既有菜单设计非本轮引入。另：一次 S3 createSync POST 瞬时失败（立即重试成功，body 未捕获），判定为环境瞬态，不复现、不计项。

## 未覆盖（环境/范围限制，非「通过」）

1. UI link cell 写路径的 422 toast 展示与 zh-Hans 文案（后端 422 已由 API 活体覆盖，镜像写禁入已由「新增记录 disabled」DOM 证据覆盖）。
2. editor Overview 页 DOM 直证（上游按角色跳过该页；以 ACL 静态闭环 + sourceCreate 门代码 + editor 全端点 403 活体替代）。
3. 测试账号删除：无删除用户 API，`f09p4r4l5-{owner,editor,ui,uied}` 保留（全前缀可辨，历轮同惯例）。

## 纪律

只读审查（`git status`：packages/ 零改动；仅新增 `.work/ee-ce/f09p4r4l5-*.sh`、本报告与 ui-shots 截图）；未构建/未重启/未 pkill/未跑 `dev-backend*.sh`；无 psql、未提权；隔离未读他路 R4 报告（对照材料限任务书指定：R2/R3 lane-prompt、r3-p4-lane3、impl-report）。测试数据清零：`f09p4r4l5*` base 计数 = 0（清零核验），记录随 base 删除；无凭证写入 git 跟踪文件（口令仅存 `.work` 白名单脚本，历轮惯例）。
