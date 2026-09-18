你是 NocoDB CE-EE fork 的 F09 Sync data（P1 Table Sync）第 8 轮复审（R8）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/r3-f09-lane-prompt.md`（同规格任务书）、`.work/ee-ce/r4-f09-lane-prompt.md`、`.work/ee-ce/r6-f09-lane-prompt.md`、`.work/ee-ce/r7-f09-lane-prompt.md`（增量附录，回归项全部继承），再读本增量。

## 审查基线

HEAD = 9c4db33fe1（含 R7 blocker 修复）。后端 :8080 无改动；前端 :3000 Nuxt dev 即当前源码（R7 坏页已修复）。

## R7 事故背景（裁决已归因）

R6 修复批 5a11c4ab86 曾引入 `CreateNewSync.vue` L18 与 L76 `loadTables` 重复声明 → SFC 编译失败 → 任意 base 页整页崩（4/5 路同判）。R7 期间（09:29–10:0x）前端处于坏页状态，四路 CLI 的 UI 段全部被阻塞。修复 9c4db33fe1：store 版别名 `refreshBaseTables`（:138 创建路径调用），本地 `loadTables(baseId)`（:76，向导源表加载器，:159 watch 使用）保留。**R8 首项即验证编译健康，再补 R7 全部未竟 UI 验证。**

## R8 增量附录

### A. 编译健康（先行门）

1. `curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/_nuxt/components/project/Action/CreateNewSync.vue` → 200（500 = 编译错误，立即报 error）
2. 同法验证 `components/dashboard/TreeView/Table/SyncMenuOptions.vue` → 200
3. 打开任意 base 页 → 无 Vite error overlay、无 "error loading dynamically imported module"

### B. R7 未竟 UI 验证（本轮重点，前轮被坏页阻塞）

1. **创建流树刷新**（R6 修复点 1 + R7 回归）：向导完整走通创建 → 不刷新页面：树即时出现 synced 表；无成功/错误 toast 并存；API 侧 sync active
2. **删除流自动跳转**（R6 修复点 2）双腿：①删除当前打开的 synced 表（base 内还有其它表）→ 树即时移除 + 自动跳剩余首表（URL 与主区一致）②base 内删至 0 表 → 跳 base 根 URL ③非当前打开表删除 → 不跳转、树即时移除
3. **树菜单新鲜度**：Sync now / freeze / resume 后不刷新页面重开菜单 → 状态即时正确
4. **可搜索选择器**：向导 step0 base/table 下拉按关键字过滤命中
5. editor 三入口 fail-closed 复查

### C. 全部继承回归

R6-A E1 六格矩阵（显式 base no-access 全 404 + createSync 数据面不落镜像）、R6-B 四象限、ACL 十端点、引擎 e2e（full-create/resync/双删除策略/freeze-resume/deleteSync）、守卫链、系统列网格不可见——按 r6/r7 prompt 附录执行。

### D. 沿袭已知项（勿重复报，除非升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、404 vs 平台 403（fail-closed）、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）。

## 纪律

- 只读审查：严禁修改源码；只写报告与 /tmp 脚本
- 隔离：禁读其它 lane 报告（r8-f09-lane*.md 他路及历轮他路）
- **严禁 dev-backend*.sh / pkill / 重启后端 / 进程操作**；8080/3000 异常每 60s 轮询，连续 3 次失败记 E3，勿自愈
- 严禁 psql 提全局 super（自建账号角色置位等效 invite API 允许）
- camoufox --session f09r8lN 专属会话
- 测试数据全部 `f09r8lN-` 前缀，测试 base 测完删除
- 质量门：tsc/jest 单跑（本轮 lane 少可错峰；超时 >300s 记「未完成」勿反复重试）；**前端编译健康按附录 A 的 Vite URL 法**（tsc/jest 不编译 .vue，这是 R7 漏网根因）
- 报告落盘 `.work/ee-ce/r8-f09-laneN.md`（N = 你的 lane 号；沙箱禁写则完整输出 stdout 并在文末注明「待 orchestrator 落盘」）
- 报告格式：结论（PASS / N error + N minor）开头，逐项证据，附质量门结果
