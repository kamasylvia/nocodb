# r6-f07-lane5 — F07 第 6 轮收敛确认（第 5 路：集成 + 复审）

## 裁决：issues 列表（1 项 minor；主链路与安全面全 PASS）

---

## int（交叉抽验）— 快照安全全链路实测：22/22 PASS

环境：dev backend :8080（rspack）+ nocodb-dev（qnap.elf-balance.ts.net:5432，pg8000 直查每步核验）。脚本：`.work/ee-ce/tmp/lane5_r6_run1.py`。

| # | 步骤 | 结果 | DB 证据 |
|---|---|---|---|
| 1 | 源 base 建 secret 变量（`POST /api/v2/meta/bases/:id/variables`，type=secret） | PASS | `nc_base_variables.value` = `U2FsdGVkX19NYvW2...`（AES 密文，非明文，`plaintext_leak=false`） |
| 2 | 创建快照 → 轮询至 completed | PASS | `nc_snapshots` 行：base_id/snapshot_base_id/status=completed/fk_workspace_id/created_by 全对 |
| 3 | 副本 base 存活 | PASS | `nc_bases_v2` id=`pv0voxpy4d1xt7k`，deleted=False，title=`Snapshot 2026-09-12T16-54-50 of <src>` |
| 4 | **secret 物料不入快照副本** | PASS | 副本 base `nc_base_variables` 行数 = 0；源 base 仍 = 1 |
| 5 | restore | PASS | 新 base `p3lggmxaehuvd0f`，title=`<orig> (restored)`，deleted=False；**其 variables = 0** |
| 6 | 权限：editor（受邀）4 端点 | PASS | GET/POST/POST-restore/DELETE 全 403 |
| 7 | 权限：无 token | PASS | 401 |
| 8 | 越权：跨 base 读他 base 快照 | PASS | 404 `Snapshot not found`（无内部 id 泄漏） |
| 9 | 删快照 | PASS | 登记行删净（remaining=0）+ 副本 soft-delete（deleted=True） |
| 10 | 源 base secret 变量全程完好 | PASS | count=1（终态复查） |

## rev（交叉面终审）

### 安全语义 — PASS
- ACL：`baseSnapshot*` 4 权限仅 creator（后端 `packages/nocodb/src/utils/acl.ts:274-277` 与前端 `packages/nc-gui/lib/acl.ts:143-146`），双侧一致；editor/commenter/viewer/no-access 均无。
- 越权面：`getSnapshotWithBaseCheck` 强制 `snapshot.base_id === URL baseId`（404）；restore/delete 的 context 由 DB 行 `fk_workspace_id` 构造，非用户可控输入，无跨 workspace 注入路径。
- secret 通道：实测副本/restore 产物 variables=0（上表 #4/#5）；源码旁证 `duplicateBase` options 无 variables 复制项（duplicate.service.ts:38-47）。
- 输入校验：title 非 string 400、>512 400（service:34-39）；DB 全参数化。

### 一致性 — 1 issue
- `packages/nc-gui/lib/../../nocodb/src/helpers/uniqueConstraintErrorHandler.ts`：见下方 issue 1。
- Api.ts / `ncUtils.ts`（isEeUI）未动 ✓（git diff 无命中）。
- 其余全部修改处 `[CE-EE]` 标记齐全（含 3 个新文件、dataHelpers 守卫、Base.ts 清理钩子、nuxt.config hook）✓。
- i18n en/zh-Hans 键对齐（6+3 键双侧同步）✓。

### 测试基建 — PASS
- 后端 `npx tsc --noEmit`：exit 0，0 错误。
- jest Fork 桶实跑：**26/26 passed**（2 suites）。
- 前端定向 vitest `unique-constraint-helpers.test.ts`：**8/8 passed**（正则改动相关）。
- `logs/backend.log`：无任何 F07/snapshot ERROR、无 500；仅 53 条 Token Expired 401 认证噪音（他路/浏览器自动化 token 过期，非 fork 引入）。

### 文档 — PASS
- AGENTS §2.1 四条主张逐条验证：①异步完整副本+`Snapshot <ts> of` 前缀（实测）②restore 新 base `<orig> (restored)`（实测）③删=softDelete+删登记行（实测，副本进 trash）④"duplicateBase 无 variables option"（源码证实）+ NC_CONNECTION_ENCRYPT_KEY 密文落库（实测 U2FsdGVkX1 前缀）。准确。
- commit 前清单：改动面 = 15 tracked（AGENTS.md 状态已同步）+ 3 新文件；`.work/` 不入 git ✓。

---

## issues

1. `packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts:310 / :645 / :875`：3 处正则 `Key\s*\([^)]*\)\s*=\s*\(([^)]+)\)` → `\((.+)\)` 为本 fork 修改但**无 `// [CE-EE]` 行尾标记**，违反仓根 AGENTS「所有修改处加标记」约定；且该文件属 F01 范围，混入 F07 commit 需说明归属。建议：3 处补行尾标记，commit body 注明该改动动机（value 含 `)` 时的 detail 提取截断）或由 orchestrator 决定移出本 commit。功能面无回归（jest 26/26 + 前端 8/8 实测过）。severity: minor（一致性，非功能/安全缺陷）。

## 观察项（不计 issue，供参考）
- `Snapshots.vue` createSnapshot 轮询（24×2.5s）无组件卸载取消；上限 60s 自停，无害。
- `nuxt.config.ts` `allowedHosts: true` 仅影响 vite dev server，生产构建不受影响，注释已声明 dev-only 意图。
- F05 create 端点响应回显 secret 明文 value（刚输入值的标准回显；list 已 mask）——F05 已 pass 范围，不属本轮。
