# F02 Edit field permissions — R3 轮 lane4 复审报告（收敛第 2 轮）

审查对象：4b26d7a23f（实现）/ e85a421d92（R1 修复）/ 3b9dcbdbc6（R2 修复）。
方法：camoufox-cli 浏览器 UI 实测（owner/ed1/ed2/匿名 四会话）为主，代码辅审为辅。
环境：前端 :3000 / 后端 :8080 / nocodb-dev（qnap.elf-balance.ts.net）。测试账号 `f02r3l4-*`。

## 结论

**issues（2，实测坐实，建议必修）**

1. `packages/nc-gui/components/permissions/Modal/Content.vue:100-106`（根因在 `packages/nc-gui/components/dlg/Field/Permissions.vue:190-198`）：`DlgFieldPermissions` 以 `v-if="activeField"` + `visible=true` 同时挂载，watch 非 immediate 不触发 → `loadCurrentGrant`/`loadMembers` 从不执行 → 回显卡在默认 Editors & up 且 `existingId=null`。实测：Details → Permissions tab → Secret 行 Edit 打开弹窗，DB grant=user(ed1) 却回显 Editors & up（截图 10_configure_dialog_from_tab.png）；此时点 Save 会 POST 新 grant **静默覆盖现有 grant**。列头菜单路径（visible false→true）回显正确，两路径行为不一致坐实根因。建议：watch 加 `{ immediate: true }`（`if (v)` 守卫已有），或挂载时 `props.visible && loadCurrentGrant()`。
2. `packages/nc-gui/components/smartsheet/Form.vue`（渲染层）＋ `components/smartsheet/form/GridField.vue`：in-app form view **渲染层无 permission 门控**。`permissions.isAllowedToEdit` 唯一消费点是 Form.vue:378 的 submitForm 数据剥离，渲染不隐藏。实测：nobody 态与非入选 specific-users 态，ed2 的 form view 均渲染 Secret 输入框（截图 11/12），且同会话 grid 双击被前端拦截（证明 grants 前端活载，排除 fail-open 干扰）。数据面安全（提交剥离 Secret=null、匿名提交 403），但任务验收"nobody → form 中 Secret 隐藏（R2 前不隐藏）"**仍不达成**。建议：`setFormData()` 组装 localColumns 时对 `!isAllowedToEdit` 字段过滤或标记隐藏（渲染层），并对被剥离提交给出提示。

**观察项（不算 error）**

3. canvas 网格列头无 lock 图标：ncLock 只在 DOM header（Cell.vue/VirtualCell.vue）。canvas 面自有等价受限语义（`isCellEditable=false` → 灰边框 + editFieldTooltipTitle/editFieldTooltip tooltip；双击拦截 + toast 实测生效），CE canvas 原生即无 lock glyph，属呈现差异非 fork 缺陷（截图 02c_header_zoom.png）。
4. 匿名共享 form 同样渲染受限字段（public-metas 无字段剥离；提交被 403 整拒，数据面安全）——research §6 已裁定剥离为可选二批，记录缺口待 F03 前补。
5. ed2 in-app form 提交被静默剥离（无提示），UX 缺口。
6. 后端 5xx：本轮所有测试路径未见（观察面限于请求响应码；dev 日志无采集渠道，如实记录覆盖范围）。

**E3 环境噪音（不算 error）**：rspack watch 在 `tsc --noEmit` 完成时触发 rebuild → 后端重启换 JWT secret → 会话内 token/UI 登录态反复失效。证据：`dist/main.js` mtime 跨测试轮更新、8080 短暂 connection refused 后自愈、刚刷新的 token 突然 401。每次均在恢复后重测，未使任何验证项失真。另：首轮 UI 数据准备时误用 `nc_users`（实为 `nc_users_v2`）与 `POST /api/v1/meta/bases/`（实为 `/api/v2/meta/bases`），均为脚本笔误非产品问题。

## R2 修复验证（本轮重点，全部实测通过）

| R2 修复点 | 实测结果 |
|---|---|
| acl `permissionList` 放宽 editor+ | ed1/ed2 `GET /api/v2/meta/bases/:id/permissions` 200；ed1 POST 仍 403 `permissionCreate`（creator+ 未松动） |
| dlg/Field/Permissions.vue 补 `getPermissionLabel` 导入 | 弹窗四选项卡全部渲染（creators/editors/specific_users/nobody，label/desc/icon 正常，无 R1 空列表） |
| `loadPermissions(force)` 保存后即时刷新 | Save → toast "Permissions updated" → Permissions tab summary 实时切换（Editors&up → Specific users → 均准确）；Save/Delete/Reset 均 force refetch |
| Permission.update 共享 validateGrantShape | PATCH `granted_role:"viewer"` → 400 minimum role；`"bogusr"` → 400 Invalid |
| nobody 转换删 subjects | 切 Nobody 后 `nc_permission_subjects` 0 行残留 |
| datas.service isPublicForm 语义收敛 | 认证 in-app form 提交走剥离路径；匿名共享 form 提交 403（语义分离生效） |
| debug console.log 清理 | console.error/warn/unhandledrejection 捕获 = 0（SPA 内 Details→Permissions→弹窗全流程注入捕获） |

## 任务书 UI 流程逐项

1. **API 铺数据** ✓ owner(super)+base f02r3l4base+table Data(Name/Secret)+2 记录；ed1/ed2 editor 邀请成功。
2. **弹窗全流程** ✓ 列头右键（canvas 合成 contextmenu）→ 菜单含 Edit field permissions → 四选项卡渲染 → Nobody → Save（body 内按钮）→ toast → 重开回显 Nobody + Reset field permissions 按钮出现（截图 01）。
3. **editor 视角** ✓(行为) nobody 态 ed1/ed2 双击 Secret 均无编辑器 + toast "You do not have permission to edit this field"；Name 双击出编辑器并成功写库（r1→r1-edited，Secret 未动）。lock 图标见观察项 3（截图 02c/03）。
4. **Specific users 对照** ✓ owner 配 ed1 后：ed1 UI 可编辑并落库（s1→s1-by-ed1）；ed2 UI 拦截 + API PATCH 403 "You don't have permission to edit the field Secret"（未入选）。
5. **Form 隐藏** ✗ → issue 2（渲染不隐藏；提交剥离 Secret=null / 匿名 403 兜底，数据面安全）。
6. **Details tab** ✓ Permissions tab 存在（gate 已解）；字段 summary 准确（Name=Default — Editors & up / Secret 随 grant 实时变 Nobody、Specific users）；Edit 按钮打开弹窗——但回显错误见 issue 1（截图 07/08/09/10）。
7. **console error / 5xx 双零 / i18n** ✓ console 捕获 0；裸 i18n key 扫描 0 命中（"Permissions updated"/"Reset field permissions"/"Nobody"/"Default — Editors & up" 等均正常渲染）；5xx 未观察到（见观察项 6 覆盖说明）。
8. **代码辅审** ✓ 3b9dcbdbc6 acl editor+ 位置正确（EDITOR include，继承 creator/owner）；弹窗 import 补齐；force refetch 三处（save/delete/reset）；subjects 清理；PATCH 校验。发现 issue 1 的挂载路径缺口与 issue 2 的渲染消费点缺失。

## 证据

截图归档：`.work/ee-ce/r3-f02-lane4-shots/`（01 弹窗回显+Reset / 03 ed2 拦截 / 05 ed1 form / 06 匿名 form / 09 Permissions tab summary / 10 回显错误 / 11-12 form 渲染不隐藏双态对照）。
DB 断言：nc_permissions（granted_type/enforce_for_form 变迁）、nc_permission_subjects（nobody 后 0 行）、记录值（r1-edited / s1-by-ed1 / form-row-by-ed2 Secret=null）均经 psql 实查。
