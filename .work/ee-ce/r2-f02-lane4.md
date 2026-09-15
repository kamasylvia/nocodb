# r2-f02-lane4 — F02 R2 收敛轮:浏览器 UI 实测(camoufox-cli)+ 代码辅审

> 审查对象:4b26d7a23f(F02 实现)+ e85a421d92(R1 修复,重点 UI 3 项)。
> 环境::3000 Nuxt dev / :8080 后端 dev / nocodb-dev。测试账号 f02r2l4-owner / f02r2l4-editor@test.local,base `pmzamnxcutu1i8t`「f02r2l4 Base」,table `mijt7jox4mg8cij` Secrets(Name/Secret),截图目录 `.work/ee-ce/r2-f02-lane4-shots/`。
> ⚠️ 测试中途工作树出现未提交 R2 修复(diff:删 4 处 console.log、Permission.validateGrantShape、loadPermissions(force)、datas.service isPublicForm 回撤)。本报告对**两 commit**下结论,并逐条标注工作树是否已修。

## 结论

```
packages/nc-gui/components/dlg/Field/Permissions.vue:232 : 模板用 getPermissionLabel 但未 import(未从 usePermissions 解构,nocodb-sdk 导出不在 auto-import)→ 渲染时 _ctx.getPermissionLabel undefined → a-spin 子树渲染崩,prod Vue 静默吞(0 console 输出)→ 弹窗只显示字段名+Save/Cancel,四个权限选项(Nobody/Specific users/Creators/Editors)永不出现 = F02 核心配置 UI 死路(ColumnMenu 与 Details 两挂载点同崩) : 从 usePermissions() 解构 getPermissionLabel(该函数已在其 return 中)或补 `import { getPermissionLabel } from 'nocodb-sdk'`
packages/nocodb/src/utils/acl.ts:279 : permissionList 归入 creator+ → editor 打开 base 时 usePermissions GET /api/v2/meta/bases/:id/permissions 403 → permissions 恒 [] → 前端全部权限指示失效:Secret 列头无 lock 图标、双击直接进入编辑态(保存才 403 toast)、Form view 无权字段不隐藏(R1 修复③ useViewData 惰性 getter 机制正确但数据源被 ACL 掐断,editor 场景恒 allow) : permissionList 放宽至 viewer+/editor+(读权限面无泄密面),或为已登录成员提供非 ACL 只读通道;同时 usePermissions 区分「拉取失败」与「无 grant」,失败时不得 fail-open 渲染为可编辑
packages/nocodb/src/db/BaseModelSqlv2.ts:3058,10575,10613 + packages/nocodb/src/services/permissions.service.ts:83 : 4 处 debug console.log([F02-P/Q/R/Z])随 e85a421d92 提交,与 commit message「Debug probes removed」矛盾;F02-Z 每次 create 泄漏全量 grant list 到 stdout : 工作树已删(未提交),尽快入库
packages/nocodb/src/models/Permission.ts(update) : commit 版本 update 不校验 granted_role(enum+minimumRole 只在 insert),PATCH 可把 role grant 降到 viewer : 工作树已修(validateGrantShape 复用,实测 PATCH viewer/bogus 均 400),待入库
packages/nc-gui/composables/usePermissions.ts:159 isAllowed / :128 getPermissionSummary 仅评 grants[0] : 与后端 R1「any denying grant blocks」规则漂移;当前被 service 去重兜住(单 (entity,entity_id,permission) 仅一行,实测重复 POST 400),记为潜在面非现行 error : 循环评估或多 grant 语义对齐后端
```

E3(外部限制):无。dev 环境杂音(Nuxt dev 偶发 Page Loading Error toast、直连 base URL hydration 竞态、Bases(0) 瞬时空,刷新即愈)非 F02 引入,不计。

## 实测逐项(步骤号对应 lane 任务书)

1. **API 铺数据** ✓:owner signup → DB `nc_users_v2.roles='super'` → 建 base/table(Name+Secret)+ 2 记录;editor signup + 邀请为 base editor(DB nc_base_users_v2.roles=editor 复核)。
2. **弹窗全流程(R1 重点)——部分失败(E1)**:
   - 列头菜单(chevron 区单击)→「Edit field permissions」菜单项**可见可点**(03 截图);
   - 点击 → **弹窗出现**(04 截图)= R1 修复①(ColumnMenu v-if 去 isEeUI)通过;
   - Save/Cancel 在弹窗 body 内(R1 修复②通过;有 grant 时 Reset 亦在,12 截图);
   - **但四个选项卡全部不渲染**(弹窗 DOM:`<a-spin>` 位置为注释占位;04 截图)。选 Nobody/Save/toast/重开回显 无法执行 → E1。
   - 根因链:vite 预编译产物 `dist` 里 v-for 正确;`.nuxt/imports.d.ts` 无 getPermissionLabel(仅 `export { usePermissions, PermissionOption }`);编译产物 `_ctx.getPermissionLabel(...)`;运行环境 prod Vue(无 `__vue_app__._instance`)→ 渲染错误静默 → console error 计数 0 但 UI 坏。
3. **lock 图标 + 编辑拦截(editor)——失败(E2)**:editor 登录 → grid **Secret 列头无 lock**(06);双击 Secret cell **直接进入编辑态**(07);改值回车 → 后端 403 到达 UI:toast「Record update failed: Forbidden - You don't have permission to ed…」(08)。后端矩阵:editor PATCH Secret 403 / PATCH Name 200 / insert 含 Secret 403 / insert 仅 Name 200 / owner PATCH Secret 200。即:数据安全由后端保住,前端预拦与提示全失。
   - **Form view**:editor 建 Form view → **Secret 字段仍显示**(09;预期 enforce_for_form=true + Nobody 应隐藏)= R1 修复③ 的消费链失效(数据源 403)。
4. **Details tab(owner)✓**:Details → Permissions tab 渲染完整:说明条 + Field permissions 列表,**Secret=Nobody,Name=Default — Editors & up**(11 截图);行内 Edit 打开同一弹窗 → 选项区同样不渲染(12,复证 E1)。
   - owner grid 无 lock(R1 修复④ owner bypass)✓(10)。
5. **Specific users 流**:UI 弹窗死路无法走;API 对照:删 nobody → 建 user grant(subject=editor)→ editor PATCH Secret **200** ✓;重复 grant 400 ✓;role=viewer(低于 minimumRole)POST/PATCH 400 ✓。
6. **console error / 5xx**:观察窗内 console.error=0、服务端 5xx=0(403/400 均预期)。⚠️ E1 因 prod Vue 静默吞渲染错误,console 双零不代表 UI 健康。
7. **i18n**:en.json/zh-Hans.json 的 `permissionUpdated/selectUsers/editFieldPermissions/resetFieldPermissions/fieldPermissionsNotAvailableForSyncedColumns/dataInThisFieldCantBeManuallyEdited` 均在;页面无裸 key。

## 代码辅审(对两 commit)

- **R1 修复① ColumnMenu v-if 去 isEeUI**:正确,实测通过(菜单项 flag-gated,弹窗无条件挂载)。
- **R1 修复② 按钮移入 body**:正确,Save/Cancel/Reset 均现(修好了 NcModal `:footer=null` 吞 footer slot 的问题)。
- **R1 修复③ useViewData 惰性 getter**:实现正确;但上游数据源被 acl.ts:279 掐断(E2),editor 场景恒 true,实测 Form 未隐藏。
- checkPermission(BaseModelSqlv2:10558+):owner 直通、多 grant any-deny、匿名 form+enforce_for_form 逻辑正确(后端矩阵全过佐证);Permission.list cache-free 方案合理。
- datas.service nestedInsert 挂点、public-datas 匿名判定:工作树正在重构 isPublicForm 标志(测试窗内变动),终态以入库 commit 为准,本轮不下结论。

## 证据文件

- `.work/ee-ce/r2-f02-lane4-shots/03-column-menu-edit-field-permissions.png`(菜单项)
- `04-permissions-dialog-initial.png`(弹窗无选项,E1)
- `06-editor-grid-lock.png`(editor 无 lock,E2)、`07-editor-secret-cell-edit.png`(编辑态打开)
- `08-editor-secret-save-403.png`(403 toast)、`09-editor-form-secret-visible2.png`(Form 未隐藏)
- `10-owner-grid-with-nobody-grant.png`(owner 无 lock ✓)、`11-owner-details-permissions-tab.png`(tab ✓)
- `12-owner-details-dialog-still-broken.png`(第二挂载点复证 E1)
- 测试残留已清理(grant 全删,Name 改回 alpha;空行 row3 留在表内,无影响)
