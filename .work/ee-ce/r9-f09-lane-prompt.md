你是 NocoDB CE-EE fork 的 F09 Sync data（P1 Table Sync）第 9 轮复审（R9）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/r3-f09-lane-prompt.md`（同规格任务书）、`.work/ee-ce/r6-f09-lane-prompt.md`、`.work/ee-ce/r8-f09-lane-prompt.md`（增量附录，回归项全部继承），再读本增量。

## 审查基线

HEAD = 5e3d736b2a（R8 修复批：SyncMenuOptions storeToRefs）。后端 :8080 无改动；前端 :3000 Nuxt dev 即当前源码。

## R8 事故背景（裁决已归因）

R8 lane5（UI 专项）活体实测：SyncMenuOptions.vue 裸解构 `useTablesStore()`（缺 storeToRefs）→ `activeTable.value` 恒 undefined → 删除流自动跳转**两腿死代码**（删当前打开表应跳剩余首表 / 删至 0 表应跳 base 根——URL 均停死）。修复 5e3d736b2a：state 经 `storeToRefs` 解构，actions 保持裸解构（对齐上游 DlgTableDelete）。lane1 的 minor1（0 表 URL 未归根）同根同修。

## R9 增量附录

### A. 删除流自动跳转回归（本轮重点，5e3d736b2a 修复验证，须 camoufox 活体）

1. **剩余表腿**：删除当前打开的 synced 表（base 内还有其它表）→ 树即时移除 + **自动跳到剩余首表**（URL 与主区一致，无空白网格/死 tabs）
2. **base 根腿**：base 内删至 0 表 → **URL 归一到 base 根**（`/nc/<baseId>`）
3. **非当前表腿**：删除非当前打开表 → 不跳转、树即时移除
4. **判别对照**：同场景删普通表（DlgTableDelete 路径）跳转行为与 F09 删除流一致

### B. 编译健康先行门（R8 方法保留）

`/_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` 与 `/_nuxt/components/project/Action/CreateNewSync.vue` Vite URL → 200；base 页无 vite-error-overlay。

### C. 站位回归（全继承）

创建流树刷新（无刷新树即时出现 + 单一成功 toast）、树菜单新鲜度（Sync now/freeze/resume 三态翻转）、可搜索选择器、editor 三入口不可见 + API 403、E1 六格矩阵、R5 四象限、ACL 十端点、引擎 e2e（full-create/resync/双删除策略/freeze-resume/deleteSync）、守卫链、系统列网格不可见——按 r6/r8 prompt 附录执行。

### D. 方法学注记（R8 lane1 建议，本轮生效）

零关系（dest 无 base 行）调用者调 source-schema 会先被 dest 侧 ACL 403 拦截（到不了服务层 404）——**403/404 双 fail-closed 码均判 PASS**，不作为发现。若需测服务层判定，用 dest-creator 临时提权的 dest-qualified 调用者。

### E. 沿袭已知项（勿重复报，除非升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台（fail-closed）、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）、source-schema 对无 allow_sync 视图仍 200（create 侧强制，灰区）。

## 纪律

- 只读审查：严禁修改源码；只写报告与 /tmp 脚本
- 隔离：禁读其它 lane 报告（r9-f09-lane*.md 他路及历轮他路）
- **严禁 dev-backend*.sh / pkill / 重启后端 / 进程操作**；8080/3000 异常每 60s 轮询，连续 3 次失败记 E3，勿自愈
- 严禁 psql 提全局 super（自建账号角色置位等效 invite API 允许）
- camoufox --session f09r9lN 专属会话；UI 与 API 测试账号分离（token_version 互踢）
- 测试数据全部 `f09r9lN-` 前缀，测试 base 测完删除
- 质量门：后端 tsc + jest Fork 桶（超时 >300s 记未完成勿重试）；前端编译健康按附录 B Vite URL 法
- 报告落盘 `.work/ee-ce/r9-f09-laneN.md`（沙箱禁写则完整输出 stdout 文末注明待 orchestrator 落盘）
- 报告格式：结论（PASS / N error + N minor）开头，逐项证据，附质量门结果
