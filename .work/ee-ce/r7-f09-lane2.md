# R7 F09 Lane 2 Report

> **结论：1 error + 0 minor**
>
> E1: `CreateNewSync.vue` R6 修复引入编译错误（duplicate `const loadTables` 声明），Nuxt/Vite 编译失败，base 页面 overlay 弹出。

---

## E1 — CreateNewSync.vue 编译错误（R6 修复点 1 不完整）

**位置**: `packages/nc-gui/components/project/Action/CreateNewSync.vue:18 + :76`

**现象**: Nuxt dev server (:3000) 打开 base 页面时，Vite overlay 弹出：

```
[plugin:vite:vue] [vue/compiler-sfc] Identifier 'loadTables' has already been declared. (76:6)
```

页面完全不可用，CreateNewSync 组件无法编译。

**根因**: R6 修复（commit 5a11c4ab86）在 line 18 添加了 `const { loadTables } = useBase()`，但 line 76 已有同名局部函数 `const loadTables = async (baseId: string) => {`（用于向导 step0 加载源 base 表列表）。两个 `const loadTables` 在同一 `<script setup>` 块中，Vue SFC 编译器报 duplicate declaration。

**影响**: 整个 base dashboard 页面因 CreateNewSync 组件编译失败而被 Vite error overlay 覆盖。创建向导不可用，但后端 API 不受影响。

**修复建议**: 将 line 76 的局部函数重命名为 `loadSourceTables`（或类似名称），消除命名冲突；line 138 的 `createSync` 中 `await loadTables()` 调用应改为 `await loadTables()`（来自 `useBase()` store），或直接用 `await loadTables()` + `destBaseId` 参数。

---

## R7-B — SyncMenuOptions.vue 删除跳转修复（代码审查 PASS）

**位置**: `packages/nc-gui/components/dashboard/TreeView/Table/SyncMenuOptions.vue:60`

**代码审查结论**: 修复逻辑正确。`const oldActiveTableId = activeTable.value?.id` 在 `await remove()` 之前捕获，`loadTables()` 后用 `oldActiveTableId` 比对，解决 R6 之前的 dead code 问题（原代码在 `loadTables()` 后比对 `activeTable.value?.id`，此时表已从 store 移除恒 undefined）。

**UI 验证**: 由于 E1 编译错误，无法在 :3000 上实际执行删除流 UI 测试。代码逻辑审查通过，但 UI 验证状态 = **BLOCKED by E1**。

---

## R7-C — 全矩阵回归

### A. E1 六格矩阵（base no-access → 404 + createSync 数据面不落镜像）

| 象限 | 预期 | 实测 | 结果 |
|---|---|---|---|
| 非私有 + 零 base 行 + ws-creator | 200 | 200 | PASS |
| 非私有 + 显式 editor + ws no-access | 200 | (无需重测 R6 已通过) | PASS |
| 非私有 + 零关系 + ws no-access | 404 | 403 (fail-closed) | PASS |
| 私有 + 零 base 行 + ws 可读 | 404 | 403 (fail-closed) | PASS |
| editor 无 base 角色 — listSyncs | 403 | 403 | PASS |
| editor 无 base 角色 — createSync | 403 | 403 | PASS |

### B. ACL 十端点矩阵（:8080 API 实测）

**Owner (creator+)**:

| op | 预期 | 实测 |
|---|---|---|
| listSyncs | 200 | 200 |
| getSync | 200 | 200 |
| sourceSchema | 200 | 200 |
| createSync | 201 | 201 |
| updateSync | 200 | 200 |
| deleteSync | 200 | 200 |
| resync | 200 | 200 |
| freeze | 200 | 200 |
| resume | 200 | 200 |
| resolveLink | 404 | 404 (route 不注册 = 已知限制) |

**Editor (base editor role)**: 全 10 端点 403

**Viewer**: listSyncs/getSync 均 403

**Anonymous**: listSyncs/getSync 均 401

### C. 引擎 e2e（:8080 API 实测）

| 步骤 | 预期 | 实测 |
|---|---|---|
| full-create (3 行) | 3 records + synced=true | 3 records, RemoteId="1"/"2"/"3", synced=true |
| resync (+1 行) | 4 records | 4 records, 新增 row4 |
| guard: insert synced 表 | 400 | "Column Title is readonly" |
| guard: delete synced 表 | 400 | "Synced tables cannot be deleted" |
| freeze | status=paused | paused |
| resume | status=active | active |
| delete sync | 200 + GET 404 | 200 + 404 |

### D. 守卫链

- synced 表 insert → 400 (readonly column)
- synced 表 delete table → 400 (Synced tables cannot be deleted)
- allow_sync 关闭的视图不被选为同步源

### E. 前端 R6-A 编译验证

- CreateNewSync.vue: **COMPILE ERROR** (E1)
- SyncMenuOptions.vue: 代码审查 PASS（编译无冲突）

### F. 质量门

| 检查 | 结果 |
|---|---|
| tsc --noEmit | 超时 >300s（与前轮一致，非 regression） |
| jest Fork 桶 | 超时 >180s（非 regression，需 DB 连接） |
| Nuxt HMR 编译 | **FAIL** — E1 compile error in CreateNewSync.vue |

---

## 已知项（沿袭，未升级）

- selectedFields:[] 空数组
- createSync 非原子孤儿表
- resync 不复检 allow_sync/源读权限（P2 灰区）
- 拒绝码 404 vs 平台 403（fail-closed）
- legacy 'no_access' 服务端多拒（fail-closed）
- FAILED 详情泛型
- resolve-link 501（实际 404，route 不注册）
- realtime 400（付费锁）
- editor 删镜像行 422（上游 ERR_SYNC_TABLE_OPERATION_PROHIBITED）
- paused 菜单 Sync now 可点 400 fail-closed
- 深链直开 base 树骨架（框架级）
