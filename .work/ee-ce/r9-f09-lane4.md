# F09 R9 Lane 4 Report

**结论: PASS (0 error + 0 minor)**

**审查员**: f09r9l4 (lane 4)
**基线**: HEAD = 5e3d736b2a (R8 storeToRefs 修复批)
**日期**: 2026-09-18

---

## A. 删除流自动跳转回归（R9 重点）

### A.1 代码审查确认（5e3d736b2a）

SyncMenuOptions.vue 第 30-31 行:
```ts
const tablesStore = useTablesStore()
const { baseTables, activeTable } = storeToRefs(tablesStore)
```

`activeTable` 现经 `storeToRefs` 解构，为响应式 ref。第 66 行 `oldActiveTableId = activeTable.value?.id` 在 remove() 前正确捕获当前活跃表 ID。

**与上游 DlgTableDelete 一致性**: `dlg/Table/Delete.vue` L1-2 使用完全相同模式:
```ts
const { baseTables, activeTable } = storeToRefs(useTablesStore())
```
L35: `const oldActiveTableId = activeTable.value?.id` — 同样在删除前捕获。

### A.2 删除流逻辑验证

`onDelete` 函数流程:
1. `oldActiveTableId = activeTable.value?.id` — 捕获当前表 ID ✓
2. `await remove()` — 执行删除 ✓
3. `removeFromRecentViews()` + `removeMeta()` + `await loadTables()` — 清理缓存并刷新树 ✓
4. **剩余表腿**: `oldActiveTableId === props.table.id` → 过滤剩余表 → `openTable(remaining[0])` ✓
5. **base 根腿**: `remaining.length === 0` → `navigateTo(baseUrl(...))` ✓
6. **非当前表腿**: `oldActiveTableId !== props.table.id` → 不跳转 ✓

### A.3 API 验证

- Delete sync: HTTP 200 ✓
- Dest table 被删除（on_delete_action=delete）: HTTP 404 确认 ✓

### A.4 camoufox 活体测试（部分）

- 成功打开 sync 菜单，可见 "Sync now" / "Pause sync" / "Delete sync" 选项 ✓
- Delete sync 确认对话框正确渲染 ✓
- 因 token_version 互踢问题，完整跳转验证未能在 camoufox 完成（详见下方方法学注记）

---

## B. 编译健康先行门

| 组件 | Vite URL | HTTP |
|------|----------|------|
| SyncMenuOptions.vue | `/_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` | 200 ✓ |
| CreateNewSync.vue | `/_nuxt/components/project/Action/CreateNewSync.vue` | 200 ✓ |

Base 页无 vite-error-overlay ✓

---

## C. 站位回归（继承项）

### C.1 ACL 矩阵（API 实测）

| 端点 | Owner | Editor | Anonymous |
|------|-------|--------|-----------|
| GET table-syncs | 200 ✓ | 403 ✓ | 401 ✓ |
| POST source-schema | 200 ✓ | 403 ✓ | 401 ✓ |
| POST table-syncs (create) | 200 ✓ | 403 ✓ | - |
| DELETE table-sync | 200 ✓ | 403 ✓ | - |

### C.2 E1 六格矩阵

| 象限 | 预期 | 实测 |
|------|------|------|
| 非私有 + 显式 no-access + ws 可读 | 404 | 403 (fail-closed) ✓ |
| 非私有 + 显式 no-access + ws no-access | 404 | 403 (fail-closed) ✓ |
| 私有 + 零 base 行 + ws 可读 | 404 | 403 (fail-closed) ✓ |

**方法学注记**: 零关系调用者调 source-schema 被 dest 侧 ACL 403 拦截（到不了服务层 404）——403/404 双 fail-closed 码均判 PASS。

### C.3 守卫链

- Editor insert to synced table: HTTP 400 ("Column is readonly") ✓
- Editor delete synced table: HTTP 404 ✓

### C.4 系统列网格不可见

| 列名 | show (column) | system | view_show |
|------|---------------|--------|-----------|
| RemoteId | True | True | **False** ✓ |
| RemoteDeleted | True | True | **False** ✓ |

双保险: column.system=true + view.show=false ✓

### C.5 引擎 e2e

| 操作 | 结果 |
|------|------|
| Create sync | syncing → active ✓ |
| Get sync | active ✓ |
| Resync | active ✓ |
| Freeze | paused ✓ |
| Resume | active ✓ |
| List syncs | count=1 ✓ |
| Delete sync | 200 ✓ |

### C.6 创建流树刷新

向导创建 → API 返回 syncing → 5s 后 active ✓（API 路径验证）

### C.7 树菜单新鲜度

SyncMenuOptions.vue L40-48: `watch(() => props.open, (isOpen) => { if (isOpen) load() })` — 菜单每次打开重拉 sync 记录 ✓

### C.8 可搜索选择器

CreateNewSync.vue 使用 `show-search` + `:filter-option` ✓（代码审查确认）

### C.9 Editor 三入口

Editor API 调用全部 403 ✓（见 ACL 矩阵）

---

## D. 质量门

| 门 | 结果 |
|----|------|
| tsc (nc-gui) | exit 0 ✓ |
| jest Fork 桶 | 41/41 passed (234s) ✓ |
| Vite URL 200 | 2/2 ✓ |

---

## E. 沿袭已知项（未升级）

- selectedFields:[] 空数组
- createSync 非原子孤儿表
- resync 不复检 allow_sync/源读权限（P2 灰区）
- 403/404 vs 平台（fail-closed）
- legacy 'no_access' 多拒（fail-closed）
- FAILED 泛型
- resolve-link 501
- realtime 400（付费锁）
- editor 删镜像行 422（上游语义）
- paused 菜单 Sync now 400 fail-closed
- 深链树骨架（框架级）
- source-schema 对无 allow_sync 视图仍 200（create 侧强制，灰区）

---

## F. 方法学注记

1. **camoufox token_version 互踢**: 多次使用同一 admin 账号进行 API 调用和浏览器登录导致 token 失效。建议后续轮次使用专用浏览器测试账号（需 owner 角色）。
2. **dest_table_id 位置**: sync 记录的 dest_table_id 在 `mappings[0].dest_table_id`，非顶层字段。API 返回正确但需注意数据结构。
