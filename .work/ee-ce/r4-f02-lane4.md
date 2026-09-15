# r4-f02-lane4 — F02 R4 UI 实测(camoufox)+ 代码辅审

审查对象:4b26d7a23f(实现)/ e85a421d92(R1)/ 3b9dcbdbc6(R2)/ a8fc2c2966(R3,纯后端,UI 不可见)。
环境:前端 :3000 / 后端 :8080 / nocodb-dev;camoufox-cli 本机会话 `f02r4l4`;canvas grid 表头经合成 MouseEvent 驱动(表头为 canvas 绘制,无 DOM 节点)。
测试数据:`f02r4l4-setup.sh`;base `pe5499deuvrb59k` / table `mapcrnmr8q3ml6y` / Secret 列 `c21wur3kzrt7k14`;owner `f02r4l4-owner@test.local`(DB 提权 roles='super')、editor1/editor2(base roles=editor)。

## 结论

issues:

1. `packages/nc-gui/components/dlg/Field/Permissions.vue:202(NcModal) + packages/nc-gui/components/smartsheet/header/ColumnMenu.vue:992` : 弹窗打开状态下登出/会话失效跳转 /signin 时,teleport 的 `ant-modal-wrap` 残留为全屏孤儿 modal(z-index 1000、pointer-events auto),拦截 signin 页全部点击,且 Cancel/Escape 均无法关闭(reload 才能清除);同一场景用上游 expanded-form dialog 做对照,登出后 0 残留 → F02 弹窗专属缺陷 : 建议 logout/signout 流程强制复位该弹窗 visible(或全局 dialog store 随 signout 清理 / NcModal 加 destroyOnClose 并确保卸载时移除 teleport DOM)。
2. `packages/nc-gui/components/smartsheet/Form.vue:378 + packages/nc-gui/composables/useViewData.ts:411` : form view 对无权字段只做**提交时剥值**,不做视觉隐藏——`isAllowedToEdit` 全仓唯一消费点是 Form.vue:378(submitForm 里 delete formState),模板层无任何隐藏/禁用渲染;实测 editor2(未被 Specific users 授予)打开 form view,Secret 以可填输入框渲染(截图 13c),填了值提交会被静默丢弃,与该功能「无权字段在表单隐藏」语义不符(fork R1 注释自述目标是让 grant 生效于 Form.vue,现仅剥值): 建议 Form.vue 模板按 `!col.permissions.isAllowedToEdit` 隐藏字段(或渲染只读态 + `permissions.label` tooltip,该 label 现为死配置无消费点)。
3. `packages/nc-gui/components/dlg/Field/Permissions.vue:240-247` : Specific users 多选搜索按 option **value(=user id)** 过滤,按 email 文本搜不到(a-select 未设 `optionFilterProp="label"`,默认过滤 value);实测输入 `f02r4l4-editor1` 0 结果、输入 id `usndv3qadm67eeeg` 命中,真实用户无从得知 id : 建议 a-select 加 `option-filter-prop="label"`(或自定义 filterOption 同时匹配 email)。
4. [observation,未复现不计 error] 首次从 Details→Permissions tab→Edit 打开弹窗时采样到回显 selected=editors_and_up(实际 grant=Specific users);随后多轮复测(400/800/1200/2000ms 采样)均正确回显 specific_users + subjects chip。疑瞬态竞态,建议后续轮关注。

PASS 部分(证据见下):弹窗全流程(4 选项卡/Nobody/Save/toast/回显/Reset)、editor 拦截(Nobody 与 Specific-users 对照)、editor 可编辑并落库、Details Permissions tab(owner 可见+summary 正确+Configure 打开回显;editor2 无该 tab 正确)、R2 三改动代码走查、后端 5xx 分诊(本 lane UI 流零 5xx)。

## 步骤逐项

### 0. R2 代码辅审(3b9dcbdbc6 三改动)— PASS
- acl:`packages/nocodb/src/utils/acl.ts:559` `permissionList: true` 位于 `ProjectRoles.EDITOR` include(include 向上继承,creator/owner 自动获得);permissionCreate/Update/Delete 仍在 creator 段。注释说明 read-only 语义。
- usePermissions:`packages/nc-gui/composables/usePermissions.ts:3` 从 nocodb-sdk 导入 `getPermissionLabel`,:190 再导出,弹窗 :232 使用,链路一致。
- loadPermissions(force):`:48-54` force 绕过 `loadedFor===baseId` guard;弹窗 save(`Permissions.vue:160`)与 reset(`:178`)均 `loadPermissions(true)`,baseId 空值守卫仍在;失败路径 `loadedFor=null` 允许重试。

### 1. 弹窗全流程(owner)— PASS
- Data grid → 右键 Secret 表头(canvas 坐标 x=380,y=16)→ 菜单含 `Edit field permissions`(菜单顶部 FIELD ID=c21wur3kzrt7k14 确认是 Secret 列)。
- 弹窗渲染 4 选项卡:Creators & up / **Editors & up(默认选中,border 高亮)** / Specific users / Nobody(viewers/commenters/everyone 已按设计过滤);Cancel/Save 在 body(NcModal footer=null 的 R1 处理)。截图 `02-owner-dialog-editors-default.png`。
- 选 Nobody → Save → toast `Permissions updated`,弹窗关闭;后端落库 `nc_permissions` granted_type=nobody。
- 重开弹窗:回显 Nobody 选中 + Reset 按钮可见。截图 `03-owner-dialog-nobody-reopen.png`。

### 2. editor1 视角(Nobody grant)— PASS
- editor1 登录打开 grid(截图 `04-editor-grid-nobody.png`)。canvas 网格表头无 lock 图标——canvas 构建的锁定信号为 cell hover 灰框 + tooltip(`useCanvasRender.ts:1083`,非 DOM 网格的 header ncLock),属上游 canvas 行为,非 fork 缺件。
- 双击 Secret 单元格:无编辑器打开,toast `You do not have permission to edit this field`(=`objects.permissions.editFieldTooltip`)。截图 `05-editor-secret-dblclick-blocked.png`。代码路径:`useCanvasTable.ts:1904` isEditRestricted → `:1975` toast+return null。
- 双击 Name 单元格:行内 INPUT 编辑器打开,val=row1,正常可编。截图 `06-editor-name-editable.png`。
- editor 右键表头无菜单:`isFieldEditAllowed = isUIAllowed('fieldAdd')`(creator+),上游既有 gate,非 F02 回归;editor 天然无配置入口。

### 3. Specific users — PASS
- owner 弹窗选 Specific users → 用户多选出现 → 选中 `f02r4l4-editor1@test.local` → Save → 弹窗关闭;DB:`nc_permissions` granted_type=user + `nc_permission_subjects` subject_id=usndv3qadm67eeeg。
- editor1 双击 Secret:INPUT 编辑器打开,写入 gamma → Enter,API 回读 `{"Name":"row1","Secret":"gamma"}` 落库成功。截图 `08-editor1-secret-editable.png`。
- editor2(未入选)双击 Secret:无编辑器 + toast 权限拦截。截图 `09-editor2-secret-blocked.png`。
- 搜索按 email 不可用 → 见 issues #3。

### 4. Details tab Permissions — PASS
- owner:Details → Permissions tab 存在(编辑器为 editor2 时该 tab 不存在,`Details.vue:37` fieldAdd creator-only gate 正确)。tab 内容:表级默认横幅 + Field permissions 列表 **Name = Default — Editors & up / Secret = Specific users**,与 DB grant 一致。截图 `10-details-permissions-tab.png`。
- Secret 行 Edit/Configure(`nc-permissions-configure-Secret`)打开弹窗,复测回显 specific_users + chip 正确(截图 `11-details-edit-opens-dialog.png`)。首次采样异常见 issues #4。

### 5. Form view 隐藏 — FAIL(issues #2)
- owner 建 Form view(vwqxtw4rw25mfv03),owner 视角 Secret 可见(符合 owner 直通,截图 `12`)。
- editor2 打开同一 form:Name 与 **Secret 字段均渲染为可填输入框**(scrollIntoView 取证截图 `13c-editor2-form-secret-field.png`);isAllowedToEdit 仅用于提交剥值,见 issues #2。安全面无洞(剥值 + 后端 checkPermission 兜底),但 UX/语义不符。

### 6. console error / 5xx 双零 — 分诊后成立
- 后端日志(`logs/backend.log`)全程扫描:permission 路由零错误;log 中的 500 均为 `bulk-data-alias.controller → bulkUpsert → afterUpdate(BaseModelSqlv2.ts:6013)` 'Id' 错误与 malformed-JSON 错误(7:45-7:53 窗口),是并行 lane 的 bulk API 测试所致——本 lane 全程未调用 bulk 端点。
- 本 lane 自身仅 401(API signin 轮换 refresh token 踢掉同账号 UI 会话的预期产物,亦为本轮多数「登出→幽灵弹窗」复现的触发源;该踢会话机制本身非 bug,见 issues #1 的对照实验设计)。
- 历史 rspack `TS2367 Permission.ts:362` 编译错误为中间态:当前源码已无该比较,后续多次编译 `Rspack compiled with 1 warning`,干净。
- 前端 console 无法回溯采集(camoufox 工具限制);Nuxt dev error overlay 未在任何截图出现;所有非预期 toast 均为预期的权限拦截文案。记 E3(tooling)不算 error。

## 截图目录
`.work/ee-ce/f02r4l4-shots/`:01 owner grid、02 弹窗默认 Editors&up、03 Nobody 回显+Reset、04 editor1 grid、05 Secret 双击被拦、06 Name 可编、07 Specific users 选中态、08 editor1 Secret 可编、09 editor2 被拦、10 Permissions tab、11 Configure 弹窗、12 owner form、13/13b/13c editor2 form Secret 可见取证。

## 复现脚本/上下文
- `.work/ee-ce/f02r4l4-setup.sh`、`.work/ee-ce/f02r4l4-ctx.json`(含 base/table id 与测试口令,仅 nocodb-dev)。
