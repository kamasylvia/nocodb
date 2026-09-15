# r3-f10-lane4（int + rev）

## 裁决：issues（不 PASS）

## issues

1. `packages/nc-gui/store/dashboard.ts:67-85`：`openNewDashboardModal` 防重名取号仅基于内存 `dashboards` Map，而 `loadDashboards` 全仓无任何 UI 调用方（仅 store 自身导出），Map 只在同会话内累积。页面刷新/新会话后 Map 恒空 → 恒提议 "Dashboard 1" → 撞 R1 引入的 (base_id,title) 唯一约束 + service 预检 → 400。**UI 实测复现**：新浏览器会话点击 Create New → Dashboard 菜单项 → 错误 toast "Dashboard title Dashboard 1 already exists in this base"，不创建不跳转；同会话第二次建（Map 已有值）则正常出 "Dashboard 2"。API 侧确认：POST 同名 title 返回 400。建议：`openNewDashboardModal` 开头 `await loadDashboards(baseId)` 以服务端为准取号，或捕获 400 后递增标题重试。
2. `packages/nc-gui/store/dashboard.ts:87-103`：fork 重写删除了基线 stub store 的三个公共字段 `activeDashboardId` / `isEditingDashboard` / `activeDashboard`（见 `git show 744d31618b:packages/nc-gui/store/dashboard.ts`），而 `components/smartsheet/Topbar.vue:10,48,53,65,68,73` 与 `components/dlg/share-and-collaborate/View.vue:19,143-156` 仍解构使用 → 现取到 undefined。运行时无崩溃（v-if/falsy 语义与旧 stub null 等价，实测页面正常），属 store 公共面收缩 + 上游合并隐患（低危/潜在）。建议：store 补回三个兼容字段，或同批改两处消费方。

## int 证据（UI 实测，camoufox-cli session f10r3/f10r3b）

- API 建 base：POST /api/v2/meta/bases → `f10r3d_base`（id prh7vjfnn4wmikg，ws w9qi3ljd），测完已删（GET 复核 404）；临时 API token 亦已删。
- UI 流程（登录后纯点击导航，无刷新）：登录 f01e2e → base 页 → mini sidebar Create New 菜单 **Dashboard 项可见、enabled、可点**（gate `!blockAddNewDashboard`，useEeConfig.ts:77=false，实测通过）→ 新建跳转 `/nc/{baseId}/dashboard/dash70qntm7y9ljxa3` → 页面渲染标题 "Dashboard 1" + "No widgets yet" 占位（fork 设计）→ 同会话二次建出 "Dashboard 2"（dashjqh65x4077a0o3）。
- Settings 复核：BASE SETTINGS（members/data-sources/integrations/mcp/variables/snapshots/general）**无 dashboards 节**，fork 无 dashboards settings 页（pages 下仅 `dashboard/[dashboardId].vue`）。存在性复核改经 API GET list 对照：列表与 UI 创建完全一致（2 条，id/title/base_id 全对上）。
- ≥400（登录后）：流程窗口内 backend.log（.work/ee-ce/logs/backend.log，size 标记前后 diff 扫描）无任何 4xx/错误栈新增；UI 全步无错误 toast（除 issue 1 的复现场景，该 400 即后端记录的预期行为）。限制说明：camoufox-cli eval 为隔离 world，页面内 fetch/XHR 钩子截不到应用流量，请求级监测技术不可行，以上述服务端日志 + UI 表现 + API 对照三项证据代替。
- 环境约束（非 F10 错误，实测定位）：① 同账号每次 login 轮换 `token_version` 并删 refresh tokens（users.service.ts:736-782 single-session enforcement），5 路共用 f01e2e 互踢；后端以 `PLAYWRIGHT_TEST=true` 启动可关（users.service.ts:737）。② 测试窗口内他路改码触发 rspack 重编译重启 ≥2 次，JWT secret 随进程重生成 → 存量会话全废（UI 弹回 /signin、curl token 401，后端 log 可见对应 401 栈）。两者均为共享 dev 环境约束，非本功能缺陷。

## rev 证据

- store/dashboard.ts：`$api` 经 `useNuxtApp()`（:5）✓；`openDashboard` 跳转 `/{typeOrId}/{baseId}/dashboard/{dashboardId}`（:59-63）与页面路由 `pages/index/[typeOrId]/[baseId]/dashboard/[dashboardId].vue` 参数对齐 ✓；`route = router.currentRoute` 响应式使用 ✓；HMR accept ✓。
- CreateNewActionMenu.vue:501 gate `!blockAddNewDashboard` ✓；`dashboardCreateReason`/`hasDashboardCreateAccess`（isUIAllowed('dashboardCreate')）链路完整。
- lib/acl.ts:148-152：dashboardList/Create/Update/Delete 于 CREATOR include ✓；role-scope 级联（:316-332）传至 OWNER ✓；EDITOR 及以下无 ✓；重复权限校验（:297-314）未触发。
- vitest 实跑：全量 130 passed / 5 skipped / 1 套件级失败（formula-url-xss beforeAll hook 超时 = 上游并发 flake，AGENTS §3.2 已记录，单跑 5/5 过，已复跑验证）。**任务口径 "vitest 10/10" 与仓内实际不符：不存在 F10 专用 vitest 文件**（store/dashboard.ts、CreateNewActionMenu、acl dashboard* 均无测试覆盖）——测试缺口本身列为观察项，不计 error。
