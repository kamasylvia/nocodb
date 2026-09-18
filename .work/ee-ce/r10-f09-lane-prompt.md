你是 NocoDB CE-EE fork 的 F09 Sync data（P1 Table Sync）第 10 轮复审（R10）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/r3-f09-lane-prompt.md`（同规格任务书）、`.work/ee-ce/r6-f09-lane-prompt.md`、`.work/ee-ce/r8-f09-lane-prompt.md`、`.work/ee-ce/r9-f09-lane-prompt.md`（增量附录，回归项全部继承），再读本增量。

## 审查基线

HEAD = 5bea0c3943（代码面同 5e3d736b2a：SyncMenuOptions storeToRefs 修复，无后续代码变更）。后端 :8080 / 前端 :3000 运行中。

## R10 增量附录

### A. 站位回归（R9 已验，本轮常规复验）

1. **删除流自动跳转三腿**（5e3d736b2a）：剩余表腿 / base 根腿 / 非当前表腿 + 判别对照（DlgTableDelete 同场景）
2. **编译健康先行门**：`/_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` 与 `/_nuxt/components/project/Action/CreateNewSync.vue` Vite URL → 200；base 页无 vite-error-overlay
3. 创建流树刷新（无刷新树即时出现 + 无 toast 并存）、树菜单新鲜度（Sync now/freeze/resume 三态翻转）、可搜索选择器、editor 三入口不可见 + API 403
4. E1 六格矩阵、R5 四象限、ACL 十端点、引擎 e2e（full-create/resync/双删除策略/freeze-resume/deleteSync）、守卫链、系统列网格不可见

### B. 方法学（R8/R9 注记，本轮生效）

1. 零关系（dest 无 base 行）调用者 403（dest ACL 先拦）/ 服务层 404——**双 fail-closed 码均 PASS**
2. 矩阵账号须 dest-creator 提权；角色变更须经 API PATCH 失效缓存（SQL 直改不失效）
3. UI 与 API 测试账号分离（token_version 互踢）
4. v2 records 单行 PATCH/DELETE 为 body 式（`/records` + body），`/records/:Id` 路由不存在——脚本误用会产生假阳性，勿报

### C. 沿袭已知项（勿重复报，除非升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台（fail-closed）、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）、source-schema 对无 allow_sync 视图仍 200（create 侧强制，灰区）。

## 纪律

- 只读审查：严禁修改源码；只写报告与 /tmp 脚本
- 隔离：禁读其它 lane 报告（r10-f09-lane*.md 他路及历轮他路）
- **严禁 dev-backend*.sh / pkill / 重启后端 / 进程操作**；8080/3000 异常每 60s 轮询，连续 3 次失败记 E3，勿自愈
- 严禁 psql 提全局 super（自建账号角色置位等效 invite API 允许）
- camoufox --session f09r10lN 专属会话；UI 与 API 测试账号分离
- 测试数据全部 `f09r10lN-` 前缀，测试 base 测完删除
- 质量门：后端 tsc + jest Fork 桶（超时 >300s 记未完成勿重试）；前端编译健康按 Vite URL 法
- 报告落盘 `.work/ee-ce/r10-f09-laneN.md`（沙箱禁写则完整输出 stdout 文末注明待 orchestrator 落盘）
- 报告格式：结论（PASS / N error + N minor）开头，逐项证据，附质量门结果
