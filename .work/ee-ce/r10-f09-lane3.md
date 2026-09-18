沙箱限制无法写入文件。完整报告输出到 stdout，待 orchestrator 落盘。

---

# R10 F09 Lane 3 Report (f09r10l3)

**结论：BLOCKED — 运行时验证全部不可执行，静态审查 0 error / 0 minor**

**HEAD**: 5bea0c3943（代码面同 5e3d736b2a：SyncMenuOptions storeToRefs 修复，无后续代码变更）

---

## 阻塞说明

Host `state mutation` 预算约束持续阻止所有 shell 命令（curl、node、camoufox-cli、tsc、jest）和文件写入。唯一通过的 bash 命令是 `echo`、`ls`、`pwd`、`date`、`git log`、`which`、`wc`、`find`、`read_file`。后果：

- **附录 A.2（Vite URL 编译健康检查）**：无法执行 `curl localhost:3000/_nuxt/components/...`，运行时编译健康不可验证
- **附录 A.1（删除流跳转回归）**：无法启动 camoufox，全部 UI 段不可验证
- **附录 A.3-A.6（ACL 矩阵、引擎 e2e、守卫链、系统列）**：无法执行 `curl localhost:8080/api/v2/...`，API 实测不可验证
- **质量门（tsc/jest）**：无法执行 `pnpm test` / `tsc --noEmit`

---

## 静态审查结果（仅限源码层面）

### A.2 编译健康（静态推断）

**CreateNewSync.vue** (326 行) — 零重复标识符，零 SFC 编译错误风险：
- L21: `const { loadTables: refreshBaseTables } = useBase()` — store 版别名，避免与本地 `loadTables` 重名
- L79: `const loadTables = async (baseId: string) => { ... }` — 向导源表加载器，独立声明
- L141: `await refreshBaseTables()` — 创建后刷新树（store 版）
- L162: `watch(selectedBaseId, (id) => { if (id) loadTables(id) })` — 向导步骤中用本地版
- **静态 PASS。**

**SyncMenuOptions.vue** (189 行) — 无重复声明，`useBase()` 单次解构 L23：
- L30-32: `storeToRefs(tablesStore)` 解构 state refs（`baseTables`、`activeTable`），`tablesStore` 裸解构 action（`openTable`）——与上游 `DlgTableDelete` 模式一致
- **静态 PASS。**

### A.1 删除流自动跳转三腿（静态审查）

**SyncMenuOptions.vue L61-86 (`onDelete`)**：
1. L66: `const oldActiveTableId = activeTable.value?.id` — 先捕获活动表 ID（storeToRefs 修复后正确读取）
2. L67: `await remove()` — 删除 sync 记录
3. L73-74: `removeFromRecentViews` + `removeMeta` — 清理缓存
4. L75: `await loadTables()` — 刷新树
5. L76-85: 跳转逻辑：
   - `oldActiveTableId === props.table.id`（当前打开表被删）
     - `remaining.length > 0` → `openTable(remaining[0])`（跳剩余首表）
     - `remaining.length === 0` → `navigateTo(baseUrl({ id: props.baseId, type: 'database' }))`（跳 base 根）
   - 否则不跳转

**静态 PASS**：逻辑正确，storeToRefs 修复后 `activeTable.value` 不再恒 undefined。

### A.3 创建流树刷新 + 树菜单新鲜度 + 可搜索选择器（静态审查）

**CreateNewSync.vue**：
- L141: `await refreshBaseTables()` — 创建后刷新树（store 版，非旧 useBases().loadTables()）
- L135: `message.success(t('labels.createSyncTable'))` — 单一成功 toast
- L43-51: `filterSelectOption` — 按 label 过滤
- L208-209: `show-search` + `:filter-option="filterSelectOption"` — base 下拉可搜索
- L220-221: 同上 — table 下拉可搜索

**SyncMenuOptions.vue**：
- L40-45: `watch(() => props.open, (isOpen) => { if (isOpen) load() })` — 菜单每次打开重拉 sync 记录
- L92-95: loading 占位行（`!sync && isLoading`）

**静态 PASS**。

### A.4 editor 三入口不可见 + API 403（静态审查）

**ACL 10 端点（controller.ts）**：
1. `tableSyncList` — `@Acl('tableSyncList')`
2. `tableSyncGet` — `@Acl('tableSyncGet')`
3. `tableSyncSourceSchema` — `@Acl('tableSyncSourceSchema')`
4. `tableSyncCreate` — `@Acl('tableSyncCreate')`
5. `tableSyncUpdate` — `@Acl('tableSyncUpdate')`
6. `tableSyncDelete` — `@Acl('tableSyncDelete')`
7. `tableSyncResync` — `@Acl('tableSyncResync')`
8. `tableSyncFreeze` — `@Acl('tableSyncFreeze')`
9. `tableSyncResume` — `@Acl('tableSyncResume')`
10. `tableSyncResolveLink` — `@Acl('tableSyncResolveLink')`

**权限注册（Fork.spec.ts L97-122）**：
- `permissionScopes.base` 包含全部 10 个 tableSync* 操作
- editor 的 `include` 中无 tableSync*（editor 403）
- creator/owner 的 `exclude` 中无 tableSync*（creator+ 200）

**静态 PASS**：editor 三入口不可见（UI gate `blockTableSync`）+ API 403（ACL exclude model）。

### A.5 E1 六格矩阵 + R5 四象限 + 引擎 e2e（静态审查）

**assertSourceReadAccess（service.ts L91-141）**：
- L108-141: 完整镜像平台谓词
- L115-119: `hasExplicitBaseRole` — 排除 no_access/inherit
- L121-122: `baseNoAccess` — 检测显式 no_access
- L124-140: 四路径全覆盖（私有/非私有 × 显式 no-access/inherit/ws-role）
- **E1 六格矩阵静态 PASS**。

**引擎（processor.ts）**：
- L152-227: RemoteId 键控 upsert（分页 500/页）
- L263-288: delete vs mark_deleted 双策略
- L232-238: allowSystemColumn 白名单通道
- L71-81: 错误落 status=error+last_error
- L53-56: paused 跳过
- **引擎 e2e 静态 PASS**。

### A.6 守卫链 + 系统列网格不可见（静态审查）

**系统列（service.ts L44-50）**：
```typescript
export const TABLE_SYNC_SYSTEM_COLUMNS = [
  { title: 'RemoteId', uidt: UITypes.SingleLineText },
  { title: 'RemoteDeleted', uidt: UITypes.Checkbox },
];
```
- L498-517: system:true 后置补丁
- L341-356: 保留名守卫（RemoteId/RemoteDeleted + 系统列）

**静态 PASS**：系统列带 system:true + isHiddenCol 双保险，网格不可见。

---

## 沿袭已知项（未升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、404 vs 平台 403（fail-closed）、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）、source-schema 对无 allow_sync 视图仍 200（create 侧强制，灰区）。

---

## 质量门

| 项目 | 状态 |
|---|---|
| tsc | ⛔ 未执行（bash 被阻塞） |
| jest Fork 桶 | ⛔ 未执行（bash 被阻塞） |
| Vite URL 健康检查 | ⛔ 未执行（bash 被阻塞） |
| camoufox UI 段 | ⛔ 未执行（bash 被阻塞） |
| API 实测 | ⛔ 未执行（bash 被阻塞） |

---

## 结论

**BLOCKED（2 error — 均为不可执行类）**

- E1: 附录 A.2 Vite URL 编译健康检查无法执行（bash loop guard 阻塞 curl/node）
- E2: 附录 A.1-A.6 全部运行时验证无法执行（bash loop guard 阻塞所有网络/进程命令）

**静态审查通过**：源码层面 0 error / 0 minor。storeToRefs 修复（5e3d736b2a）代码逻辑正确，删除流三腿、创建流树刷新、菜单新鲜度、可搜索选择器、editor fail-closed、E1 六格矩阵、引擎 e2e、守卫链、系统列——静态审查全部 PASS。

**建议**：orchestrator 应在 loop guard 解除后对本 lane 补发一次完整运行时验证（重点：附录 A.2 Vite URL + A.1 删除流三腿 + A.4 ACL 矩阵），否则本轮 R10 不能算 PASS。

---

*待 orchestrator 落盘至 `.work/ee-ce/r10-f09-lane3.md`*（沙箱禁写 .work 目录）
