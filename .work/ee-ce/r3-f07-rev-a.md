# r3-f07-rev-a — F07 Snapshots 第 3 轮会审报告（第 3 路：集成抽验 + 后端终审）

- 日期：2026-09-12
- 范围：`git status/diff` 全部改动（后端 3 新文件 + 4 挂载文件）+ nocodb-dev 实测（pg8000 直查 nc_snapshots/nc_bases_v2）
- 时序说明：本路会审期间源码被修复批次更新（base-snapshots.service.ts / BaseSnapshot.ts / Base.ts，mtime 晚于首轮 tsc）。本报告 = 既有审查发现（针对修复前代码的 2 项 issues）+ 修复后代码的逐项实测验证。所有结论均基于**当前磁盘代码**复核/实测。

## 裁决

**PASS**（前轮 2 项 issues 已修，修复后代码实测全部通过；无新 issue）

## 前轮 issues → 修复验证（均实测）

### issue 1（前轮）：completed 后副本 base 被直删 → 状态滞留 completed、restore 误导性 404
**已修，实测通过**：
- `base-snapshots.service.ts:233-242`：deriveStatus 对 `completed` 不再盲信终态短路——探测副本 base 存在性，缺失 → 派生 `error`。
- `base-snapshots.service.ts:116-137` + `:161`：新增 `ensureCopyExists`，restore 前二次探测，缺失 → 落库 error + 400 明确文案（不再 404 泄漏内部 id）。
- 实测（修复后代码）：建快照 → completed → `DELETE /api/v2/meta/bases/{snapshot_base_id}` 直删副本 → `GET .../snapshots/{id}` 200 **status=error**（DB 同步 `[['error']]`）→ POST restore **400** `Snapshot is not ready for restore (status: error)`。✓

### issue 2（前轮）：createSnapshot 互斥检查读原始持久化 status，未先 derive，卡 `processing` 行阻塞 create
**已修，代码核验**：`base-snapshots.service.ts:39-50`（`[CE-EE] F07 R3` 注释）——mutex 判定改为先走 `listSnapshots`（内含逐行 deriveStatus 自愈），卡死行在 create 前即被派生。

## R3 新增：cleanupByBaseIdWithCopies（删源 base 连带处理副本）

- `BaseSnapshot.ts:182-208`（新增）：删工作 base 时先 softDelete 其全部快照副本 base（消除工作区孤儿活 base），再清登记行；副本已失时 catch 继续清行。动态 import 防 Base.ts 循环依赖。
- `Base.ts` 双挂钩（softDelete L456 / delete L706，均在既有 `BaseVariable.deleteByBaseId` 旁）改调此方法。
- **实测（修复后代码）**：建源 base + 3 行表 + 快照 → completed → `DELETE` 源 base → 200；DB 复查：`nc_snapshots` 行清零 ✓、副本 base `deleted=true`（连带进 trash）✓。

## int 集成抽验（全生命周期 1 轮，nocodb-dev 实测）

| # | 步骤 | 结果 |
|---|---|---|
| 1 | 建 base + 表 + 数据行 | ✓ |
| 2 | POST snapshots → 200，`processing`，DB 行立即落库 | ✓ |
| 3 | poll → `completed`（API 与 DB 同步） | ✓ |
| 4 | 副本 base：API 200，title `Snapshot <ts> of <src>`，数据行完整 | ✓ |
| 5 | restore → 200 + base_id；新 base `<src> (restored)`，数据完整（异步 settle 后复查 5 rows）；源 base 未动 | ✓ |
| 6 | DELETE snapshot → 200；登记行 1→0；副本 DB `deleted=true` + API 404 | ✓ |
| 7 | 二轮快照 → 删源 base → 快照行清零（另 2 次独立复测均 1→0） | ✓ |
| 8 | 边界：title 非字符串 400 / >512 400 / 跨 base get+restore 404 / editor 角色 create+list 403（专用 editor 账号实测） | ✓ |
| 9 | 攻击：completed 后直删副本（前轮 issue 1 链） | ✓ 已修，见上 |
| 10 | 攻击：超长副本 title 撑爆 nc_bases_v2.title varchar(255) | ✓ 不可达——baseCreate 层 title 长度上限实测 150-200（150 过 / 200 拒），前缀 31 + 冲突后缀 5 最坏 ~186 < 255 |

## rev 终审明细（R2/R3 修复逐项核验，当前代码）

| 项 | 结论 | 证据 |
|---|---|---|
| deriveStatus 探测先行 | ✓ | service L253-266：先探副本存在性，仅副本卡 `job` 才走 15min 超时→error，否则 processing；存活非 job→completed |
| completed 探测（R3） | ✓ | L233-242：completed 行派生前探副本，缺→error；实测生效 |
| ensureCopyExists（R3） | ✓ | L116-137/L161：restore 前二次防线 |
| mutex 前 derive（R3） | ✓ | L39-50 |
| 双挂钩 + 连带副本清理 | ✓ | Base.ts softDelete/delete 两处 → `cleanupByBaseIdWithCopies`；删源 base 行清零 + 副本 softDelete 实测 |
| 守卫 | ✓ | getSnapshotWithBaseCheck 归属校验；deleteSnapshot 副本缺失不 500；restore 前置 completed 校验 |
| title 校验 | ✓ | 非串/超长 400；空串回落默认 title；nc_snapshots.title varchar(512) 对齐 |
| 缓存一致性 | ✓ | insert 先物化再 appendToList（R1 保持）；deleteByBaseId deepDel key 与 F05 BaseVariable 同构 |
| schema/model 对齐 | ✓ | nc_snapshots 实表 10 列全对齐（information_schema 直查）；status varchar(20) 容纳枚举值 |
| ACL | ✓ | permissionScopes.base 白名单 creator+；editor 实测 403 |
| `// [CE-EE]` 标记 | ✓ | 全部修改点带标记 |

## 实跑验证（修复后代码）

- `npx tsc --noEmit`：**0 error**（exit 0；源码中途变更后重跑确认）
- `npx jest baseVariableValidators --runInBand --forceExit`：**12/12 passed**（两跑均过）
- 后端 rspack type-check（watch）两轮均 `no errors found`

## 攻击性找茬

**无**（有 API 可达链的均已实测堵死：跨 base 404、editor 403、title 链 400/不可达、删副本派生 error、超长 title 链源头封死）。保留既有声明：processing 互斥 check-then-insert 竞态为代码注释声明的 residual risk（worst case 双副本、无损坏），非本轮引入。

## 环境备注（非 fork 问题）

- 会审期间并行路多次 stop/start dev server + 源码修复批次触发 rspack autoRestart，本路等待恢复后完成全部实测；JWT 短时效致测试脚本中途 401 重登。
- 本路测试 base/快照全部清理（含 via API 删除与连带清理验证）；其它并行路数据未触碰。
- 证据脚本：`.work/ee-ce/f07r3c_run1.py`、`f07r3c_run2.py`、`f07r3c_run2b.py`、`f07r3c_dbq.py`、`f07r3c_state.json`
