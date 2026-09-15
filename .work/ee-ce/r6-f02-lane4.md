# R6 F02 lane4 — 浏览器 UI 抽测(camoufox)+ 代码辅审

## 结论

**PASS**(0 error;1 项 E3 环境事件,有诊断证据,不计 error)

---

## 0. 代码辅审:10e8d92729(R5,纯后端确认)

`git show --stat 10e8d92729`:仅 `packages/nocodb/src/db/BaseModelSqlv2.ts`(+10/-1)、`packages/nocodb/src/models/Permission.ts`(+10)、`-X`/`PATCH`/`AGENTS.md`(流程文件)。**零前端文件**。

- `Permission.ts` validateGrantShape:nobody + subjects → 400,create/update 共用该函数 → 对称 ✓
- `BaseModelSqlv2.ts` updateLTARCols hook:payload key 匹配放宽为 column_name/title/id(原仅 column_name,title-keyed payload 下 hook 死代码)✓

**UI 间接影响核查**:前端弹窗 `packages/nc-gui/components/dlg/Field/Permissions.vue:127-128` nobody 分支 payload 仅 `granted_type=NOBODY`,不带 subjects → 不触发 R5 新增 400。Save 路径无影响(实测 owner Save 成功,见 §2)。

## 1. API 铺数据

- owner `f02r6l4-owner@t.io`(DB 提权 roles='super' 后 signin)、editor `f02r6l4-editor@t.io`(org=org-level-viewer,base=editor)
- base `pymz2hlac4ssejf` / table `Data`(`mdsj57w536ulahr`;Name=`cjy3sw2edxmdcvr`,Secret=`cpc752fv94dcf3p`)/ row1
- editor 邀请:`POST /api/v2/meta/bases/:bid/users` → "invited successfully"

## 2. owner 侧 UI(camoufox;canvas grid 经合成 MouseEvent 驱动)

grid 为 canvas 渲染(`packages/nc-gui/components/smartsheet/grid/canvas/`),列头/单元格不在 DOM → 快照不可见属正常,交互用 canvas 上合成 mousedown/mouseup/click。

1. **弹窗开合 + 四选项**:Secret 列头菜单 → "Edit field permissions" → 弹窗渲染 Creators & up / Editors & up(默认选中)/ Specific users / Nobody + Cancel/Save ✓ → `.work/ee-ce/r6-lane4-shots/1-dialog-open.png`
2. **Nobody → Save**:弹窗关闭;DB `nc_permissions` 行 `field|cpc752fv94dcf3p|RECORD_FIELD_EDIT|nobody|enforce_for_form=t` ✓
3. **回显**:重开弹窗 → Nobody 高亮 + "Reset field permissions" 按钮出现 ✓ → `r6-lane4-shots/2-dialog-reopen-nobody.png`
4. **Reset**:点击 → DB grant 行删除(count=0)、按钮消失;再选 Nobody → Save → DB `nobody|t` ✓
5. owner 网格 nobody 后渲染正常 → `r6-lane4-shots/3-owner-grid-after-nobody.png`

## 3. editor 侧 UI

- editor 进入网格正常(FE avatar;Secret 列值仍可见 — RECORD_FIELD_EDIT 仅限编辑,合理)→ `r6-lane4-shots/4-editor-grid.png`
- **列头菜单抑制**:editor 点 Secret 列头(文本区/箭头区)均无菜单、无 Edit Column 弹窗。源码一致:canvas `grid/canvas/index.vue:1728` `isFieldNotEditable = !isUIAllowed('fieldEdit') || ...` 整级 return;菜单项级 gate `smartsheet/header/ColumnMenu.vue:720-724` 要求 `isUIAllowed('fieldAlter')` → editor 不可达 "Edit field permissions" ✓
- **Secret 编辑拦**:dblclick Secret 单元格 → 无 cell editor 弹出(DOM input 计数=0)✓。注:合成事件可驱动菜单/弹窗,但无法触发需 trusted focus 的内联编辑路径 → Name/Secret 编辑对比以 API 补证:
  - editor `PATCH /api/v2/tables/:tid/records {"Id":1,"Secret":...}` → **403** "Forbidden - You don't have permission to edit the field Secret" ✓
  - editor `PATCH ... {"Id":1,"Name":...}` → **200** ✓(Name 正常)
- **Form 隐藏**:form view `vwkjpk5hpzldqphc` 下 editor 打开 → 仅 Name 字段,Secret 不在 DOM/innerText ✓ → `r6-lane4-shots/6-editor-form-nobody.png`

## 4. R5 权限 API 抽查(路由 `/api/v2/meta/bases/:baseId/permissions`)

- **create** nobody+subjects(未授权的 Name 列)→ 400 `"subjects are not allowed on nobody grants"` ✓
- **update** nobody+subjects(Secret 现存 grant)→ 400 同文案 ✓ — create/update 对称达成
- clean nobody:create → 200;update → 200 ✓
- 测试残留清理:Name 测试 grant 已 DELETE(200);复验 editor PATCH Name=200 / Secret=403

## 5. console error / 5xx 双零

- grid 页 + form 页分别 hook `window.onerror` / `unhandledrejection` / `console.error` 后页面内交互 → **0 条**
- 本轮全部 ~50 个 API 调用状态码 ∈ {200,400,403,404},**无 5xx**(404 系本 lane 首次探测时的错误路由,非服务端错误)

## 6. E3 环境事件(诊断证据,不计 error)

审查中途后端 rspack dev 自行重建重启,8080 掉线约 75s:期间 UI 登录全量无响应(owner 对照组同样失败)、前端页面 hydration 中断。证据:`lsof` 8080 无监听但 rspack 进程存活(PID 19480/19509);15s 间隔轮询,t+75s 恢复 200;恢复后所有 F02 UI 路径复测正常。R5 commit 未触任何前端文件,时间上无因果。定性:dev server 重建窗口,与 F02 代码无关。

附注(流程非 F02 问题):抽测初期 editor org role 被本 lane 误设为 'user'(无效值)导致前端 workspace bootstrap 失败弹回 signin,已修正为 'org-level-viewer' 并复验;此为测试环境配置失误,非产品缺陷。

## 测试终态

base `pymz2hlac4ssejf`(f02r6l4 base):Secret=nobody grant 存续(enforce_for_form=t),Name 无 grant;row1 Name='row1-edited2'。账号 f02r6l4-owner/editor@t.io 留存。
