# r2-f10-lane4 — F10 前端 R2 收敛确认（int + rev）

## 裁决：PASS

（非阻塞观察项 3 条列后，均不构成必修违反）

---

## int（UI 浏览器实测，camoufox-cli）——PASS

环境：前端 :3000 / 后端 :8080 均存活；测试 base 经 API 创建（资源前缀 f10r2d_），测后全部删除。

流程实录（登录后免刷新纯点击导航）：

1. UI 登录 f01e2e@ce-ee.local → 跳转 SPA。
2. 纯点击导航：nc-back-icon → workspace home（/w9qi3ljd，Bases 列表 42）→ base 卡片（focus+Enter，卡片为 tabindex=0 div）→ base home /nc/p2t8yuwmio8w5sm。
3. Create New（+ 按钮，`nc-mini-sidebar-plus-btn`）→ 菜单含 `mini-sidebar--dashboard-create` 项（同菜单：View 子菜单/Grid/Form/Gallery/Kanban/Calendar/Table）。
4. 点 Dashboard 项 → 即建即跳 `/nc/p2t8yuwmio8w5sm/dashboard/dashprm837hp8sz1c0`，页面渲染标题「Dashboard 1」（`[data-testid=dashboard-title]`）。
5. 第二个 base（f10r2d_base_lane4b / pgybdyw52s5nz16）同流程连建两枚：「Dashboard 1」→「Dashboard 2」，命名递增（store 碰撞规避逻辑 live 验证）。
6. API 对照（GET /api/v2/meta/bases/:baseId/dashboards）：
   - base1：1 条 = dashprm837hp8sz1c0「Dashboard 1」——与 UI 产物 id+title 完全一致。
   - base2：2 条 = dash63pal4xwqs7sdw「Dashboard 1」+ dash5fjztsgq9vypsv「Dashboard 2」——与 UI 产物完全一致。
7. 网络监控：登录后注入 fetch+XHR 双 hook，`window.__badReqs` 全程 `[]`——**0 个 ≥400 请求**。
8. 复核：fork 现状无 dashboard 列表/Settings 页签 UI（`activeBaseDashboards` 无 UI 消费者，base Settings 无 Dashboards tab）→ 列表复核走 API 对照（任务允许）。页面标题渲染即 UI 复核。
9. 清理：3 dashboard + 2 base 全部 DELETE 200。

### 环境噪声声明（非 F10 缺陷）

共享测试账号在多路并发下 token_version 互踢，会话内多次被强制登出。被踢残的半死会话中曾复现「Dashboard 菜单项点击无响应（同菜单 Table 项正常）」——但两次全新登录的健康会话中同样操作全部成功（含连建两枚、0 坏请求），且失败态无一伴随 XHR/错误，判定为环境伪象。若需排除，可换独占账号重测一轮。

## rev（代码复审）——PASS

- `store/dashboard.ts`：route 用 `router.currentRoute`（store 系惯例，同 base/bases/views/tables）；`$api.instance.*` 裸调用（见观察 3）；`openNewDashboardModal` 自动命名 + 碰撞规避（live 验证递增正确）；**Dialog.prompt：仓内 0 先例**（grep 0 命中），store 未用 Dialog、改为直建默认标题——与仓内惯例一致，无违规。`duplicateDashboard` 为 EE 面 stub（no-op），合理。
- `CreateNewActionMenu.vue`：门条件 `v-if="!blockAddNewDashboard"`（useEeConfig CE 分支 `computed(()=>false)`，已解 gate）✓；disabled 链（isDataTab/isBaseHomePage/hasDashboardCreateAccess + sandboxRestrictionReason）与同菜单 workflow/agent/table 项结构对称；live 验证菜单项可见且可用。
- `pages/index/[typeOrId]/[baseId]/dashboard/[dashboardId].vue`：路由参数 baseId/dashboardId 取用正确；加载态 GeneralLoader ✓；错误态 message.error toast ✓（无内联错误占位，见观察 2）；空态 `$t('msg.info.dashboardEmpty')` ✓。
- `lib/acl.ts`：`dashboardList/Create/Update/Delete` 仅 CREATOR include（L148-152）；角色级联 NO_ACCESS<VIEWER<COMMENTER<EDITOR<CREATOR<OWNER，OWNER 仅叠加 4 项额外权限 → creator+ 对称、EDITOR 及以下不含 ✓。
- i18n（`lang/en.json`）：`general.dashboard` / `tooltip.navigateToBaseToCreateDashboard` / `tooltip.youDontHaveAccessToCreateNewDashboard` / `tooltip.switchToDataTab` / `msg.info.dashboardEmpty` / `labels.createNew` 全部存在 ✓。
- 后端路由确认存在：`packages/nocodb/src/controllers/dashboards.controller.ts` GET/GET-by-id/POST/PATCH/DELETE 五路由（live 全命中）。

### rev 实跑门

`npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → **2 files / 10 tests 全过（10/10）**。

## 非阻塞观察项

1. **UI 无标题输入**：任务脚本期望标题「UI Dashboard 1」，但 fork 实现为即建即跳、自动命名「Dashboard N」（store 内注释已声明该设计），且无任何 dashboard 重命名 UI——「UI Dashboard 1」经 UI 不可满足。与代码意图一致，非缺陷；如需自定义标题能力归入 R3+ 功能项。
2. dashboard 页错误态仅有 toast，dashboard=null 时正文区空白（无错误占位 UI）。风格级。
3. `store/dashboard.ts` 用 `$api.instance.*` 裸路径，store 系主流为 `$api.internal.*Operation` typed 客户端；与 fork 已有 F05/F07 组件层裸调用先例一致，功能实测无碍。一致性级。
4. （环境）共享账号 token_version 竞态见 int 声明——建议后续 lane 会审时各路换独占测试账号，避免互踢噪声。
