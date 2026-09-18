## R11 F09 Lane3 审查报告

**结论：PASS（0 error + 0 minor）**

审查员：f09r11l3（lane 3）
HEAD：5bea0c3943
日期：2026-09-18
基线：R8 修复（5e3d736b2a）后 R9/R10 连续两轮 0 error，R11 为 pass 冲刺轮。

---

### A.2 编译健康先行门

**⚠️ 沙箱限制**：curl / camoufox MCP 网络调用均被沙箱约束阻断（"blocked: the current constraints forbid state mutation"），无法执行 Vite URL HTTP 200 检查。

**静态替代验证**：
- `SyncMenuOptions.vue`（189行）：Vue 3 SFC `<script setup lang="ts">` + `<template>` 结构完整。L31 `storeToRefs(tablesStore)` 修复确认生效。
- `CreateNewSync.vue`（326行）：Vue 3 SFC 结构完整，三步向导模板正确闭合。L21 `refreshBaseTables` 别名（R7 修复）确认。
- 质量门佐证：`npx tsc --noEmit` 退出码 0（无错误），间接确认 TS 编译链健康。

### B. 删除流自动跳转三腿 + 判别对照

**5e3d736b2a 修复代码静态审查确认**：
1. **storeToRefs**（L30-32）：state 通过 `storeToRefs` 解构（响应式），action 裸解构（函数引用），与上游 DlgTableDelete 一致
2. **三腿**（L61-86）：`oldActiveTableId` 在 `remove()` 前捕获 → 剩余表腿 `openTable(remaining[0])` / base 根腿 `navigateTo(baseUrl(...))` / 非当前表跳过跳转
3. **树刷新**（L73-75）：`removeFromRecentViews` + `removeMeta` + `loadTables()` 对齐 DlgTableDelete

### C. 创建流 + 树菜单新鲜度 + 可搜索选择器

- 创建流：`refreshBaseTables()`（L141）用 `useBase()` 别名，非已修 bug `useBases().loadTables()`
- 树菜单：`watch(() => props.open)` 每次打开重拉 + loading 占位行（L92-95）
- 选择器：`filterSelectOption`（L43-50）按 label/value 过滤，两个 NcSelect 均配置 `show-search`

### D. editor 三入口 + API 403

- **ACL**：editor include 不含任何 `tableSync*`（acl.ts L549-658）→ 10 端点全 403
- **creator exclude**：仅 `baseDelete/migrateBase`（acl.ts L660-664）→ `tableSync*` 不排除 → creator+ 有权限
- **VIEWER include**（L461-491）：不含 `tableSync*` → 403

### E. 后端 API 审查

**Controller 10 端点**：全部带 `@UseGuards(MetaApiLimiterGuard, GlobalGuard)` + `@Acl` 装饰器 ✅

**服务层关键逻辑**：
- `assertSourceReadAccess`（L91-141）：完整平台谓词匹配（base 角色优先 → ws 继承 → no_access 短路 → 私有 base 隔离）
- `allow_sync` 强制（L190-194）、保留名守卫（L341-356）、realtime API 400（L325-329）
- `system:true` 后置补丁（L498-517）、缓存失效 PARENT_TO_CHILD（L521-525）
- `selected_fields` 拒绝更新（L654-658），P2 scope

**引擎**（table-sync.processor.ts）：
- RemoteId 键控 upsert（L142-227）、分页读源 500/页、引擎白名单（L232-238）
- 消失行：mark_deleted → `bulkUpdate RemoteDeleted=true`；delete → `bulkDelete`
- 错误：catch → status=error + last_error，不 rethrow

**Module 注册**：Controller (noco.module.ts L247) + Processor (jobs.module.ts L101) + JobType (jobs-map.service.ts L96) ✅

### F. 质量门

| 门 | 结果 |
|----|------|
| tsc --noEmit | **PASS** 退出码 0 |
| jest Fork 桶 | **PASS** 3 suites / 41 tests / 41 passed / 75s |
| Vite URL | **⚠️ 未执行**（沙箱阻断；静态审查无语法错误） |

### G. 沿袭已知项（未升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台（fail-closed）、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）、source-schema 对无 allow_sync 视图仍 200（create 侧强制，灰区）、columns[].show=null 表述差。

---

**审查方式**：纯静态代码审查（沙箱阻断 curl/camoufox/MCP）。质量门 tsc + jest Fork 桶实际执行通过。Vite URL 健康检查未能执行。

**判定**：本轮 0 error，连击 3/3（R9 + R10 + R11）→ **F09 P1 PASS 建议通过**。

---

**⚠️ 待 orchestrator 落盘**：报告文件 `.work/ee-ce/r11-f09-lane3.md`（沙箱禁写，完整报告如上 stdout 输出）
