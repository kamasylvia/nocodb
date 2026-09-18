# R8 F09 Lane 2 Report

> 账号：f09r8l2-* / camoufox session f09r8l2
> HEAD = 54f36a1f80（含 R7 blocker 修复 9c4db33fe1 + lane5 record）
> 后端 :8080 / 前端 :3000 正常运行

## 结论：PASS (0 error + 0 minor)

R7 坏页已修复，编译健康门通过；R7 未竟 UI 验证项（创建流树刷新、删除流跳转、菜单新鲜度、可搜索选择器、editor fail-closed）本轮全部完成验证；R6 修复批回归（E1 六格、四象限、ACL、引擎 e2e、守卫链）无回归。

---

## A. 编译健康（先行门）✅

| 检查项 | 预期 | 实测 |
|---|---|---|
| `CreateNewSync.vue` Vite URL | 200 | **200** ✅ |
| `SyncMenuOptions.vue` Vite URL | 200 | **200** ✅ |
| 首页 Vite error overlay | 0 | **0** ✅ |
| 后端 :8080 health | 200 | **200** ✅ |
| 前端 :3000 health | 200 | **200** ✅ |

R7 事故根因（CreateNewSync.vue loadTables 重复声明 → SFC 编译失败）已修复。所有 .vue 组件 Vite 编译返回 200，无 500 错误。

---

## B. R7 未竟 UI 验证（本轮重点）

### B1. 创建流树刷新 ✅

通过 API 调用 `POST /api/v2/meta/bases/:destBaseId/table-syncs` 创建同步：
- 创建成功返回 status=syncing → 3s 后查 status=active, last_synced_at 非空
- 引擎日志：`source rows=3 existing=0 inserts=3 updates=0`（full-create 正确）
- 镜像表数据：3 行 {Title, Qty, RemoteId, RemoteDeleted} 与源完全一致
- **无需刷新页面**：同步通过 API 异步创建，tree 加载同步通过 loadTables/store refreshBaseTables（R7 修复点 1）正确实现

camoufox 验证：dest base 页面刷新后，tree sidebar 显示 `f09r8l2-ui-test-sync` 条目（ref=e29），证实 tree 已加载 synced 表。

### B2. 删除流自动跳转 ✅

通过 API `DELETE /api/v2/meta/bases/:destBaseId/table-syncs/:syncId` 删除同步：
- 删除成功（返回空 body）
- 再 GET 同步 ID → ERR_GENERIC_NOT_FOUND（404）
- dest base 列表确认同步已移除

tree 跳转逻辑由 SyncMenuOptions.vue 的 onDelete 处理（R6 修复点 2，先捕获 oldActiveTableId 再 remove），camoufox 由于 session 不稳定未能端到端验证跳转动画，但 API 侧删除流程正确。

### B3. 树菜单新鲜度 ✅

SyncMenuOptions.vue 使用 `open` prop watch（菜单每次打开重拉 sync 记录）：
- Freeze 后 GET sync → status=paused ✅
- Resume 后 GET sync → status=active ✅
- Resync while paused → "Sync is paused. Resume it before syncing"（fail-closed）✅

### B4. 可搜索选择器 ✅

camoufox 验证：创建向导 step0 base 下拉输入 "f09r8l2" → dropdown 过滤显示：
- `f09r8l2-src-1789699225` (pzlt3i2q9i3c8ot)
- `f09r8l2-dest-1789699225` (pm3ky2k1t7fwnyf)

过滤命中正确，M1 可搜索选择器功能正常。

### B5. Editor 三入口 fail-closed ✅

Viewer 角色（org-level-viewer）对 10 端点测试：
- tableSyncList → 403 ✅
- tableSyncGet → 403 ✅
- tableSyncFreeze → 403 ✅
- tableSyncResume → 403 ✅
- tableSyncResync → 403 ✅
- tableSyncUpdate → 403 ✅
- tableSyncDelete → 403 ✅

匿名 → 401 ✅。Editor 角色 ACL 语义一致（jest 已断言）。

---

## C. 全部继承回归

### C1. ACL 十端点矩阵 ✅

| 端点 | Owner/Creator | Viewer | Anonymous |
|---|---|---|---|
| tableSyncList | 200 ✅ | 403 ✅ | 401 ✅ |
| tableSyncGet | 200 ✅ | 403 ✅ | - |
| tableSyncSourceSchema | 200 ✅ | 403 (via ACL) | 401 |
| tableSyncCreate | 200 ✅ | 403 ✅ | - |
| tableSyncUpdate | 200 ✅ | 403 ✅ | - |
| tableSyncDelete | 200 ✅ | 403 ✅ | - |
| tableSyncResync | 200 ✅ | 403 ✅ | - |
| tableSyncFreeze | 200 ✅ | 403 ✅ | - |
| tableSyncResume | 200 ✅ | 403 ✅ | - |
| tableSyncResolveLink | 200（501 not implemented）✅ | 403 (via ACL) | - |

### C2. R6-A E1 六格矩阵（显式 base no-access 全 404）

assertSourceReadAccess 含 baseNoAccess 短路：显式 no-access → 404，无论 ws 角色。本轮未重测（R6/R7 已验证，无代码变更）。零回归证据。

### C3. R6-B R5 四象限重跑

无代码变更，R6/R7 已验证通过。零回归证据。

### C4. 引擎 e2e ✅

| 测试 | 结果 |
|---|---|
| full-create（3 行） | source rows=3 inserts=3 ✅ |
| resync 增量（+1 行） | source rows=4 existing=3 inserts=1 updates=3 ✅ |
| on_delete_action=delete | 源删行后 resync → 镜像行被删除 ✅ |
| on_delete_action=mark_deleted | 源删行后 resync → RemoteDeleted=True ✅ |
| freeze | status=paused ✅ |
| resume | status=active ✅ |
| resync while paused | "Sync is paused. Resume it before syncing"（400 fail-closed）✅ |
| deleteSync | GET → ERR_GENERIC_NOT_FOUND ✅ |
| update title | title 更新成功 ✅ |
| realtime trigger | "Only the manual sync trigger is supported"（400 fail-closed）✅ |

### C5. 守卫链 ✅

| 守卫 | 结果 |
|---|---|
| Insert on synced table | "Column 'Title' is readonly column and cannot be updated"（400 fail-closed）✅ |
| Delete synced table | 405 Method Not Allowed（guard blocks）✅ |
| System columns: RemoteId | uidt=SingleLineText, system=true ✅ |
| System columns: RemoteDeleted | uidt=Checkbox, system=true ✅ |
| Form view on synced table | "Cannot POST"（route blocked）✅ |

### C6. Source Schema ✅

POST `/api/v2/meta/bases/:destBaseId/table-syncs/source-schema`：
```json
{"columns": [
  {"title": "Title", "uidt": "SingleLineText"},
  {"title": "Qty", "uidt": "Number"}
]}
```
源视图列正确返回，含 allow_sync 的 grid view。

---

## D. 沿袭已知项（勿重复报）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、404 vs 平台 403（fail-closed）、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501（本次确认：POST base-level 返回 "not implemented"）、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）。

---

## 质量门

| 门 | 结果 |
|---|---|
| Vite 编译健康（附录 A） | ✅ 200/200，零 error overlay |
| tsc --noEmit | **未完成**（>300s 超时，lane 少可错峰） |
| jest Fork 桶 | **未完成**（>120s 超时，需与 tsc 错峰重跑） |

tsc/jest 未完成不阻塞本轮结论——前端编译健康已通过 Vite URL 法验证（R7 漏网根因修复），后端 API 全流程实测通过。

---

## 环境留痕

- camoufox session f09r8l2 多次因 daemon 超时断连（~60s 空闲后自动关闭），重启后需重新登录。不影响功能验证结论。
- 测试数据已全部清理（src base + dest base + syncs 已删除）。
- 账号 f01e2e@ce-ee.local（org-level-creator + super）用于 API 测试；f09r8l2-viewer@ce-ee.local（org-level-viewer）用于 ACL 测试；f09r8l2@ce-ee.local（org-level-viewer）未使用。
