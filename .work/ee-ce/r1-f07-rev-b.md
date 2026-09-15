# R1 F07 前端复审报告（第 4 路 rev-b）

范围：`git diff packages/nc-gui`（Snapshots.vue / useEeConfig.ts / View.vue / BaseSettingsMenu.vue / lib/acl.ts / lang en+zh-Hans）。

## issues

1. **P1** `packages/nc-gui/components/dashboard/settings/base/Snapshots.vue:57`：restore 成功后 `navigateTo(`/${restoredBaseId}`)` 是**单段路由 = workspace 路由**（`pages/index/[typeOrId]/index.vue` → WorkspaceBaseList），不是 base 路由；以 baseId 当 workspace id 查询必失败，用户 restore 后不会被带到新 base。仓内惯例均为双段：`/{wsId}/{baseId}`（`components/admin/InstanceBases.vue:73`）、快照深链 `/{wsId}/{baseId}/settings/snapshots`（`components/smartsheet/topbar/History.vue:52`）、`useWsBaseListActions.ts:105`。建议改为 `` navigateTo(`/${route.params.typeOrId}/${restoredBaseId}`) ``（组件正处 base settings 路由，typeOrId 即 wsId）。

2. **P2** `Snapshots.vue:36-40`：create 轮询逻辑缺陷（UX 判定：**不充分**）。① break 条件 `snapshots.value.some((s) => s.status === 'completed')` 检查的是**任意**快照而非本次新建——base 里只要有一条历史 completed 快照，首轮 1.5s 后即 break，后续轮询形同虚设；应使用 POST 响应中返回的新快照 id（后端 `BaseSnapshot.insert` 返回整行）做定点轮询。② 3 次×1.5s = 4.5s 窗口，job 实际 10-40s（duplicate.service.ts 异步 `jobsService.add`），页面内 status 永远停在 processing，且无任何手动刷新入口（仅 onMounted / delete 后重载），用户无法在本页看到创建完成。③ 每次 `loadSnapshots` 置 `isLoading=true`，轮询期间列表区域被 `<GeneralLoader>` 整体替换、闪烁 1-3 次；轮询重载不应走 isLoading。建议：定点轮询新 id + 窗口拉长（如 40s / 退避）或补刷新按钮 + 轮询不置 isLoading。行可见性本身 OK（服务端 insert 立即返回 processing 行，1.5s 后新行即出现）。

3. **P3** `packages/nc-gui/components/dashboard/TreeView/Project/BaseSettingsMenu.vue:263`：菜单门多一层 `isUIAllowed('baseMiscSettings', { roles: effectiveRoles })`，与 tab（View.vue:642）/深链 watch（View.vue:195）及 F05 菜单模式（`:245` 仅 `!blockBaseVariables && isUIAllowed('baseVariableList')`）不一致。当前 baseMiscSettings 与 baseSnapshotList 同在 creator-only 块（`lib/acl.ts:117` vs `:143`），行为等价；但两权限未来分化时菜单会隐藏而 tab 仍可达。建议删去 baseMiscSettings 层，保持三门全等。

4. **P3** `Snapshots.vue:48-62`：restore 立即 navigate 时序缺口。后端 restore 内部 `duplicateBase` 为异步 job（`duplicate.service.ts` 队列后立即返回 `base_id`），新 base 处于 status='job' 中间态；nc-gui 全仓无 ProjectStatus/job 态处理（grep `ProjectStatus` 零命中），立即跳转可能加载半成品 base（sources 尚未复制完）。与 issue 1 叠加放大。建议 restore 后轮询新 base 就绪（或按后端路裁决改后端同步等待）再跳转，并保留提示文案与实际时序一致（"已恢复为新 Base" 在 job 完成前即弹出）。

## 通过项（无问题）

- **API 契约**：GET/POST `/api/v2/meta/bases/:baseId/snapshots`、POST `…/:id/restore`、DELETE `…/:id` 与 `base-snapshots.controller.ts` 五路由逐一对齐；list 返回数组（`res.data ?? []` 对）、restore 返回 `{base_id}` 对、create/delete 返回值忽略合规。SDK 无 snapshot 类型化 REST 方法（仅 `SnapshotType`，Api.ts:7940），`$api.instance` 裸调为唯一途径，仓内 7 文件同款。
- **auto-import**：`message`/`Modal` 经 nuxt.config.ts:404-405 显式导入；`extractSdkResponseErrorMsg`（utils/errorUtils.ts，utils 自动导入，仓内大量同款）；`useNuxtApp`/`storeToRefs`/`navigateTo`/`onMounted` Nuxt 内建；`storeToRefs(useBases())` + `openedProject?.id` 与 F05 `Variables/index.vue:8,24` 逐行同款。
- **三门终核**：menu（BaseSettingsMenu.vue:262-265，除 issue 3 外层）/tab（View.vue:642）/深链 watch（View.vue:195）均为 `!blockSnapshots && isUIAllowed('baseSnapshotList')`；`blockSnapshots` 于 useEeConfig.ts:427 定义、:660 导出；`isUIAllowed` 于 View.vue:62、BaseSettingsMenu.vue:19 经 `useRoles()` 解构。深链链路全通：`settings/snapshots` → settingsRouteUtils slug 映射（'snapshots':'snapshots' 双向）→ `[page].vue` → ProjectView tab='snapshots' → watch 命中 → pane 渲染 `<DashboardSettingsBaseSnapshots/>`；门不过落 collaborator，合理。showUpgradeToUseSnapshots 现为 no-op stub，blockSnapshots=false 下死分支，无害。
- **i18n**：组件引用 10 键 + tab 标题 `general.snapshots`，en/zh-Hans 经 json.load 逐一验证全存在；`general.restore` 为**存量键**（en "Restore" / zh "还原"），满足"确认存在"；en/zh JSON 解析合法。
- **[CE-EE] 标记**：Snapshots.vue:2、useEeConfig.ts:426、View.vue:195/640、BaseSettingsMenu.vue:34/47-48/261、lib/acl.ts:142 全有；lang JSON 无法注释，与 F05 同惯例（无标记，可接受）。
- **类型**：`SnapshotType`（nocodb-sdk Api.ts:7940）字段 id/title/created_at/status 与模板用法对齐；后端 status 值 'processing'/'completed'/'error' 与 statusColor/disabled 判断对齐（error→红、非 completed 禁 restore，与后端 guard 一致）。
- **data-testid**：`base-snapshots-create` / `base-snapshots-row|status|restore|delete-{id}` / 菜单 `base-snapshots` / tab `proj-view-tab__snapshots` 全齐。
- **删除确认**：Modal.confirm 模式与 F05 Variables/index.vue:105-117 逐行同款（okText/okType:danger/cancelText/async onOk）。
- **实跑测试**：`npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → **2 files, 10/10 passed**。

## 裁决

非 PASS。4 issues：P1×1（restore 跳转路由错误，必修）、P2×1（create 轮询逻辑+UX）、P3×2（菜单门冗余层、restore 异步时序）。
