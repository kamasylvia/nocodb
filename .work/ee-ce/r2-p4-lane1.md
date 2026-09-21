# F09 P4 R2 — lane 1（R1 六族活体回归）报告

**结论：PASS（0 error + 1 minor，minor 为继承性已知裁剪 M2，不阻塞）**

- 审查员：lane 1；账号 `f09p4r2l1-api@lantest.local`（owner）/ `f09p4r2l1-ed@lantest.local`（editor，真 editor 角，已 demote 验证）/ `f09p4r2l1-paste@lantest.local` / `f09p4r2l1-ui@lantest.local`；UI/API 账号分离
- 基线：`5368ef1366`（R1 修复批）；`git diff 5368ef1366 HEAD -- packages/` **空**（src 树 == 基线）；:8080 运行修复后 dist，全程未构建/重启/清进程
- 方法：staged sync 复用（`f09p4r2l1-run.sh` 前置 S1/S2：T1/T2 + 双 mm link Ns/Ns2 同 RT + 交叉配对 p1→n2/p2→n1、p1→n1/p3→n3）+ 增量活体；隔离（未读他路报告）
- 测试数据：SRC/DST 双 base 已 DELETE（复查 404）；hax 列已删；账号保留（无数据）；token 仅 /tmp

## R1 六族回归（活体逐项）

| 族 | 验证 | 结果 |
|---|---|---|
| 1. keep-link PATCH | `["Title","Qty","Ns","Ns2"]` keep PATCH → status 先 syncing 后 active，Ns/Ns2 列 id 不变，J1=2 行未动，shadow id 不变（`mb2xziwm0htplpf` 全程同一） | PASS |
| 1b. 真掉线级联 | 去 Ns2 → mappings 4→3，Ns2 列消失，Ns2 junction 表 404，Ns 链（J1=2 行、shadow=3 行）完好 | PASS |
| 1c. null 全字段 | null PATCH → 4 mappings（main+1S+2J），Ns 保留 + Ns2 重建，双 J 各 2 行回填 | PASS |
| 1d. `[]` | `[]` → 400 `selectedFields must be a non-empty array or null` | PASS |
| 2. 双 shadow 共享 | staged 双 link 加腿即 1 shadow + 2 junction；B2 加标量腿/单删 Ns 后 shadow 数=1 且 id 不变 | PASS |
| 3. LTAR 守卫 | owner 注入/unlink → 422 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`；真 editor 注入/unlink → 422；junction 直插 owner/editor 422；editor 镜像行插 400；J 行数不变；源侧 link 写 200/201 不受影响 | PASS |
| 3b. 五入口代码 | `assertLinkWriteAllowed` 定义 6597 + 调用 6654(addChild，audit-only 早退之后）/7050(removeChild)/8922(addLinks)/8942(removeLinks)/8965(reorderLink)；v1/v3 alias 经 `datas.service:1306/1344`、`data-alias-nested:397/430` 汇入 addChild/removeChild；nestedLink/nestedReorder 经 `data-table.service:657/731` 汇入 addLinks/reorderLink；引擎走 raw-knex 无 bypass | PASS（代码+活体） |
| 4. paste+link | createSync paste+link → 400（browse-mode 说明文）；paste sourceSchema 仅 `Title,Qty` 无 link；纯标量 paste 200 → active 单 mapping；`syncPasteLinkUnsupported` en+zh-Hans 双 key 在册；paste 零成员账号直读源表（对照通道正常） | PASS |
| 5. deleteSync | 级联三表 404 + sync 行 404；僵尸守卫代码核验（`table-syncs.service.ts:1690-1746`：main 失败查 `Model.get` 存活则 throw 保 sync 行，已删则继续；junction/shadow best-effort；role 排序 J→S→M）+ Fork 2 用例随 60/60 过 | PASS |
| 6. mark_deleted | manual 全量档：删源 p1 → resync → RemoteDeleted=true + J 2→1；realtime 增量档：删源 p2 → ~20s 镜像打标 + J 2→0（两档统一「配对恒镜像源 junction」） | PASS |

## P1-P3 站位（抽查）

- realtime link 事件 → J 1→2（~15s，full-resync 简化档）；realtime 标量 insert → p9 出镜 RemoteId=4（incremental 无回归）
- junction `includeM2M=true` 可见；镜像改名 400；editor meta 列操作 403；E1 未知字段 400；listSyncs 无凭据字段（python 核验 keys + 无 uuid/shared/secret/token 命中）；browse sourceSchema 列出 Ns,Ns2（向导三层可选数据源）
- `syncTrigger:auto` → 400（`TableSyncTrigger` 仅 Manual/Realtime；“AUTO 双档”= realtime 档，见 f09-research flag 族考据；非产品问题）

## 质量门

- `jest --testPathPattern Fork`：**60/60**（3 suites，`/tmp/l1_jest.log`）
- `tsc --noEmit`：本次 runs 超时未落盘，但 `packages/` 与 5368ef1366 diff 为空 → 类型结果与 R1 修复批记录（exit 0）同一；继承有效
- Vite URL 门：`packages/nc-gui/` 相对基线零 diff → 无对象（后验：i18n 双 key 在 R1 批内已合入）

## Minor（1，继承不阻塞）

- **M2（lane3b M2 carry-over）**：owner 对 junction `POST /columns` → 200 落列（editor 已被 meta ACL 挡 403）；新列不进 mappings、无数据损坏。维持已知裁剪记录，未在本轮范围。

## 备注（非问题）

- reorder 公共 v2 路由不存在（404 系路由缺席）；守卫在 `nestedReorder→reorderLink` service 方法内，internal-ops 通道代码可达。
- detach 写：单记录 PATCH 路由本就不存在（404 系本人方法误用）；bulk PATCH 200 且落盘 `detached-ok4`，detach 后可写成立。
- editor 授权：email 体 PATCH 报 22001，改 userId 路径 PATCH 成功（测试环境 API 形态，与产品守卫无关）。
