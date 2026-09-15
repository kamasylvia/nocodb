# F02 复审 R1 — lane4(浏览器 UI 实测 + 代码辅审)

**结论:issues(4 error + 1 中危)**

- `packages/nocodb/src/services/datas.service.ts:1216`:form 提交路径 `baseModel.insert(param.body, null, param.cookie)` 第 2 参传 `null`,checkPermission 取 `user=(request)?.user` 恒空 → fail-open 放行:改为传 req(第 3 参才传 trx),或对该调用点单独补挂:实测 editor 登录态经 form view 提交 `Secret`(nobody grant、enforce_for_form=true)3 次全部原样落库(应 403/剥离);同一 editor 直接 `POST /api/v2/records` 带 Secret 被 403,证明仅此路径绕过。
- `packages/nc-gui/composables/useViewData.ts:411`:`isAllowedToEdit` 在 formColumns 构建时一次性求值为静态布尔(非 computed/getter),usePermissions 懒加载 grant 未到达时固化为 `true`,此后 grant 到达也不重算 → `Form.vue:378` 的提交剥离永不触发:改为 submit 时调用响应式 `isAllowed(...)` 求值,或 permissions 用 getter:实测 reload 后(GET permissions 已 200)提交仍泄漏,排除纯时序偶然,快照固化是结构性缺陷。
- `packages/nc-gui/components/smartsheet/header/ColumnMenu.vue:993`:`<DlgFieldPermissions v-if="column && meta && isEeUI">` — isEeUI=false 恒假,弹窗组件永不挂载;而菜单项 gate(722)已改 flag 驱动,形成「菜单可见可点、点了无反应」死路(实测 2 次复现,dialogs=0):去掉 `isEeUI`,与 722 gate 一致。
- `packages/nc-gui/components/dlg/Field/Permissions.vue:213/251` + `packages/nc-gui/components/nc/Modal.vue:153`:NcModal 硬编码 `:footer="null"` 且不透传 footer slot → Save/Cancel/Reset footer(251-284)永不渲染;且弹窗主体选项列表(a-spin 区域)实测渲染为注释节点,Editors&up/Creators&up/Specific users/Nobody 四选项与 select 全部缺失(dialog 内 buttons=[]、radios=0,无 console error),弹窗为只剩标题+字段名的空壳:footer 移入 default slot(NcModal 惯例),并排查 a-spin 主体未渲染原因(dev 构建下无 warn):唯一能打开弹窗的入口是 Details→Edit(ColumnMenu 入口因上一条死路),UI 配置流完全不可用。
- `packages/nc-gui/components/smartsheet/grid/canvas/composables/useCanvasTable.ts`(中危,提示缺失非功能错误):canvas grid 列头无 lock 图标绘制,仅 useCanvasTable.ts:1904 cell 编辑判断;DOM header(header/Cell.vue:60-63,264 的 ncLock + Tooltip)不在 canvas 渲染树(实测 DOM 0 个 header cell / 0 个 `.nc-column-lock-icon`):canvas header 补 lock 绘制或 overlay 提示。

**PASS 项(要点)**
- Details permissions tab:tab 存在(flag gate 生效);字段列表 Name/Secret/Price + summary 正确(Secret→"Nobody",其余→"Default — Editors & up");grant 建立后刷新即时反映(截图 04/06)。
- ColumnMenu 菜单项:gate 解锁生效,"Edit field permissions" 项可见、enabled、i18n 正常(截图 02);仅挂载 gate 遗漏 isEeUI(见 error 3)。
- 后端数据主路径拦截(干净角色后实测):v2 PATCH Secret:nobody 下 editor 403 / creator 403 / owner 200;role=creator grant 下 creator 200 / editor 403;v2 POST insert 带 Secret → editor 403;Name 无 grant → editor 200;错误文案 "You don't have permission to edit the field Secret"。
- 编辑拦截 UI:editor 双击/Enter 编辑 Secret 单元格 → toast "You do not have permission to edit this field",不进入编辑(截图 08b);Name 正常编辑保存(截图 09b)。
- CE 回归(fail-open):无 grant 字段(Name/Price)所有角色正常读写,无多余拦截;GET permissions editor 200。

**测试污染澄清(非实现缺陷)**:首轮 editor API 写 Secret 返回 200,排查确认是该测试号全局 roles='super'(setup 脚本重复执行重设)→ getProjectRole 解析 owner 级直通,属正当 bypass;清空全局角色后拦截全部正常。复审判读时勿引用首轮 200。

**console/网络证据**:Nuxt 无 error overlay;hook console.error/warn 捕获 0 条(含弹窗打开期间);本轮请求无 5xx(403/200/404-路由误用);后端日志仅既有 form-submission-email hook 噪音,与 F02 无关。i18n 无裸 key(菜单项/toast/tab 文案均正常英文)。

**步骤逐项**
1. ColumnMenu 入口:owner(canvas grid,坐标事件开菜单)→ Secret 列头菜单含 "Edit field permissions" 可点(截图 02)→ 点击后弹窗不出现(截图 03,dialogs=0)→ 2 次复现 → bug。
2. 配置流:Details→Permissions tab→Secret 行 Edit(截图 04)→ 弹窗打开但空壳(截图 05,DOM 验证 a-spin=comment、footer 缺失)→ Nobody/Save/Reset 均无法触达 → bug;配置改经 API 直建 grant(nobody)完成。
3. lock 图标+拦截:editor 干净会话(grid 截图 10)Secret 列头无 lock/tooltip(canvas 缺失)→ 双击/Enter 编辑 Secret 被 toast 拦截(截图 08b)→ Name 正常编辑(截图 09b)。
4. Details tab:见 PASS(截图 06)。
5. Form 隐藏:API 建 form view "f02 form"(owner 截图 11)→ editor 打开:Secret 字段行仍渲染(DOM `nc-form-focus-element` 内 y=691)→ 提交 Name+Secret → id=6/7/8 三次 Secret 原样落库 → 前端剥离+后端 form 路径双重失效 → bug。
6. i18n/console/5xx:见上。

**环境与数据**:base `pkknojh1beu9juf`(f02r1l4-base)/ table `m8588018i3mcw3k`(Data)/ Secret colId `cojnczn8e90ovmk` / form view `vw1rinxi8copdxdz`;owner=super(base owner)、editor(base editor,全局角色清空)、creator(base creator);测试行已清理,grant 已改回 nobody 留档。截图 `.work/ee-ce/f02r1l4-shots/01-12b`。后端 dev 进程 3:41 启动(含 F02 代码,permissions API 生效佐证),git worktree == 4b26d7a23f。

**E3**:无。
