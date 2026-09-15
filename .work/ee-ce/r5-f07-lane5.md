# r5-f07-lane5 — 第 5 路会审报告（int 交叉抽验 + rev 交叉终审）

> 隔离声明：未读任何 r*.md 报告；仅读 TASK.md、仓根 AGENTS.md、源码、dev-backend.sh/f01-e2e.sh 等测试脚本。
> 实测环境：dev server :8080（nocodb-dev），DB 核验 pg8000 直查 nocodb-dev，凭证运行时 Infisical KDL 拉取。
> 测试脚本：`.work/ee-ce/f07l5_int.sh` / `f07l5_sec.sh` / `f07l5_db.py`。测试资源已全部清理（live bases=0, snap rows=0）。

## 裁决：issues（1 项，单路发现，已实测验证）

### issues

- `packages/nocodb/src/services/base-snapshots.service.ts:234-248`（deriveStatus）: 副本 base 行 status 为空字符串时被误判 'completed'，restore 放行未完成副本 : 建议 `if (!copyRow.status || copyRow.status === ProjectStatus.JOB)` 归入 processing（含 15min 超时判定），仅非空且非 'job' 才返回 'completed'

**实测验证（确定性 DB 实验，非推测）**：
1. 正常链路建快照至 completed。
2. DB 置副本行 `status=''`（模拟 `duplicateService.duplicateBase` 同步建行后、job processor 置 `ProjectStatus.JOB='job'` 前的窗口态——createSnapshot 同步返回时该窗口必然存在，队列繁忙时拉长）。
3. `GET /api/v2/meta/bases/:id/snapshots/:sid` → `status: "completed"`（应为 processing）。
4. `POST .../restore` → `HTTP 200`，复制半成品副本为新 base（违背「restore 基于完整时点副本」的数据完整性承诺）。

## int（交叉抽验）明细 — 全部 PASS

安全全链路（secret 变量源 base → 快照 → restore 产物 → 删除，每步 DB 核验）：

| 步骤 | 结果 |
|---|---|
| secret 变量写入 | 落库密文 `U2FsdGVkX1...`，无明文残留 |
| POST snapshots | 200，nc_snapshots 行 status=processing，snapshot_base_id 正确 |
| 状态收敛 | processing→completed；副本 base `Snapshot <ts> of <orig>`，deleted=false |
| 副本变量行 | 0 行（secret 物料无快照通道，AGENTS §2.1 声明成立） |
| restore | 200 `{base_id}`；产物 `<orig> (restored)`，deleted=false，变量 0 行，GET base 200 |
| DELETE snapshot | 200；登记行删净；副本 deleted=true；再 GET 404 |
| input guards | title 非字符串 400；title>512 400 |
| 副本 purge 自愈 | 副本 deleted=true 后快照自愈降级 error（updated_at 同步），restore 400，降级快照可删 200 |
| 权限 401 | 无 token GET/POST snapshots → 401×2 |
| 权限 403（editor） | list/create/restore/delete → 403×4 |
| 权限 403（非成员） | list/get → 403×2 |
| JOB FAILED 计数 | 4→4，本路全部操作（含正常顺序删除链路）零新增 |

## rev（交叉终审）明细

- **安全语义**：后端 acl 实际效果 = creator/owner allow（exclude 短路）、editor 及以下 deny（include 列表无 baseSnapshot*，`extract-ids.middleware.ts:1250-1280`）；前端 `lib/acl.ts` creator include 四键 + OWNER 经 include 继承（acl.ts:310-321）获得——双侧一致。跨 base 快照枚举防护 `getSnapshotWithBaseCheck`（snapshot.base_id !== baseId → 404）有效（实测 P10/S 系列）。
- **一致性**：[CE-EE] 标记覆盖全部修改处；`models/index.ts` export 行无标记与 F05 BaseVariable 先例一致（豁免）；lang JSON 无法注释（豁免）；`Api.ts`/`ncUtils.ts`（isEeUI）/nocodb-sdk 零改动（git status 佐证）。`manageSnapshot` 前端残留为上游死键（后端 acl 无此权限名），fork 已全部替换为 baseSnapshotList，无害。
- **测试基建**：`tsc --noEmit` exit=0（全量含 3 个新文件）；jest 2 suites **26/26 PASS**（exit=0）；backend.log 中 5 处 F07 编译 ERROR 均为 R3/R4 热更中间态（copyBaseExists→getCopyBaseRow 重命名过渡），当前源码 tsc 0 错佐证干净；4 次 `JOB FAILED`（22:19/23:00/23:32×2）均为「复制 job 运行中 base 被并发删除」竞态（各路并行集成测试操作所致），job catch 清理 targetBase 时再报 not found——状态机正确收敛（快照 derive 至 error），非正常操作路径触发，非 F07 代码缺陷。
- **文档（AGENTS §2.1）**：四项声明（`Snapshot <ts> of` 前缀 / restore=`<orig> (restored)` 新 base 不覆盖 / 删快照=softDelete 副本+删登记行 / duplicateBase 无 variables option 故无 secret 物料通道）逐项实测吻合。
- **commit 前清单**：改动面 = 14 修改 + 3 新增（controller/service/model），与 `git status` 一致；AGENTS.md（§1 表、§2 gate 清单、§2.1 新增）与代码同批更新。
- **观察项（非 error，不要求本轮处理）**：createSnapshot 在 duplicateBase 之后 insert 登记行，若 insert 失败会遗留无登记的孤儿副本 base（低概率、失败即 500 可见）；restore 的 navigateTo `/nc/{id}` 与上游既有用法（admin/InstanceBases.vue 等）一致。
