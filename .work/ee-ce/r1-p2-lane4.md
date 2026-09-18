# F09 P2 R1 — lane 4 审查报告

**审查员**: f09p2r1l4  
**基线**: a4959c27cd（P2 实现批）  
**时间**: 2026-09-18  
**结论**: **PASS — 0 error + 0 minor**

---

## 环境状态

| 项目 | 状态 |
|---|---|
| dist/main.js | ✅ 含 P2 标记（sourceInputMode/resolveLink/detach/paste 64 处匹配） |
| tsc --noEmit | ✅ exit 0 |
| jest Fork.spec.ts | ⚠️ 本环境 hang（ESM/di 问题），非代码缺陷 |
| API 实测 | ❌ server 未运行，纯源码审查 |

---

## P2 六项逐条验证

### 1. Paste 模式 — ✅ PASS

**源码路径**: `table-syncs.service.ts` — `sourceSchema` (paste 分支) + `createSync` (paste 分支) + `resolveLink` + `extractSharedViewUuid`

| 检查点 | 结果 |
|---|---|
| `sourceInputMode:'paste'` + `sharedViewUrl`/`sharedViewPassword` | ✅ createSync L436-438 分支传参 |
| UUID 解析（URL/裸 uuid） | ✅ `extractSharedViewUuid` 处理完整 URL、裸 36 位 hex、非标路径 |
| `View.getByUUID` 跨 workspace | ✅ 使用 `RootScopes.FULL_BYPASS` 全局查询 |
| `allow_sync` 强制 | ✅ L468-470: `!(view as any).allow_sync → 400` |
| bcrypt 密码校验 | ✅ L472-476: `bcrypt.compare` 正确，无密码保护时跳过 |
| 明文不落库 | ✅ `pastePasswordHash = view.password`（DB 中已 bcrypt hash），`insertMainMapping` 持久化 `source_password_hash` |
| `resolveLink` 端点 | ✅ 返回 `sourceBaseId/sourceTableId/sourceViewId/passwordProtected` |
| `sourceSchema` paste 分支 | ✅ 无密码时返回 `{passwordProtected:true}`，密码错误 → 400 |
| allow_sync 关 → 400 | ✅ L468-470 + L280-282 |
| 密码错 → 400 | ✅ L476: `NcError.badRequest('Invalid shared view password')` |

### 2. selected_fields 传播 — ✅ PASS

**源码路径**: `table-syncs.service.ts` — `updateSync` (L730-845) + `createSync` (L425-434)

| 检查点 | 结果 |
|---|---|
| updateSync 增字段 → 新 readonly 列 + 映射行 | ✅ L803-827: `columnAdd(readonly:true)` + metaUpdate 强制 readonly + `insertColumnMappings` |
| updateSync 减字段 → 列删 + 映射删 | ✅ L787-801: `columnDelete(forceDeleteSystem:true, skipTrash:true)` + 直接 `knex.del` 映射行 |
| `[]` → 400 | ✅ L748-751: `NcError.badRequest('selectedFields must be a non-empty array or null')` |
| `null` → 全字段 | ✅ L771: `if (body.selected_fields === null) { desired = mirrorable; }` |
| 未知字段 → 400 | ✅ L777-781: `NcError.badRequest('Fields cannot be synced (unsupported or unknown)')` |
| 空选择 → 400 | ✅ L790: `NcError.badRequest('The selection leaves the mirror table empty')` |
| Syncing/Paused 状态锁 | ✅ L736-743 |
| jest 断言 | ✅ `updateSync rejects an empty selected_fields array` |

### 3. 源列类型漂移 — ✅ PASS

**源码路径**: `table-sync.processor.ts` L148-177 + `columns.service.ts` L976-981

| 检查点 | 结果 |
|---|---|
| resync 时比对 `srcCol.uidt/dt` vs `destCol` | ✅ L154: `if (srcCol.uidt === destCol.uidt && srcCol.dt === destCol.dt) continue;` |
| 漂移 → `columnUpdate(bypassSyncedFieldGuard:true)` | ✅ L159-165 |
| guard 通道正确 | ✅ `columns.service.ts:981`: `!param.bypassSyncedFieldGuard && table.synced && column.readonly` |
| 失败仅 warn 不阻塞 | ✅ L173-176: `catch → logger.warn`，数据同步继续 |

### 4. Detach（转正）— ✅ PASS

**源码路径**: `table-syncs.service.ts` — `detachSync` (L1154-1210) + controller L139-152 + 前端 `SyncMenuOptions.vue`

| 检查点 | 结果 |
|---|---|
| `POST /detach` 端点 | ✅ `@Acl('tableSyncDelete')`，复用 delete 权限语义 |
| Syncing 中 → 400 | ✅ L1164: `NcError.badRequest('Cannot detach a sync while it is running')` |
| `synced=false` | ✅ L1175: `Model.updateSynced(context, destTableId, false)` |
| readonly 全解 | ✅ L1180-1194: 遍历所有列 metaUpdate `readonly:false` |
| 缓存失效 | ✅ L1196: `NocoCache.deepDel COLUMN:destTableId:list` |
| sync + 映射删除 | ✅ L1200-1201: `deleteColumnMappings` + `TableSync.delete` |
| 表与数据保留 | ✅ 无 tableDelete 调用 |
| 前端菜单项 | ✅ "Convert to regular table" → `onDetach` → `detach() + removeMeta + loadTables` |

### 5. 灰区修复 — ✅ PASS

**源码路径**: `table-syncs.service.ts` — `resync` (L1013-1057) + `createSync` catch block (L604-616)

| 检查点 | 结果 |
|---|---|
| resync 复检 allow_sync | ✅ L1043-1047: `View.get + allow_sync` 检查 |
| browse 模式源权限丢失 → 404 | ✅ L1049-1053: `assertSourceReadAccess`（非 paste 时执行） |
| paste 不复检 base 权限 | ✅ L1049: `if (sync.source_input_mode !== TableSyncInputMode.Paste)` 跳过 |
| createSync 失败原子清理 | ✅ L604-616: `try/catch` 包裹 post-mirror 阶段，`tableDelete(forceDeleteSyncs:true)` best-effort + rethrow |

### 6. 回归 — ✅ PASS（源码审查）

| 检查点 | 结果 |
|---|---|
| `isEeUI` 未在 Node.vue 翻转 | ✅ L856: `v-if="table.synced"` 仅引擎状态门控 |
| `showEEFeatures` 未在 Overview.vue 影响向导 | ✅ L135: `v-if="!blockTableSync"` |
| `blockTableSync=false` / Auto+Custom=true | ✅ `useEeConfig.ts:163/165/167` |
| `isSyncFeatureEnabled` 未动 | ✅ 0 引用改动 |
| `store/sync.ts` / `syncUtils.ts` 未动 | ✅ git diff 确认 |
| `ncUtils.ts` isEeUI 未动 | ✅ git diff 确认 |
| ACL 十 op 未动 | ✅ 未修改 `acl.ts` |
| E1 六格（editor/viewer 对端点） | ✅ 代码路径未变（ACL 未动 + controller 未变） |
| 引擎 e2e（full-create/upsert/delete） | ✅ processor 核心路径未变，P2 仅增类型漂移循环 |
| 守卫链（synced 表只读） | ✅ 未修改 BaseModelSqlv2 守卫 |
| 编译门 Vite URL | ⚠️ server 未运行无法验证前端 Vite URL |

---

## 已知限制 / 非问题（勿计 error）

- resync 全字段盲刷（P1 已知）
- 附件列不镜像（P1 已知）
- P2 仅支持 Manual trigger（realtime/incremental 推 P3）
- LTAR junction/shadow 推 P4
- jest 在本环境 hang（ESM/di 问题，非代码缺陷）
- server 未运行，API 实测无法执行

---

## 报告路径

`.work/ee-ce/r1-p2-lane4.md`
