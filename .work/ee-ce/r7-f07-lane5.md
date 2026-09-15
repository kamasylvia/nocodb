# r7-f07-lane5 — F07 R7 会审报告（第 5 路：int + rev）

## 裁决：PASS（0 error；1 条 commit 流程注记 + 4 条 low 观察，均不构成 error）

---

## int（交叉抽验）：PASS — 55 断言全过（主链 49 + 补测 6）

环境：dev server :8080（nocodb-dev）；DB 经 pg8000 直查（qnap.elf-balance.ts.net:5432/nocodb-dev）；专用账号 f07r7l5-<ts>@ce-ee.local。脚本：`.work/ee-ce/r7-lane5-int.py` / `r7-lane5-int2.py`（首跑 2 个 FAIL 为脚本自身读法误判——records list 应用 GET、restore 为异步 job 需等待——补测复核全过，非被测代码缺陷）。

### 快照安全全链路（secret 变量源 base）

| 步骤 | API 结果 | DB 核验 |
|---|---|---|
| 建 base+T1 表+2 行 | 200/200/200 | — |
| 建 secret 变量（F05 API） | 200 | nc_base_variables 1 行，value=密文 `U2FsdGVkX1...`（非明文） |
| create snapshot | 200，status=processing | nc_snapshots 行：base_id/snapshot_base_id/status=processing/created_by 全部正确 |
| 轮询至 completed | completed | 行内 status 持久化 completed |
| 副本 base 核验 | tables 可见（T1） | nc_bases_v2：deleted=false、status 清空（非 job）、title=`Snapshot <ts> of <orig>`；**副本 base 变量行=0（无 secret 物料通道）**；源 base 变量 intact=1；secret 值不在副本 meta |
| 副本数据 | T1 数据 2 行（GET records） | 与源一致 |
| restore | 200 → {base_id} | 新 base title=`f07l5_base_... (restored)`、deleted=false、数据 2 行、**变量行=0**、工作 base 未动；processing 快照 restore → 400 干净拒绝 |
| delete snapshot | 200 | nc_snapshots 行 gone；副本 deleted=true（软删进 trash） |
| 删带快照的 base（cleanup 链） | 200 | 快照行清 0；副本软删（cleanupByBaseIdWithCopies 经 Base.softDelete hook 生效） |

### 边界 + 权限抽查

- POST title=12345 → 400；title 513 字符 → 400
- 未知 baseId → 404；未知 snapshotId → 404；**跨 base 快照 id → 404**（getSnapshotWithBaseCheck 归属校验生效）
- 无 token GET/DELETE → 401 ×2
- viewer 角色（base 级邀请）：list → 403、create → 403（ACL 双侧一致实测）
- 孤儿快照行 = 0；测试产物全部软删（trash 语义），未动他路数据

## rev（交叉面终审）：PASS

### 安全语义
- secret 隔离：duplicate.processor/duplicate.service 无 BaseVariable 引用（源码核）+ 实测副本/restore 产物 0 变量行 → AGENTS §2.1「无 secret 物料通道」断言成立
- 密文链：NC_CONNECTION_ENCRYPT_KEY 注入下 secret 落库为密文（实测）；无明文泄漏路径（list 掩码、meta 无值）
- 输入面：title string+≤512 校验；body 显式读取（多余字段忽略）；404 归属校验防跨 base 枚举；错误响应不泄内部 id
- mutex check-then-insert TOCTOU = 已记录 residual（GOAL-STATE backlog），非新发现

### 一致性
- Api.ts / ncUtils.ts（isEeUI）：**未动**（git status 无）
- [CE-EE] 标记：全部改动 hunk 覆盖；models/index.ts 纯 re-export 行无标记——与 F05 BaseVariable 行先例完全一致，不算违反
- acl 双侧：server `utils/acl.ts` permissionScopes 注册 baseSnapshotList/Create/Restore/Delete 4 op + CREATOR exclude 模型（不含即放行）；前端 `lib/acl.ts` CREATOR include 显式 4 op，EDITOR/VIEWER 不含——双侧一致
- UI 三门（BaseSettingsMenu / View.vue tab+深链 / useEeConfig blockSnapshots=false）全走 `!blockSnapshots && isUIAllowed('baseSnapshotList')`；View.vue isUIAllowed 来自 useRoles() 合法
- i18n en/zh-Hans 键成对（6+3 键两侧对称）

### 测试基建
- 后端 `npx tsc --noEmit`：0 error
- jest：**26/26**（2 suites passed）
- nc-gui vitest：**135/135 passed**（pwa-self-destroying suite 失败 = AGENTS §3.2 已载上游噪音，import 已删的 pwa.config，非 fork 引入；一次偶发第二失败未复现，属既有并发抖动模式）
- `.work/ee-ce/logs/backend.log`（3217 行）：snapshot 相关 ERROR = 0；CacheMgr ERROR = 0（仅既有 auth 401 噪音）；rspack 编译正常

### 文档（AGENTS §2.1 准确性）
逐条对照实测：异步完整副本 ✓、processing→completed/error 派生 ✓、副本为活 base 非时点冻结 ✓、restore=新 base 不原地覆盖 ✓、删快照=softDelete 副本+删行（Base.delete 守卫勿用）✓、不复制 base variables ✓。文档准确。

### commit 前清单（对照 git status：15 M + 3 ??）
- F07 面：3 新文件（controller/service/model）+ 12 修改 + AGENTS.md 同步——齐
- **流程注记（非 error）**：`packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts` 的 3 处 `[CE-EE] F01` greedy capture 改动（`[^)]+`→`.+`）是 F01 commit 744d3161 **之后**新增的 F01 修复，尚未 commit，现混在 F07 working tree。建议：commit 时拆为独立 F01 fix commit（或 F07 commit body 明确说明混入内容）。改动本身已随本轮 tsc/jest 全绿，语义正确（PG detail 单行 Key(...)=(value) 场景贪婪捕获到行尾，正确修复 value 含 `)` 截断）。
- `dataHelpers.ts` 的 `!base → NcError.baseNotFound` 守卫标 `[CE-EE] F07 R3 fix`，属 F07 面 ✓
- `.work/` 未入 status（gitignore 生效）✓

## low 观察（不构成 error，不要求修）

1. `packages/nc-gui/components/dashboard/settings/base/Snapshots.vue` createSnapshot 轮询上限 24×2.5s=60s：超大 base 完成超 60s 时 UI 停留 processing；重新进入设置页即自愈（loadSnapshots 重拉）
2. restore 返回时产物可能仍在复制中（DuplicateBase 异步），UI 立即 `/nc/{id}` 跳转——GOAL-STATE backlog 已记（「restore 后新 base job 态即跳转」）
3. `base-snapshots.service.ts` deriveStatus 对 terminal 快照每次 list/get 均做无缓存 metaGet2 探测：快照量少时无感，量大时有 N+1 查询放大（自愈语义的合理代价）
4. `packages/nc-gui/nuxt.config.ts` allowedHosts hook 无环境 gate，但 `vite.server.allowedHosts` 仅 dev server 消费，生产 build 无效果——注释「dev-only」事实成立，本地 dev 风险可接受

## 测试残留

- 本路测试 base/快照/restore 产物全部软删（nc_bases_v2 deleted=true，进 trash）；nc_snapshots 孤儿行 0
- dev 库另有他路（f07_src/f07r7c/f07del/f07r3a 等）测试数据与 1 条 R2 前 hook 修复前的历史孤儿快照行（base 已软删）——按隔离纪律未清理，留 orchestrator 统一处理
