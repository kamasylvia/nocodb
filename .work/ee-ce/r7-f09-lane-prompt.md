你是 NocoDB CE-EE fork 的 F09 Sync data（P1 Table Sync）第 7 轮复审（R7）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/r3-f09-lane-prompt.md`（同规格任务书）、`.work/ee-ce/r4-f09-lane-prompt.md` 与 `.work/ee-ce/r6-f09-lane-prompt.md`（增量附录，回归项全部继承），再读本增量。

## 审查基线

HEAD = 5a11c4ab86（R6 修复批）。后端 :8080 无改动（~/.nocodb-run dist 即当前）；前端 :3000 Nuxt dev HMR 已含全部修复，无需任何构建/重启。

## R7 增量附录（R6 修复批回归）

### A. 创建流树刷新（5a11c4ab86 修复点 1，R6 三路同判）

`CreateNewSync.vue` 创建路径原调 `useBases().loadTables()`（bases store 无此方法，TypeError 在 try 块内被吞，树永不刷新）。现改 `useBase()` store 的 `loadTables` 并 await。验证：向导完整走通创建 → **不刷新页面**：树即时出现 synced 表（带 sync 图标）；无红色错误 toast 与成功 toast 并存；API 侧 sync active。

### B. 删除流自动跳转（5a11c4ab86 修复点 2，R6 四路同判）

`SyncMenuOptions.vue` onDelete 原**在 loadTables() 之后**才比 activeTable（恒 undefined → 跳转分支死代码，停死 URL 空白网格）。现先捕获 `oldActiveTableId` 再 remove（DlgTableDelete 同款）。验证两腿：
1. **剩余表腿**：删除当前打开的 synced 表（base 内还有其它表）→ 不刷新页面：树即时移除 + **自动跳到剩余首表**（URL 与主区一致，无空白网格/死 tabs）。
2. **base 根腿**：base 内删至 0 表 → 自动跳 base 根 URL。
3. 非当前打开表删除 → 不触发跳转、树即时移除。

### C. 全部继承回归

R6-A E1 六格矩阵（dd46a3eb1d 显式 base no-access 全 404 + createSync 数据面不落镜像）、R6-B R5 四象限重跑、R6-C minors（M1 可搜索选择器 / M2 菜单 open-watch 新鲜度 / editor 三入口 fail-closed）、ACL 十端点、引擎 e2e、守卫链、质量门（tsc 0 + jest Fork 桶全过）——按 r6-f09-lane-prompt.md 附录执行。

### D. 沿袭已知项（勿重复报，除非升级）

selectedFields:[] 空数组、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、拒绝码 404 vs 平台 403（fail-closed）、legacy 'no_access' 服务端多拒（fail-closed）、FAILED 详情泛型、resolve-link 501、realtime 400（付费锁）、editor 删镜像行 422 = 上游 ERR_SYNC_TABLE_OPERATION_PROHIBITED 语义（R6 裁定非缺陷）、paused 菜单 Sync now 可点 400 fail-closed（backlog 观察）、深链直开 base 树骨架（框架级）。

## 纪律

- 只读审查：严禁修改源码；只写报告与 /tmp 脚本
- 隔离：禁读其它 lane 报告（r7-f09-lane*.md 他路及历轮他路）
- **严禁 dev-backend*.sh / pkill / 重启后端 / 进程操作**；8080 异常每 60s 轮询（连续 3 次失败才记 E3，勿自愈）
- 严禁 psql 提全局 super（自建账号角色置位等效 invite API 允许）
- camoufox --session f09r7lN 专属会话
- 测试数据全部 `f09r7lN-` 前缀，测试 base 测完删除
- 报告落盘 `.work/ee-ce/r7-f09-laneN.md`（N = 你的 lane 号；被占则 -b 后缀并注明）
- 报告格式：结论（PASS / N error + N minor）开头，逐项证据，附质量门结果
