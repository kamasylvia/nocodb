# r5-f05-rev-b — F05 前端第 5 轮终审（第 4 路）

## PASS

## 审查范围与证据

### 1. R4 掩码点修复复核（Variables/index.vue v-if/v-else 结构）
- 服务端契约实测确认：`packages/nocodb/src/helpers/baseVariableValidators.ts:53` `maskSecretVariable` 对 SECRET 行剥 `value`/`default_value`（置 undefined）；`src/services/base-variables.service.ts:23-29` list 端点对所有行过 mask → **list 响应中 secret 的 value 恒 undefined，无论是否已设值**。
- 前端 `Variables/index.vue:162-171`：secret 行 `v-if variable.value`（undefined → falsy，恒不走）/ `v-else` 显示 `••••••••`。已设值 → 点；未设值 → 点。与「服务端恒掩码」契约**自洽，行为正确**。v-if 分支为防御性残留（未来服务端若改回掩码串仍正确），非 bug。
- TEXT 行明文显示 = 契约内（仅 secret 掩码）。
- 编辑回填：secret 走单值 GET（`service.get` 返回解密完整值，`base-variables.controller.ts:44` `@Acl('baseVariableList')` creator-only，权限集合与 baseVariableUpdate 一致，无放宽）；TEXT 直接用 list 行。PATCH body 只传 `{value, description, type}`，key 恒 immutable（input disabled + 后端 `service.update:98` 拒改），一致。

### 2. 三门
- gate：`useEeConfig.ts:357` `blockBaseVariables = computed(() => false)`（`// [CE-EE] F05` 标记在位）。
- 菜单：`BaseSettingsMenu.vue:243` `!blockBaseVariables && isUIAllowed('baseVariableList')`；`:57` navigate 带 block guard。
- 页签：`View.vue:604` tab pane 同双闸；`View.vue:190` 深链 watch 同条件。三处条件一致，无双源漂移。
- variables 分支不要求 `isEeUI`（permissions/snapshots 等仍带）——fork 自实现 CE 功能的有意差异，合理。

### 3. 深链
- `utils/settingsRouteUtils.ts:24` `'variables': 'variables'` 双向映射在位（settingsTabToSlug / baseSettingsSlugToTab）；`View.vue:238` settingsPageTitle 有 'variables' 键；无权限深链 fallthrough 'collaborator'，行为合理。

### 4. i18n（lang/en.json）
- 全键实测在位且非空：`title.baseVariables`、`msg.info.baseVariablesSubtitle/Empty/KeyFormat/DeleteTitle/DeleteDescription`、`msg.error.baseVariableKeyRequired`、`msg.success.baseVariableCreated/Updated/Deleted`、`labels.key/value/type/description`、`general.add/edit/delete/cancel/save/create`。`{key}` 命名插值与 `t(..., { key })` 用法匹配。

### 5. 标记
- `// [CE-EE]` 标记在位：index.vue:2/165、View.vue:41/190/604、useEeConfig.ts:356、BaseSettingsMenu.vue:243、acl.ts:136。

### 6. 类型
- `nocodb-sdk/src/lib/globals.ts:527` `BaseVariableValueType {TEXT, SECRET}` 存在；`BaseVariableType` 导出可用。`GeneralIcon icon="eye"` 在 iconMap（iconUtils.ts:999 `eye: PhEyeThin`）。

### 7. ACL
- `lib/acl.ts:137-140` creator include 四 op（baseVariableList/Create/Update/Delete）；测试 `test/base-variables-acl.test.ts` 锁定 creator 有、editor/commenter/viewer include 无。

### 8. 测试实跑
```
cd packages/nc-gui && npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts
Test Files  2 passed (2)
Tests  10 passed (10)   ✓ 10/10
```

### 9. 找茬扫描（有证据项，均判非 fork error）
- `BaseSettingsMenu.vue:252-255` 的 `LazyPaymentUpgradeBadge :feature="FEATURE_BASE_VARIABLES"`：源自上游 sync commit `58ed76ab44`（非 fork F05 diff 引入；permissions/sync 等 6 处同款上游既有模式），且 Badge 本体为 CE stub（`components/payment/upgrade/Badge.vue` 渲染 `<NcSpanHidden />`，运行时不可见）→ 非 error。
- `VariableSetupWarning.vue` 为空 stub（渲染 `<span />`），F05 范围外的 topbar 占位，无行为 → 非 error。
- `baseId` undefined 理论路径（openEditModal/deleteVariable 无 guard）：tab pane v-if 含 `base.id`，页面仅存在于 base settings 上下文，不可达 → 非 error。
- 后端 service `validateUniqueKey`（`base-variables.service.ts:202-203`）用 `context.base_id` 而非参数 `baseId`：两者在 controller 注入链下同源（route param 经 middleware 写回 context），且 DB unique 约束兜底（R1 已处理 unique violation → 400）→ 非 error（后端侧细节，供参考）。

## 结论
**PASS — 0 error。** R4 掩码点结构与「服务端恒掩码」契约自洽；三门/深链/i18n/标记/类型全过；vitest 10/10。
