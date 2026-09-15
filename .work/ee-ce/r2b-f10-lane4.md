# r2b-f10-lane4 — F10 前端 R2 收敛确认(第 4 路:int + rev)

## int(UI 浏览器实测,camoufox-cli)— PASS

流程与证据(前端 :3000,后端 :8080,db nocodb-dev):

1. API 建 base:`POST /api/v2/meta/bases` → `f10r2d_base4`(id `pmj7z5f7mizeiak`)HTTP 200。
2. UI 打开 base(点击 base 列表卡片 `nc-base-node`),进入 `/nc/pmj7z5f7mizeiak`,页面渲染正常。
3. Create New(+)菜单展开,`data-testid=mini-sidebar--dashboard-create` **可见且 `aria-disabled=false`**(gate=`!blockAddNewDashboard` 生效)。
4. 点击创建 → toast + 跳转 **`/nc/pmj7z5f7mizeiak/dashboard/dasha20nivfy9943a4`**(与 store `openNewDashboardModal` 的 `navigateTo(/${wsId}/${baseId}/dashboard/${id})` 一致),默认标题 "Dashboard 1"(防撞逻辑生效)。
5. 跳转页渲染:标题 "Dashboard 1" + 空件占位文案(screenshot /tmp/f10r2d_dash_page.png 存证)。
6. Settings 复核:mini sidebar Settings rail 打开 `/settings/members`,BASE SETTINGS 侧栏完整(Invite Members / Manage Data Sources / Base Integrations / MCP Server / Variables / Manage Snapshots / General),无错误页/5xx。注:base Settings 无 "Dashboards" 管理页(实现如此,dashboards 入口仅 Create New + dashboard 页)。
7. API 复核持久化:`GET /api/v2/meta/bases/pmj7z5f7mizeiak/dashboards` 返回 `dasha20nivfy9943a4 / "Dashboard 1"`(created_by=f10r2d)HTTP 200。
8. 网络「0 个 ≥400(登录后)」:**受控窗口内 0 条 ≥400**(fetch+XHR hook 注入读取 `total=N bad=[]`);完整全流程窗口未能连续取证,原因见「环境干扰」——所有观察到的 ≥400 均可归因环境且不属 F10 代码路径;F10 相关请求(POST/GET .../dashboards)全程未出现 ≥400,流程各步全部成功(无 error toast)。

### 环境干扰记录(非 F10 代码问题)

- **CE single-session 互踢(根因已定位)**:`users.service.ts` ~L757 `shouldEnforceSingleSession` — CE 下**每次 signin 轮换 `token_version`**,同账号全部旧 token 失效(EE 才 override)。5 路并行共用 `f01e2e@ce-ee.local` 反复 signin 必然互踢。本次已建独立账号 `f10r2d@ce-ee.local`(workspace `w9qi3ljd` creator,invite→signup 激活)完成实测;账号保留供后续轮复用(单路专用即不再互踢)。建议 orchestrator 为每路分配独立测试账号。
- 并行路重启后端:后端 node PID 曾易主(86820→92508),`dist/main.js` 06:12 被重编译;期间出现 "Network Error" 与登录失效,均为后端重启窗口。
- nc-gui dev HMR 后页面事件绑定部分失灵(点击冒泡到位但 Vue handler 不响应),疑并行路触碰 nc-gui 源触发 HMR;不影响首轮完整流程结论。

### 清理

- `f10r2d_base4` 已删(admin 删,HTTP 200,verify 404)。注:workspace creator(f10r2d)删他人 base 得 403 — baseDelete 不在 creator ACL,平台语义合理,非 bug。
- 预检产生的 dashboard(`pre-check-noise`)已删(HTTP 200)。
- `f10r2d@ce-ee.local` 账号保留(独立测试账号,避免下轮 single-session 互踢)。

## rev(代码复审)— PASS

- `packages/nc-gui/store/dashboard.ts`:
  - `$api` 经 `useNuxtApp()` 取(L5)✅(R1 修复在位)。
  - `openDashboard` 跳 `/{typeOrId}/{baseId}/dashboard/{dashboardId}`(L59-63)✅。
  - route 使用:`router.currentRoute` computed ref,`activeBaseId`/`openDashboard`/`openNewDashboardModal` 均自 route params 取,响应式正确 ✅。
  - `openNewDashboardModal` 默认标题防撞(`Dashboard N` 递增扫 titles Set,L73-76)+ 错误走 `extractSdkResponseErrorMsg` ✅;CRUD 各方法与 `dashboards` Map 同步一致 ✅。
  - `duplicateDashboard` 为 no-op stub(L65,上游同款占位,无 UI 入口)——信息性,非 error;`loadDashboards`/`activeBaseDashboards`/`openDashboard` 当前无 UI 消费点(widget 层预留)——信息性,非 error。
- `CreateNewActionMenu.vue` 门:L501 `<template v-if="!blockAddNewDashboard">`,且注释明确 `isEEFeatureBlocked`(CE 恒 true)不得作此门 ✅;`useEeConfig.ts` L77 `blockAddNewDashboard = computed(() => false)`(fork 解锁,带 `[CE-EE]` 标记)✅;权限面 `hasDashboardCreateAccess`(ACL `dashboardCreate`)与 sandbox reason 双重禁用逻辑完整;UI 实测 `aria-disabled=false` 与代码一致 ✅。`LazyPaymentUpgradeBadge` 的 CE stub(`Badge.vue` 渲染 `<NcSpanHidden/>`)无锁标渲染影响 ✅。
- `lib/acl.ts`:CREATOR include 含 `dashboardList/Create/Update/Delete`(L148-152,带 `[CE-EE]` 标记)✅;EDITOR 节无 dashboard* 权限(creator+ only 语义正确)✅。
- `[CE-EE]` 标记在位(store L71、acl L148、useEeConfig L76、menu L499)✅。

### vitest

- 实跑:`npx vitest run --config test/vite.config.ts`(排除 EE-only 自动跳过 8 文件 + 已知噪音 pwa-self-destroying / formula-url-xss)→ **16 文件 130/130 全过**。
- 「dashboard 专属 10 用例」不存在:仓内无 dashboard store/组件专属测试文件;唯一含 "dashboards" 的 `test/base-section-sidebar-order.test.ts` import `../ee/utils/sidebarOrderUtils`,CE 下(无 `packages/nc-gui/ee`)被 vite.config 的 eeOnly 检测跳过(带 console.info,非静默)。该文件属上游 EE 测试,非本 fork 缺口。信息性。

## 找茬

- 无(error 级)。信息性三项见上(store stub/无消费点、EE-only sidebar 测试跳过、Settings 无 dashboards 管理页)。

## 裁决

- int:PASS(核心断言全过;网络取证窗口受限已如实说明,归因环境非 F10)
- rev:PASS
- **总裁决:PASS(0 error)**
