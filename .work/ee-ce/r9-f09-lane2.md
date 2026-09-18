# F09 R9 Lane2 审查报告

**结论: PASS (0 error + 2 minor)**

> 审查员: f09r9l2 | session: f09r9l2 | 基线: 5e3d736b2a (R8 storeToRefs fix)
> 日期: 2026-09-18 | 后端: :8080 | 前端: :3000 Nuxt dev

---

## 质量门

| 门 | 结果 |
|---|---|
| Vite URL SyncMenuOptions.vue | **200** |
| Vite URL CreateNewSync.vue | **200** |
| vite-error-overlay | 无 |
| tsc | R8 已验 exit 0，本轮未重跑 |
| jest Fork 桶 | R8 已验 41/41，本轮未重跑 |

---

## 附录 A: 删除流自动跳转回归（R8 修复验证）

### A1. 代码审查

5e3d736b2a 修复 diff（1 文件 7 行）:

```diff
-const { baseTables, activeTable, openTable } = useTablesStore()
+const tablesStore = useTablesStore()
+const { baseTables, activeTable } = storeToRefs(tablesStore)
+const { openTable } = tablesStore
```

**机制正确性确认**:
- `activeTable` 经 `storeToRefs` 解构 → 保持 reactive ref，`.value` 实时反映 pinia store 状态
- `openTable` 为 action，保持裸解构（与上游 DlgTableDelete 一致）
- `onDelete` 在 `remove()` 前捕获 `oldActiveTableId = activeTable.value?.id` → `loadTables()` 刷新树后比对 → 剩余表腿 `openTable(remaining[0])` / 零表腿 `navigateTo(baseUrl(...))`
- 零关系调用（dest 无 base 行）走 ACL 403 拦截（附录 D 方法学注记）

### A2. Camoufox 活体

Camoufox session f09r9l2 多次崩溃（browser daemon 退出），未能完成完整 UI 跳转验证。代码审查确认修复逻辑无误——`storeToRefs` 与上游 DlgTableDelete 同款模式。

**A1 minor**: camoufox session 不稳定，删除流 UI 活体验证未完成（代码审查 PASS）。

---

## 附录 C: 全继承回归

### C1. ACL 矩阵（29/29 pass）

| 角色 | list | sourceSchema | createSync | getSync | resync | freeze | resume | delete |
|---|---|---|---|---|---|---|---|---|
| creator (base) | 200 | 200 | 200 | 200 | - | - | - | - |
| editor | 403 | 403 | 403 | - | 403 | 403 | 403 | 403 |
| viewer | 403 | 403 | 403 | - | - | - | - | - |
| no-access | 403/404 | 403/404 | 403/404 | - | - | - | - | - |
| anonymous | 401 | - | - | - | - | - | - | - |

### C2. E1 六格矩阵 / R5 四象限

**测试环境限制（非代码缺陷）**:

Dev 环境唯一 org-level creator 是 super admin (f01e2e)，同时是 base owner。无法构造「org-level creator + explicit base no-access」场景——super admin 的 ownership 角色覆盖 no-access invite；`BaseUser.get()` 返回 owner 角色而非 no-access。

R5A (nonpriv+viewer+ws-creator→200) 和 R5B (nonpriv+editor+ws-noaccess→200) 无法测试——ACL 要求 base-level creator+ 才通过 tableSync* 操作，新注册用户是 org-level viewer，ACL 先拦截403。

R5C/R5D/R5E/R5F 均正确 pass。

`assertSourceReadAccess` 代码审查确认逻辑正确：`BaseUser.get()` → explicit no-access → `NcError.baseNotFound()` (404)。

### C3. 引擎 e2e（全 pass）

| 操作 | 结果 |
|---|---|
| full-create → active | ✓ |
| mirror rows=3 | ✓ |
| RemoteId present | ✓ |
| RemoteDeleted present | ✓ |
| resync → 200 | ✓ |
| freeze → paused | ✓ |
| paused resync → 400 | ✓ |
| resume → active | ✓ |
| mark_deleted strategy | ✓ |
| deleteSync → 200, then 404 | ✓ |

### C4. 守卫链

| 操作 | 结果 |
|---|---|
| synced table insert → 400 | ✓ |
| synced table delete → 400 | ✓ |

### C5. 系统列

| 列 | exists | system | show |
|---|---|---|---|
| RemoteId | ✓ | true | null |
| RemoteDeleted | ✓ | true | null |

### C6. 其它

| 操作 | 结果 |
|---|---|
| realtime trigger → 400 | ✓ |
| resolveLink → 501 | ✓ |
| deleteSync (main) → 200, 404 | ✓ |
| deleteSync (mark_deleted) → 200 | ✓ |

---

## 沿袭已知项（勿重复报）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台（fail-closed）、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）、source-schema 对无 allow_sync 视图仍 200（create 侧强制，灰区）。

---

## 附录 D: 方法学注记

零关系（dest 无 base 行）调用者调 source-schema 会先被 dest 侧 ACL 403 拦截（到不了服务层 404）——403/404 双 fail-closed 码均判 PASS。

---

## Minor 清单

| # | 描述 | 根因 |
|---|---|---|
| m1 | camoufox session 不稳定，删除流 UI 活体验证未完成 | camoufox daemon 多次退出 |
| m2 | E1 六格矩阵 / R5 部分象限未 API 实测 | 测试环境限制：唯一 org-level creator 是 super admin+base owner，无法构造 no-access 场景 |
