# R5 F02 lane4 报告 — 浏览器 UI 抽测(camoufox-cli)+ 代码辅审

## 结论

**PASS**

无 error。R4(b95fbf7f74)三项前端修复(Form.vue 渲染门控 / 弹窗 onBeforeUnmount 复位 / Specific users option-filter-prop=label)全部实测通过;核心路径(弹窗开合/回显/Reset/nobody grant/editor 视角)抽测全过。

## 测试对象与环境

- 五 commit:4b26d7a23f(实现)→ e85a421d92(R1)→ 3b9dcbdbc6(R2)→ a8fc2c2966(R3)→ **b95fbf7f74(R4,本轮重点)**
- 代码新鲜度:后端 8080 PID 58057 于 09-14 08:27 启动(R4 diff 仅 nc-gui 两文件,后端零改动,等价 R4);前端 Nuxt dev HMR 即时反映 R4 前端代码
- dev DB:nocodb-dev(qnap.elf-balance.ts.net:5432,严禁生产库红线遵守,全程未触 nocodb 库)
- 测试数据:owner=f02r5l4-owner@test.local(roles='super' 提权后 signin)/ editor=f02r5l4-editor@test.local;base `p7ep6ai5wemd2m7` / table T1 `mrea7ofilyjqbal`(Name=`cwniiy9p9o00k9v`,Secret=`c4o4kkzv08z5vhf`)+ 2 行数据 + form view F1 `vwg9jad7ml1ajvgt`

## 步骤逐项

### 1. API 铺数据 ✓
signup 两号 → owner DB 提权 `roles='super'` → signin 建 base/table(Name+Secret SingleLineText)→ 邀请 editor(`POST /api/v1/db/meta/projects/:baseId/users`,roles=editor)→ 插 row1/row2。全部成功。permissions API `GET /api/v2/meta/bases/:baseId/permissions` 双路径存在(permissions.controller.ts:30-41)且返回正确。(中途一次 401 系本 lane 在 shell 重复 signin 轮转 token_version 踢掉浏览器会话,测试操作副作用,非产品 bug。)

### 2. owner 弹窗:四选项卡 / Nobody / Save / 回显 / Reset ✓
- Secret 列头菜单(canvas grid 合成鼠标事件点击列头)含 **Edit field permissions** 菜单项;弹窗渲染四选项卡:Creators & up / Editors & up / Specific users / Nobody
- 选 Nobody → Save → toast + 落库:`nc_permissions` 新增 `(field, c4o4kkzv08z5vhf, RECORD_FIELD_EDIT, granted_type=nobody, granted_role=NULL)`;API list 同步返回(enforce_for_form=true / enforce_for_automation=true)
- 重开弹窗:**Nobody 卡高亮回显** ✓ + footer 左侧 **Reset field permissions** 按钮出现(代码按 `existingId` 条件渲染,Permissions.vue:262-273;首配时无 grant 正确隐藏)
- Reset 实际点击 → grant 行删除(DB count=0)+ toast "Permissions updated" + 选中态回落 **Editors & up** 高亮 + Reset 按钮消失 → 与代码 `resetToDefault` 语义一致
- 截图:`r5-f02-l4-dlg-nobody2.png`(四选项卡+Nobody 选中)、`r5-f02-l4-dlg-echo-reset2.png`(回显 Nobody+Reset 按钮)、`r5-f02-l4-after-reset2.png`(Reset 后回默认态)

### 3. editor 视角:拦截 + Name 正常 ✓
- grid:editor 可见全部数据(row1/row2),Name/Secret 列正常显示(canvas grid 模式列头无独立 lock 图标 = 上游 canvas 渲染器设计,非 fork 缺失;`useCanvasTable.ts:1940` 注释明示 edit-restricted 列保留专属 field-lock 信号于编辑路径;DOM header 的 ncLock 属旧 grid 渲染器)
- **行为对比实测**(canvas 合成 dblclick):双击 Name cell → 进入编辑态(`activeElement=INPUT.nc-cell-field`)✓;双击 Secret cell → 无反应(`activeElement=BODY`,不进入编辑)= nobody grant 编辑拦截 ✓(`useCanvasTable.ts:1904` isEditRestricted 生效)
- 截图:`r5-f02-l4-grid-editor2.png`

### 4. Form 隐藏(R4 新修复重点)✓
- owner form view:Name + Secret 均渲染(对照基线,inner text 含 `Name | Secret | Submit`)`r5-f02-l4-form-owner2.png`
- editor 同一 form view `vwg9jad7ml1ajvgt`:渲染 `Name | Submit`,**Secret 完全消失**;DOM 全文 `includes('Secret') === false`。R4 前 nobody grant 下 form 仍渲染可填字段,现渲染层隐藏 = R4 修复生效
- 截图:`r5-f02-l4-form-editor-no-secret2.png`(可见左下角头像 FE = editor 会话佐证)

### 5. Specific users 过滤(R4 新修复)✓
- 弹窗切 Specific users → 多选下拉展开(option label=email,value=id)→ 输入 `f02r5l4`(email 前缀,非 id)→ 过滤命中 `f02r5l4-editor@test.local` + `f02r5l4-owner@test.local`。R4 `option-filter-prop="label"`(Permissions.vue:253)生效(R4 前按 value=id 过滤搜不到)
- Cancel 退出不落库(DB 确认 nobody grant 不变)
- 截图:`r5-f02-l4-users-selected2.png`(输入过滤词 + 两个 email 命中项)

### 6. console error / 5xx ✓(间接双证)
- 后端:`logs/backend.log` 全量 grep ` 500 | 502 | 503 | Internal Server Error` = **0 命中**;本 base 相关无 error(仅 getAst WARN,来自其它 lane 的 Link 列残留数据,与本功能无关)
- 前端:window `error` + `unhandledrejection` 监听注入后重走 form↔grid 导航流 = 空数组;全程各步截图无 error toast
- 限制:camoufox-cli 无 console 历史捕获命令,isolated eval 无法 hook 页面 world 的 console.error;以「UI 流程零异常表现 + 无 unhandled error + 后端 0×5xx」作间接证据

### 7. 代码辅审:b95fbf7f74 Form.vue 两处渲染条件 ✓
- 两处(1832 字段拖拽区 / 1893 可编辑区)条件 `(!isLocked || (isLocked && element?.visible)) && element?.permissions?.isAllowedToEdit !== false`,结构一致
- `element.permissions` 来源:`useViewData.ts:410-421` formColumnData 映射时对每列注入 `permissions.isAllowedToEdit` **lazy getter**(实时求值 `isAllowed(FIELD, c.id, RECORD_FIELD_EDIT, {isFormView:true})`)——元素上恒有定义,不存在 undefined 解引用风险;getter 求值时读 usePermissions 响应式 store,grant 异步装载后条件自动翻转(R1 注释:静态快照会冻结 pre-load 状态,lazy 化即为修此)
- `!== false` 语义:无 grant 时 evaluatePermission 返回 true(EDITORS_AND_UP 默认,fail-open 契约),正常渲染;仅显式 false(nobody/低角色/user 不匹配)时隐藏 —— 与后端 fail-open 语义对齐
- 弹窗 onBeforeUnmount 复位(Permissions.vue:200-206):实测弹窗正常关闭路径 /signin 可渲染(editor/owner 多次登出登录无受阻);R4 修复描述的 teleport 残留场景(sign-out 时弹窗开着)未复现异常
- 附:首轮弹窗初始值疑点排除——代码 `loadCurrentGrant`(Permissions.vue:64-70)无 grant 时初始 = EDITORS_AND_UP,符合 SDK `RECORD_FIELD_EDIT.minimumRole=EDITOR` 语义(首轮"Creators & up"系本 lane 误读 innerText,非选中态)

## 已知限制(非 error)

- canvas grid 列头无 lock 图标(上游 canvas 渲染器设计,lock 信号在 cell 编辑路径);DOM grid 的 lock 图标未单独抽测(默认渲染器为 canvas)
- console.error 直接捕获受工具限制,以间接证据覆盖(见第 6 项)

## 证据清单

| 项 | 路径 |
|---|---|
| owner grid 基线 | `.work/ee-ce/r5-f02-l4-grid-owner2.png` |
| 弹窗 Nobody 选中 | `.work/ee-ce/r5-f02-l4-dlg-nobody2.png` |
| 回显 Nobody + Reset 按钮 | `.work/ee-ce/r5-f02-l4-dlg-echo-reset2.png` |
| Reset 后回默认 | `.work/ee-ce/r5-f02-l4-after-reset2.png` |
| Specific users email 过滤 | `.work/ee-ce/r5-f02-l4-users-selected2.png` |
| owner form(Name+Secret) | `.work/ee-ce/r5-f02-l4-form-owner2.png` |
| editor form(Secret 隐藏) | `.work/ee-ce/r5-f02-l4-form-editor-no-secret2.png` |
| editor grid | `.work/ee-ce/r5-f02-l4-grid-editor2.png` |
| grant 落库/API/删除 | 本文件步骤 2/5 的 DB 查询与 API 响应记录 |
