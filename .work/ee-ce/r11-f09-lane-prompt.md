你是 NocoDB CE-EE fork 的 F09 Sync data（P1 Table Sync）第 11 轮复审（R11）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/r3-f09-lane-prompt.md`（同规格任务书）、`.work/ee-ce/r6-f09-lane-prompt.md`、`.work/ee-ce/r8-f09-lane-prompt.md`、`.work/ee-ce/r10-f09-lane-prompt.md`（增量附录，回归项全部继承），再读本增量。

## 审查基线

HEAD = 5bea0c3943（代码面同 5e3d736b2a：SyncMenuOptions storeToRefs 修复，R10 全轮零代码变更）。后端 :8080 / 前端 :3000 运行中。

## 背景

R8 修复（5e3d736b2a）后 R9/R10 连续两轮 0 error（连击 2/3）。**R11 为 pass 冲刺轮：本轮再 0 error → 连击 3/3 → F09 P1 pass。** 按 R10 同规格执行站位回归。

## R11 增量附录

### A. 站位回归（R10 同规格复验）

1. **删除流自动跳转三腿 + 判别对照**（5e3d736b2a，camoufox 活体）：剩余表腿 / base 根腿 / 非当前表腿 + DlgTableDelete 对照
2. **编译健康先行门**：SyncMenuOptions.vue / CreateNewSync.vue Vite URL → 200；base 页无 vite-error-overlay
3. 创建流树刷新（无刷新树即时出现 + 无 toast 并存）、树菜单新鲜度三态翻转、可搜索选择器、editor 三入口不可见 + API 403
4. E1 六格矩阵、R5 四象限、ACL 十端点、引擎 e2e（full-create/resync/双删除策略/freeze-resume/deleteSync）、守卫链、系统列网格不可见

### B. 方法学（沿袭生效）

1. 零关系调用者 403/404 双 fail-closed 码均 PASS
2. 矩阵账号 dest-creator 提权；角色变更经 API PATCH 失效缓存
3. UI 与 API 测试账号分离
4. v2 records 单行 PATCH/DELETE 为 body 式
5. R10 lane5 观察项沿袭：测试脚本 querySelector 须过滤可见性（残留 overlay 误删致假象）；v2 table meta `columns[].show` 返回 null 为沿袭表述差（网格隐藏判据 DB GVC show=false + SDK isHiddenCol，功能正确）

### C. 沿袭已知项（勿重复报，除非升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台（fail-closed）、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）、source-schema 对无 allow_sync 视图仍 200（create 侧强制，灰区）、columns[].show=null 表述差。

## 纪律

- 只读审查：严禁修改源码；只写报告与 /tmp 脚本
- 隔离：禁读其它 lane 报告（r11-f09-lane*.md 他路及历轮他路）
- **严禁 dev-backend*.sh / pkill / 重启后端 / 进程操作**；8080/3000 异常每 60s 轮询，连续 3 次失败记 E3，勿自愈
- 严禁 psql 提全局 super（自建账号角色置位等效 invite API 允许）
- camoufox --session f09r11lN 专属会话；UI 与 API 测试账号分离
- 测试数据全部 `f09r11lN-` 前缀，测试 base 测完删除
- 质量门：后端 tsc + jest Fork 桶（超时 >300s 记未完成勿重试）；前端编译健康按 Vite URL 法
- 报告落盘 `.work/ee-ce/r11-f09-laneN.md`（沙箱禁写则完整输出 stdout 文末注明待 orchestrator 落盘）
- 报告格式：结论（PASS / N error + N minor）开头，逐项证据，附质量门结果
