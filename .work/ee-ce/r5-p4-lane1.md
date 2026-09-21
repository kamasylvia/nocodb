# F09 P4 R5 — lane 1（E1 修复回归 + P4 站位继承）报告

**结论：PASS / 0 error + 0 minor**

（R4 lane5 E1 修复活体回归全腿零复现：共享 shadow drop 三态 + 幂等收敛 + 二轮重建全部 200 收敛、无 404/部分拆毁/孤儿；P4 站位继承同规格复跑全过；R4 小修（processor catch-up 头注释）验证通过。维持项 M1/M2 无新增。）

审查基线 = b4849136e1（R4 修复批）；b4849136e1..HEAD packages/ 零 diff（两笔均为 .work 流程件）。dist 双条件核验：`~/.nocodb-run/.../dist/main.js` mtime 2026-09-22 03:57 < :8080 进程（pid 76261）启动 04:06:36 ✓；dist 特征串 `F09 P4-R4(lane5 E1)` ×4（两阶段 drop / 幂等 drop / 收敛 sweep / phase 2 引用计数四段注释全命中）、`P4-R2` ×2、`prohibitedSyncTableOperation` ×7 → :8080 运行的确为 R4 修复后 dist。账号 `f09p4r5l1-{owner,editor,ui,uied}`（API/UI 分离，admin `f01e2e` 仅作建 base/邀请/清理引导）；camoufox session `f09p4r5l1`；截图 12 张 `.work/ee-ce/ui-shots-f09p4r5l1/`。脚本：`f09p4r5l1-run1.sh`（E1 腿）、`-run2.sh`（守卫/收敛/mark_deleted）、`-run2b.sh`（paste/AUTO）、`-run3.sh`（ACL/freeze）。

## E1 修复回归（run1，活体，主项）

- **全量建**（源 T1 挂 3 条 mm link：Ns/Ns2→同 RT T2、Nt→T3；createSync 全选）→ **2 shadow + 3 junction**，T2 双 junction 共享 1 shadow，配对回填 1/1/1。
- **keep-only PATCH**（同 selection）→ 200；映射零变化；`last_synced_at` 不变（无 resync，与 R1 行为逐字节一致的闸门生效）。
- **删单条共享腿**（Ns 落选，Ns2/Nt 留）→ **200 无 404**；共享 shadow + T3 shadow 保留（2S）；落选腿 junction mapping 清（余 2）；存活腿配对 1/1；镜像 Ns 列删、Ns2/Nt 列留。**404/部分拆毁零复现。**
- **一条 PATCH 删完 T2 共享对**（Ns2 落选，Nt 留）→ T2 双 junction mapping 全清 + 共享 shadow 表 404 + junction 表 404；T3 junction 配对不受扰。
- **全删**（[Title]）→ roles=[main]；shadow/junction 表全部 404；镜像 link 列零残留。
- **幂等重试**：同 [Title] PATCH 重发 → 200；roles 仍 [main]；`last_synced_at` 不变（无 resync 投放，无僵尸/重建）。
- **二轮收敛**：null 重建（2S+3J、配对 1/1/1）→ 再全删（roles=[main]）→ 再幂等重试，全过。
- **静态审查**：两阶段 drop（phase 1 仅拆列+junction，shadow 循环外判定）+ junction 僵尸 sweep（仅 link-drop PATCH 触发，keep-only 不触发）+ phase 2 `keptLinkRtIds` ∩ mapping 行复验双闸，逻辑闭环；spec 3 新用例（`table-syncs.Fork.spec.ts` 60→63：删单条/双删恰一次/中断后 sweep 收敛）断言齐备。

## P4 站位继承（run2/run2b/run3，活体全过）

1. **v3 通道守卫**：owner/editor 对 synced 镜像 link `POST/DELETE /api/v3/data/{base}/{model}/links/{col}/{row}` → **422 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`**；拦截后 junction 配对不变；v3 GET 镜像 links 读路径 200。
2. **v2 嵌套通道 + readonly**：镜像 `addLinks` nested → 422；v3 PATCH 镜像标量 → 400 readonly（P1 语义）；owner 镜像行删同样 422（readonly 链不因角色放宽）。
3. **合法路径不误伤**：owner 对源表 v3 link POST/DELETE = 200；editor 对 dest 普通表 v3 写/读 = 200/201。
4. **引擎通道**：源 v2 加配对 → 手动 resync → junction 2→3（raw-knex 通道照常）。
5. **窗口收敛（delete 档 + sweep）**：源删 p2 → resync → mirror 行清 + junction 孤儿清 3→2（合法配对保留）。
6. **mark_deleted 两档一致**：独立 sync2（onDeleteAction=mark_deleted）→ 源删行 → resync → mirror 保行 + `RemoteDeleted=true` + 配对 2→1（与 delete 档同清配对）。
7. **paste 面**：browse sourceSchema 列 link（link:true）；paste sourceSchema 不列 link；paste+link createSync → 400（browse-mode 指引文案）；paste 纯标量全链建成。
8. **AUTO realtime**：realtime sync 建链 → 标量插入 2s 传播 mirror；link 配对经 tap 自动 full-resync 回填（2s，`last_synced_at` 推进，无手动 resync）；realtime delete 档 mirror 行删 + 配对清（2s）。
9. **ACL**：editor 对 list/create/resync/update/delete 五 sync 端点全 **403**；editor junction 直写/镜像行删 422。
10. **freeze/resume**：freeze→paused、resume→active（API 状态机）。
11. **P1-P3 矩阵**：标量 sync 全链、全量/增量/catch-up sweep、AUTO 双档、E1 六格 API 面（镜像行删 422 链）、守卫链——以上各腿均在 run2/run2b/run3 内同规格复跑通过。

## R4 小修验证

- processor pull-shape 头注释已准确：「an incremental run with no ids falls back to the full pass (upsert + disappearance sweep)」；源码与 dist `WITHOUT sweep` 残留 = **0**。

## UI 活体（camoufox session f09p4r5l1）

- **向导三层建同步全链**（截图 01-06）：Create New → NocoDB Sync → Browse 选 base/table → specific 字段列表含 link 列 Ns（向导零改动自然可选）→ step2 双设置组 → Create → 树出现镜像 + shadow；API 交叉核验 roles=[main,linked_shadow,junction]、status=active。
- **树菜单三态 + Syncing 守卫**（截图 07-08）：Synced 态全项（立即同步/暂停同步/转换为普通表/删除同步）→ 源侧灌 500 行后 Sync now，同步期间重开菜单 = **四个 sync 动作全隐**（守卫实锤；2 行小表同步过快抓不到，属时序而非缺陷）→ 完成后菜单恢复全项；Freeze→菜单现 Resume sync（Paused 态，截图 09）→ Resume 回 active（API 核验）。
- **editor gate**（截图 10）：editor 开 base 上游路由直送 grid（无 Overview/sync 卡）；镜像 grid **「New record」DOM `disabled:true`**；editor 树节点菜单无任何 sync 动作项。
- **zh-Hans Convert 弹窗**（截图 11-12）：zh-Hans 下树菜单项全中文（立即同步/暂停同步/转换为普通表/删除同步）；Convert 弹窗标题/正文/按钮（取消/转换为普通表）**全中文零英文回落**；确认转换后 sync 清零（API list=0）、表保留树中可编辑。

## 质量门

- `npx tsc --noEmit`（packages/nocodb）：**exit 0**。
- `npx jest --testPathPattern 'Fork'`：**63/63，3 suites 全过**（R4 新增 3 用例在内）。
- Vite URL 门：`npx vitest run test/formula-url-xss.test.ts --config test/vite.config.ts`：**5/5 过**。
- 活体四脚本：**63 项断言 FAILS=0 全过**（run1 29 + run2 18 + run2b 10 + run3 6）。备注：run2/run2b 首两轮的 FAIL 为**审查脚本自身 API 形状笔误**（v3 路由漏 `:baseName` 段、link body 应为裸 Id 数组、sourceSchema 返回键为 `columns`），修正后终轮全绿；终轮即上列证据。

## M 系列（0 新增；维持项）

- **M1（维持）** i18n 死键 `msg.warning.syncPasteLinkUnsupported`（paste+link 400 文案为后端英文，组件零引用）——本轮活体复核仍为英文，维持 R2-R4 判定。
- **M2（维持）** spec 仍无 `updateForColumn` v3 通道用例（63/63 未新增）——v3 守卫靠活体锁定。
- （观察，非判定项）① editor 侧树不显示 shadow 表（owner 可见；junction 本为系统表两侧均不显）——R1-R4 未测过 editor 树，无法判定为回归，镜像 link 列经 junction+shadow 读路径不受影响；② Paused 态菜单保留「立即同步」（R4 观察维持，paused 下 resync 后端行为仍未复核）。

## 未覆盖（环境/范围限制，非「通过」）

1. **中断 PATCH 的活体复现**（mid-loop 非预期失败后重试收敛）：无法在不注入故障的前提下对运行中 dist 确定性制造；以 spec 第 3 用例（jest 活体）+ 静态审查 + 同 PATCH 幂等重试活体三重替代覆盖。
2. 删除流三腿 UI（删 active 同步表重定向 remaining[0] 等）——R4 已 UI 实证，本轮未重复（冲刺轮以 E1 主项资源优先）。
3. 测试账号删除：无删除用户 API，`f09p4r5l1-{owner,editor,ui,uied}` 保留（全前缀可辨，历轮同惯例）。

## 纪律

只读审查：`git status` packages/ 零改动；仅新增 `.work/ee-ce/f09p4r5l1-*.sh` ×4、本报告、`ui-shots-f09p4r5l1/` 截图 12 张。未构建/未重启/未 pkill/未跑 `dev-backend*.sh`；无 psql、未提权。隔离未读他路 R5 报告（对照材料限任务书指定链：r4/r3/r2-p4-lane-prompt、r4-p4-lane5、f09-p4-impl-report §11 及其引用的自测脚本——仅取 API 机械形状，未取判定）。测试数据清零：admin 列表 `f09p4r5l1*` base 计数 = **0**（脚本 trap 清理不可靠，最终逐一手动 DELETE 200 并复核清零）；无凭证写入 git 跟踪文件。**流程失误自述**：中途以 API signin 复核 UI 专属账号（f09p4r5l1-ui）触发 token_version 轮换踢掉其浏览器会话——即「UI/API 账号分离」红线背后的机制本人实证了一次；浏览器重登恢复，后续 UI 账号零 API signin（交叉核验一律走 admin 令牌），未影响任何判定证据。
