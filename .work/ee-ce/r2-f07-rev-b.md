# r2-f07-rev-b — F07 前端代码复审(第 4 路,第 2 轮)

## PASS

### 核查证据

**1. Snapshots.vue 轮询新逻辑**(`packages/nc-gui/components/dashboard/settings/base/Snapshots.vue:40-53`)
- 按 id 定点轮询:POST create 取 `res.data.id` → 循环 24 次 × sleep 2500ms(窗口 60s)→ GET `/api/v2/meta/bases/{baseId}/snapshots/{newId}` ✓
- list 更新:`idx===-1 → unshift`(新项置顶),否则 `list[idx]=one.data`(原地更新),响应式数组 proxy 引用,渲染正确 ✓
- 终止:`status === 'completed' || 'error' → break` ✓;超窗(仍 processing)自然退出,isCreating 复位,UI 留 processing 态(10-40s job vs 60s 窗口,充足)✓
- 轮询 GET 失败落入外层 catch → error 提示 + finally 复位 ✓
- 后端 GET by-id 端点存在(`src/controllers/base-snapshots.controller.ts:49-60`),且其 `@Acl('baseSnapshotList')`(:54)与 tab 门 `isUIAllowed('baseSnapshotList')` 同名——轮询不会因 ACL 差异 403 ✓

**2. route 使用残留**
- Snapshots.vue 全文无 `useRoute`/`useRouter`/`route` 引用,R1 清理无残留,无未用引用 ✓

**3. restore 跳转一致性**
- `navigateTo('/nc/{restoredBaseId}')`(Snapshots.vue:71)与上游项目内跳转惯例一致:`store/bases.ts:348` navigateToProject 用 `path: /nc/${baseId}` 纯相对路径;`store/base.ts:281` 同款。`getBaseUrl`(useGlobal/actions.ts:197)仅在子域部署(baseHostName)返回外部 host,上游所有项目内跳转均不经过它——fork 行为与上游一致 ✓
- restore 响应体匹配:后端 `src/services/base-snapshots.service.ts:155` `return { base_id: restoredBaseId }` ↔ 前端 `res.data?.base_id`(Snapshots.vue:68)✓

**4. 三门终核**
- 门① paywall:`composables/useEeConfig.ts:427` `blockSnapshots = computed(() => false)`(带 [CE-EE] 标记)✓
- 门② tab:`components/project/View.vue:195` watch 门 `snapshots' && !blockSnapshots.value && isUIAllowed('baseSnapshotList')`;`:642` tab-pane 门同款(上游为 `baseMiscSettings + manageSnapshot + showEEFeatures`,已替换)✓
- 门③ 菜单:`components/dashboard/TreeView/Project/BaseSettingsMenu.vue:260-263` `!blockSnapshots && isUIAllowed('baseSnapshotList',{roles:effectiveRoles}) && !isMobileMode`——上游门(git d733cb71cb: `isEeUI && showEEFeatures && baseMiscSettings && manageSnapshot`)的 baseMiscSettings 已移除,R1 修复在位 ✓;`navigateToBaseSettings` 内 snapshots 守卫(:50-51)经 blockSnapshots=false 放行 ✓
- base/settings/index.vue allTabs 含 'snapshots' 但无菜单/渲染:与 upstream 同 commit(d733cb71cb)逐字一致,系上游遗留死代码,非 fork 引入,不计

**5. ACL/权限面一致性**
- 后端 controller:@Acl baseSnapshotCreate(:29)/ baseSnapshotList(:41,:54)/ baseSnapshotRestore(:68)/ baseSnapshotDelete(:87);前端门用 baseSnapshotList 同名 ✓

**6. i18n 终核**(`packages/nc-gui/lang/en.json`)
- 10 个新增 key 全在:labels.manageSnapshots / msg.info.baseSnapshotsSubtitle / baseSnapshotCreate / baseSnapshotsEmpty / msg.success.baseSnapshotCreated / baseSnapshotRestored / baseSnapshotDeleted / msg.info.baseSnapshotDeleteTitle / baseSnapshotDeleteDescription(含 `{title}` 插值参数,与代码传参匹配)/ baseSnapshotsRestoreHint ✓
- 4 个 general key(snapshots/restore/delete/cancel)上游既有 ✓

**7. 标记与类型**
- [CE-EE] 标记齐全:Snapshots.vue:2/:33/:70、useEeConfig.ts:426、View.vue:195/:641、BaseSettingsMenu.vue:34/:50/:262 ✓
- `import type { SnapshotType }`(type-only,nocodb-sdk Api.ts:7940 导出);前端用到的 id/title/created_at/status 字段均在类型定义中 ✓
- `extractSdkResponseErrorMsg` 为 auto-import(全仓 settings 组件同款无 import 用法)✓

**8. vitest 实跑**
```
npx vitest run --config test/vite.config.ts test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts
✓ test/base-variables-acl.test.ts (2 tests)
✓ test/unique-constraint-helpers.test.ts (8 tests)
Test Files 2 passed (2) / Tests 10 passed (10)
```

### 找茬
无 error 级问题。观察项(不计,均有 F05 已 pass 先例或极端防御范畴):restore 按钮无独立 baseSnapshotRestore 前端权限门(点击 403 有 error 提示兜底);`okType: 'danger'` 与 F05 Variables/index.vue:109 同款惯例;轮询 GET 返回空体时 `one.data` 无 undefined 防御(axios 2xx 正常有 body,极端场景)。
