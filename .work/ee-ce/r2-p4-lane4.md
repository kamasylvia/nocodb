# F09 P4 R2 会审报告 — lane 4（引擎重点路）

## 结论：**PASS**（0 error + 1 minor）

- 审查员：lane 4（引擎重点：①updateSync link 级联活体 ②双 shadow 共享 ③mark_deleted 两档一致性 ④P1-P3 标量引擎无回归）；账号 `f09p4r2l4-api@lantest.local`（owner，经既有 infra super 测试账号邀请建 base，沿用前轮模式）
- 基线：5368ef1366（R1 修复批）= 工作树源码零 diff（`git diff 5368ef1366..HEAD -- packages/` 为空，含未跟踪 src 文件）；:8080 运行 `~/.nocodb-run` 修复后 dist（pid 54900），全程未构建/未重启/未 pkill/未 psql
- 方法：静态精读 updateSync 级联/dropShadow/addMirrorLinkColumn/processor 三模式/realtime dispatch/守卫五入口 + :8080 活体全链（脚本 `.work/ee-ce/f09p4r2l4-run{1..5}.sh` + lib）

---

## R1 四大族回归核验（逐族）

### 族1 updateSync link 级联重写 — PASS（活体全过）

| 场景 | 实测 |
|---|---|
| keep-link PATCH `["Title","Ns"]`（去 Qty 保 Ns） | dest Ns 列 id 前后不变（cxsyz56rw5naoht）、Qty 列删除、junction 3 行原样、shadow 2 行原样、mappings=3 全保留、无 500 |
| null PATCH（=全字段含 links） | Qty 回归 + Ns 列 id 不变 + junction 3 行；`selected_fields` 落库 null |
| `[]` / `["Bogus"]` | 均 400 |
| 掉线 link 级联（`["Title"]`） | 镜像 Ns 删、junction 表 + shadow 表 + junction/shadow mapping + link 列映射全清（旧行为「拆毁保留 link」已不复现——保留 link 不进 drop 分支） |
| **结构变更后自动 full-resync 回填** | 恢复 PATCH `["Title","Qty","Ns"]` → 新 junction + 新 shadow 自动建立，**无需手动 resync** 即回填 3 配对 + 2 shadow 行（R1「静置 junction=0」不复现）；mirror 列 Title/Qty/Ns 齐 |
| 静态核对 | drop loop 以 `fk_table_sync_mapping_id===mainMapping.id` 限定主映射域（lane4b E1 子效应「shadow 列身份映射被静默清除」已修）；keptLinkRtIds 改由 desiredLinks 解析（原死代码已复活）；`[]`→400 前置校验在位（service.ts:1345-1352） |

### 族2 双 shadow 共享 — PASS（活体全过）

- 源 T1 加第二条同 RT link（Ns2→T2）→ PATCH 数组加腿 → **linked_shadow mapping 仍 1 条**（共享 shadow meyq13wqcdkcot9，无新表）、junction mapping 2 条；Ns junction 3 配对、Ns2 junction 1 配对（m1-s2）——**FK 值正确指向共享 shadow 的 n2 行**，引擎 `shadowRemoteToPkBySource` 键冲突随共享消失。
- 静态核对：加腿循环的 `shadows`/`takenTitles` 提循环外且以既有 linked_shadow mappings 播种（dest model 存活才复用，service.ts:1572-1583）。
- **单删不拆共享 shadow**：PATCH 去 Ns2 → Ns2 junction + 镜像 Ns2 列 + link 列映射清，**shadow 存活（2 行）+ shadow mapping 保留**，Ns 链路 3 配对原样；null 再加回 Ns2 → 复用同一 shadow（无新表）+ 新 junction。
- 观察（非缺陷）：selection PATCH 与 realtime job 竞态（status=syncing 窗口）→ 400 "Cannot update a sync while it is running"——既有守卫，静置后重试成功。

### 族3 LTAR 通道守卫 — PASS（spot 活体 + 静态五入口）

- 镜像 link 列 nestedLink/nestedUnlink → **422** + 专属文案 "Link operations … prohibited on synced table f09p4r2l4-sync1"（旧版 201/200）。
- 静态：五入口全挂 `assertLinkWriteAllowed`（addChild 在 audit-only 早退之后 L6654 = audit replay 放行；removeChild L7050；addLinks/removeLinks/reorderLink 在 checkPermission **之前** L8922/8942/8965 = 与角色无关）。
- 引擎 raw-knex 通道无 bypass 需求——活体反证：守卫挂载后全部 junction 回填/清理照常工作（recomputeJunctionPairs/cleanupJunctionOrphans 不经五方法），防环不破。

### 族4 paste+link 拒收 — PASS（spot 活体）

- paste createSync selectedFields 含 link → **400** + browse-mode 说明文案（en 活体验证；zh-Hans 键 `msg.warning.syncPasteLinkUnsupported` 经 jq 确认存在且为中文文案）。
- paste 分支 sourceSchema **不列 link 列**（仅 Title/Qty，Ns 隐藏）。
- 纯标量 paste → **200** + sync active（不误伤）。

### 族6 mark_deleted 两档一致性 — PASS（活体全过）

- sync2（mark_deleted + realtime + link）：源删 p2 → **incremental 档**：镜像行 p2 保留且 `RemoteDeleted=true`（行级策略），**junction 配对 (m2,s1) 同步清除（3→2）**——R1「增量档保留陈旧配对」不复现。
- **full 档**（手动 resync）：p2 仍 flagged、junction 仍 2 配对（无复活）——两档语义统一「junction 配对恒镜像源 junction」。
- 对照 sync1（delete 策略）同一事件：镜像行删除 + 配对清除（3→2），双 sync 互不串扰。
- 静态核对：`orphanedMainPks = pendingDeletes ∪ flagged`（processor.ts:486-493）；注释修订在分支处（:462/:479-485）在位。

### ④ P1-P3 标量引擎回归 — PASS（spot 活体）

- 标量插入 p3 → 双 sync 镜像 ~13s 内出行（incremental 无回归）；
- 源 link 加配对 → link tap → full-resync → junction 增 (m3,s1)、镜像 Ns LTAR 解析正确；
- T2（shadow 源表）标量更新 → shadow 行 Secret 传播（s2→s2-UPD，role=linked_shadow → full-resync 分发正确）；
- 手动 resync（full pass 含 sweep）正常收敛、`last_error` 全程 null；
- 质量门 tsc/jest 全绿（见下）。

## Minor（1 条）

- **M1（doc-only）**：`packages/nocodb/src/modules/jobs/jobs/table-sync/table-sync.processor.ts:991-993` `cleanupJunctionOrphans` 方法 docstring 仍写 "delete policy only — mark_deleted rows stay and keep their pairs"，与调用方（:478-501，族6 修复后 flagged pk 也传入）矛盾。行为正确（活体已证），属上轮注释修订漏改此方法头。建议下轮顺手改注释。

## 质量门

- `npx tsc --noEmit`：**exit 0**。
- `npx jest --testPathPattern 'Fork'`：**60/60**（3 suites；P1-P3 44 + P4 3 + R1 13）。
- Vite URL 门：**无 SFC 对象**——R1 批 nc-gui 侧仅改 `lang/en.json` + `lang/zh-Hans.json`（git show 核验），两文件 jq 解析合法且新键在位；Vite dev server（:3000）root 200。

## 纪律

- 只读：零源码改动（基线 diff 空）；:8080 未动构建/重启/dev-backend*.sh/pkill；无 psql。
- 隔离：未读任何他路报告（本轮 lane1/2/3/5 报告均未触碰）。
- 测试数据全清：SRC/DST base DELETE 200、paste sync DELETE 200、残余 `f09p4r2l4` base 0；测试账号 `f09p4r2l4-api@lantest.local` 保留可复测（无 base 归属）；脚本 `.work/ee-ce/f09p4r2l4-*.sh` 留存。
