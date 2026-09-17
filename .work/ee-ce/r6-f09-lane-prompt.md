你是 NocoDB CE-EE fork 的 F09 Sync data（P1 Table Sync）第 6 轮复审（R6）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/r3-f09-lane-prompt.md`（同规格任务书）与 `.work/ee-ce/r4-f09-lane-prompt.md`（R4/R5 增量附录，其中回归项全部继承），再读本增量。

## 审查基线

HEAD = R5 修复批之后（dd46a3eb1d + R5 minors 修复批）。前端改动经 :3000 Nuxt dev server HMR 生效（无需构建）。

## R6 增量附录（R5 修复批 + minors 回归）

### A. E1 修复回归（commit dd46a3eb1d，五路同判的 fail-open）

`assertSourceReadAccess` 现含 baseNoAccess 短路：显式 base 角色 = no-access（'no_access'/'no-access' 双拼写）→ 无条件 404，无论 ws 角色与 base 私有性。**六格矩阵**（每格 source-schema + 平台 GET base 对照；平台语义 = 显式 no-access 两路皆拒）：

| 象限 | 平台预期 | F09 预期 |
|---|---|---|
| 非私有 + 显式 no-access + ws 可读（ws-creator/editor） | 403 | 404（E1 修复点） |
| 非私有 + 显式 no-access + ws no-access | 403 | 404 |
| 私有 + 显式 no-access + ws 可读 | 404 | 404 |
| 私有 + 显式 no-access + ws no-access | 404 | 404 |
| 非私有 + 显式 no-access → createSync | 平台拒 | 404（数据面不落镜像） |

### B. R5 四象限重跑（f81e24a4f4 回归不破）

| 象限 | 预期 |
|---|---|
| 非私有 + 零 base 行 + ws-creator | 200 |
| 非私有 + 显式 editor + ws no-access | 200 |
| 非私有 + 零关系 + ws no-access | 404 |
| 非私有 + inherit + ws-creator | 200 |
| 私有 + 零 base 行 + ws 可读 | 404 |
| 私有 + inherit + ws no-access | 404 |

### C. R5 minors 修复回归（前端，:3000 HMR）

1. **M1 可搜索选择器**：CreateNewSync.vue 两个 NcSelect 现为 `show-search` + `:filter-option`（按 label 匹配）。验证：向导 step0 base 下拉输入 base 名关键字 → 命中过滤；输入 table 名 → 命中。
2. **M2 树菜单新鲜度**：SyncMenuOptions 新增 `open` prop watch（菜单每次打开重拉 sync 记录）+ loading 占位行（load 未完成时不再整块消失）。验证：Sync now 后**不刷新页面**重开菜单 → 状态不再是 Syncing（应显示 active + Pause 项恢复）；freeze/resume 后重开菜单项正确翻转。
3. **M2 删除流**：onDelete 现走 DlgTableDelete 同款后清理（旧代码 `useBases().loadTables()` 是不存在的方法，运行时 TypeError，树永不刷新）。验证：Delete sync 确认后（不刷新页面）：树中该表即时消失；若当前正打开该表视图 → 自动跳到剩余首表（或 base 根）；近期视图列表不再含已删表。
4. editor 三入口：保持不可见或仅 fail-closed 可见（lane 分歧已裁定为验收措辞偏差，无泄露通道——若发现 editor 能成功 createSync/读源 schema 即报 error）。

### D. 沿袭已知项（勿重复报，除非升级）

selectedFields:[] 空数组、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 设计灰区）、拒绝码 404 vs 平台 403 语义差（fail-closed 方向）、legacy 'no_access' 下划线拼写服务端多拒（fail-closed）、FAILED 详情泛型、resolve-link 501、realtime 400（付费锁保持）。

## 全矩阵/质量门

同 r3-f09-lane-prompt.md 任务书（8 项清单），质量门 tsc 0 + jest Fork 桶全过（当前 41/41）。

## 纪律

- 只读审查：严禁修改源码；只写报告与 /tmp 脚本
- 隔离：禁读他路报告；账号 f09r6lN-* 前缀；严禁 psql 提全局 super
- **严禁 dev-backend*.sh / pkill / 重启后端**；8080 异常每 60s 轮询
- camoufox --session f09r6lN 专属会话（互踩防护）
- 报告落盘 `.work/ee-ce/r6-f09-laneN.md`（若文件已被占，落 r6-f09-laneN-b.md 并在报告头注明）
