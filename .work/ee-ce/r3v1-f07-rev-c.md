# r3-f07-rev-c（第 5 路交叉面复审, R3 收敛确认, 2026-09-12）

复审面：`git status --short`（13 M + 3 ??）+ 全量 diff + 未跟踪源码 + AGENTS.md/TASK/GOAL-STATE/TODO + 实测（tsc/jest/vitest/backend.log）。

## 1. 安全（快照语义终审 / key 不入 git）

- 副本可见性：copy = 普通 base（duplicateBase→baseCreate, status job→null），对全 workspace 成员可见 = AGENTS §2.1 明载 fork 决策，实现与文档一致；数据受众不变（copy 用户表镜像原 base）。
- restore creator-only：controller `@Acl('baseSnapshotRestore')`；后端 CREATOR/OWNER 为 exclude 模型默认放行、EDITOR/COMMENTER/VIEWER include 模型不含 4 个 `baseSnapshot*` → 403（`packages/nocodb/src/utils/acl.ts:643,649,537`）；FE menu/tab 双门 `baseSnapshotList`，OWNER 经 role-scope cascade 继承（`packages/nc-gui/lib/acl.ts:191,310`）。双侧 creator+ 语义等价。
- delete trash 残留：copy `Base.softDelete`→trash ✓；copy 已 trash/已清（Base.get deleted 过滤返回 null）→ 跳过 softDelete 仅删登记行，无 500 ✓；原 base 删除时 snapshot 行清理双挂钩实测在位（`Base.ts:456` softDelete / `Base.ts:706` delete，R2 python 替换失效问题已由 Edit 修复并经本次读码确认）。
- 越权面：`getSnapshotWithBaseCheck` 校验 `snapshot.base_id === baseId`，跨 base id 枚举不可达；restore/delete context 用行内 `fk_workspace_id`（metaInsert2 自动注入，`meta.service.ts:335`），nc_snapshots 列齐（`nc_001_init.ts:1030-1039`）。
- key 不入 git：diff + 3 个新文件无凭证物料；dev key 仅在 `.work/ee-ce/dev-backend.sh`（`git check-ignore` 实证 IGNORED）。
- **1.1 安全面：PASS**

## 2. 一致性

- `[CE-EE]` 标记：全部代码 hunk 有标记；lang en/zh 新键与 `models/index.ts` export 行无标记 = F05 既有惯例（BaseVariable 同位行同样无标记），一致性成立。
- Api.ts / nocodb-sdk 未动（git status 证）；`isEeUI`（ncUtils.ts）未动 ✓；SnapshotType 为 CE sdk 既有类型（`Api.ts:7940`）。
- acl 双侧一致：后端 `permissionScopes.base` 4 op ↔ FE creator include 4 op，命名全等；controller `@Acl` 名全匹配；10 条 snapshot 路由注册无冲突（backend.log Mapped 实证）。
- BaseSnapshot.deleteByBaseId 与 BaseVariable.deleteByBaseId 同构（F05 已验证模式，cache key 同款仓内惯例）。
- 路由/表/缓存 scope（`CacheScope.SNAPSHOT` / `MetaTable.SNAPSHOT`）均为 CE 既有，无 schema 改动。
- **2.1 一致性 issues：见 §6-I1（TODO 滞后）**，其余 PASS。

## 3. 测试基建（实测）

- `npx tsc --noEmit`（packages/nocodb）：exit 0，0 error ✅
- `pnpm test`（jest）：2 suites / **26/26 pass** ✅
- nc-gui `base-variables-acl.test.ts`（acl.ts 变更回归）：2/2 pass ✅
- backend.log（`.work/ee-ce/logs/backend.log`）：现行进程 11332 自 11:34:56 起（R2 修复后重启）**0 CacheMgr ERROR、0 TypeError** ✅（R1 期 CacheMgr/TypeError/rspack ERROR 全部位于旧进程 98256/5635 时段，已被重启切走）
- 12:18:27 有一条 `JOB FAILED: Base 'p756q81kbhviujy' not found`（duplicate.processor catch 清理路径 baseSoftDelete 404，上游既有行为）；发生于 R3 会审实测窗口（8s 前有 401 噪音，该 id 全 log 仅此一处）→ 判定为对抗性边界测试（job 在飞时删副本）诱发，deriveStatus 对 copy 缺失返回 'error' 无卡 processing，非回归。建议 orchestrator 与集成路对时间戳交叉确认。

## 4. AGENTS.md §2.1 准确性

逐句对码核验：
- 「异步完整副本 + title 前缀 `Snapshot <ts> of`」= service.ts:62 实现一致 ✓
- 「副本是活的 base，非时点冻结」注记在位（AGENTS.md:39）✓
- 「status processing→completed/error 按副本派生」= deriveStatus 一致（探测先行 + 15min stuck 兜底）✓
- 「restore = `<orig> (restored)` 新 base 不原地覆盖」= service.ts:149 一致 ✓
- 「删快照 = softDelete 副本 + 删登记行」；「Cannot delete first source」守卫实证存在（`Source.ts:504`）✓
- 「不复制 base variables」：duplicateBase options 无 variables 项 + export-import jobs 全树 0 处 BaseVariable 引用，claim 成立 ✓
- **4.1：PASS**

## 5. commit 前清单终核（对照 status）

13 M（AGENTS.md、BaseSettingsMenu.vue、Snapshots.vue、View.vue、useEeConfig.ts、en.json、zh-Hans.json、lib/acl.ts、nuxt.config.ts、models/Base.ts、models/index.ts、noco.module.ts、utils/acl.ts）+ 3 ??（controller/service/model）全部 F07 范围或 GOAL-STATE 明载的 dev-infra（nuxt.config allowedHosts hook）✓；`.work/` 不入库 ✓；无 credential ✓。

## 6. Issues（只列问题；均 low/flow，无代码 error）

- I1 `.work/TODO.md:8`：状态滞后——写「R2 会审进行中（R1 6 项修复已落地）」，GOAL-STATE（12:12）已是「R2 修复完成 + R3 会审运行中（基准轮 R2）」；且括注「R1 6 项」与 R1 裁决实际项数不符。建议：同步为 R3 进行中并修正项数。另 `.work/TODO.md:10` 残留旧的 `[ ] F07 …补 controller/service + UI` 规划行，与 :8 形成双状态源，建议删除。
- I2 F07 无新增单测：TASK.md「实现」步要求补/改单测，本次 jest 26/26 全为 F01+F05 存量（2 个 Fork spec），FE vitest 亦无 F07 件；title 守卫/deriveStatus 超时/状态派生均为可单测纯逻辑，仅靠 f07-e2e.sh 覆盖。验收清单字面（相关 spec 通过）满足，属流程缺口，建议 orchestrator 裁决是否补（不阻塞收敛计数的话记 backlog）。
- I3 `packages/nc-gui/nuxt.config.ts:160-168`：注释称「allow ephemeral trycloudflare hosts」，实际 `allowedHosts: true` 放行任意 Host（dev-only，风险低）。建议收窄为 `['.trycloudflare.net']` 或修正注释与 GOAL-STATE 措辞。
- I4（范围外观察）`AGENTS.md:12,16,18` §1 状态列滞后：F05 已 pass+commit（6ab23da061）、F01 已 commit（744d31618b）、F07 已实现，均仍标「待做」，与 §3.1 原子同步纪律不符；非本次 5 项任务点，提示收尾 commit 时一并处理。

## 结论

代码面 0 error（安全/一致性/§2.1/commit 清单全过，tsc 0 + jest 26/26 + log 干净）；flow 面问题 I1 必须在 commit 前修（TODO 同步），I2/I3/I4 低优先级待裁决。
