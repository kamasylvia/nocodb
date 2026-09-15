# r4-f05-rev-b — F05 前端第 4 轮收敛终审(独立第 4 路)

审查范围:F05 前端 diff(working tree):`Variables/index.vue`、`View.vue`、`BaseSettingsMenu.vue`、`useEeConfig.ts`、`lib/acl.ts`、`lang/en.json`、`lang/zh-Hans.json`、`test/base-variables-acl.test.ts`;契约对照后端 `base-variables.controller.ts` / `base-variables.service.ts` / `baseVariableValidators.ts` / `models/BaseVariable.ts`。隔离声明:未读任何 r*.md 历史报告。

## 实测

- `npx vitest run --config test/vite.config.ts test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → **2 files / 10 tests 全过**(2+8)。

## 核对结论(无 error 项)

- **三门一致性**:gate `blockBaseVariables = false`(useEeConfig.ts:357,[CE-EE] 标记)+ ACL(creator include 4 个 baseVariable* op,lib/acl.ts:136-141)+ UI 菜单/tab 双条件 `!blockBaseVariables && isUIAllowed('baseVariableList')`(BaseSettingsMenu.vue:243 / View.vue:604)一致。
- **深链**:hash watch(View.vue:190)→ `projectPageTab='variables'`;slug 映射 `variables→variables` 在 `utils/settingsRouteUtils.ts:24`(上游 sync 文件,单源映射,正反向生成);BaseSettingsMenu.vue:57 防御性 gating 保留。
- **i18n 逐键**:en.json 与 zh-Hans.json 全部 10 个新键嵌套位置逐一验证一致(msg.info ×5 / msg.error ×1 / msg.success ×3 / title ×1;labels.key/value/type 复用+新增,description 沿用既有);无重复键;其余 locale 走 en fallback(上游惯例)。
- **[CE-EE] 标记**:全部 fork 修改点均有标记;`useBaseVariables.ts`、`settingsRouteUtils.ts` 经 git 确认来自上游 "chore: sync"(mertmit),非 fork 新增,无需标记。
- **契约**:前端 5 个 API 调用(list/get/create/update/delete)路径与 controller 6 路由逐一匹配;list 响应数组形状(`res.data?.list ?? res.data`)兼容;secret 单 get 预取→controller get 返回未 mask 单对象,与 `editingVariable = { ...res.data }` 匹配;PATCH 部分更新语义与 service R2 实现匹配;key 格式 UPPER_SNAKE_CASE 由 model 层 KEY_REGEX(BaseVariable.ts:213-218)强制,与 UI 文案一致;unique 冲突 400 兜底在位。
- **运行时/响应式**:`baseId` 空 guard(onMounted)、openEditModal secret 预取失败 early-return 后 `isEditing` 残留被 openCreateModal/openEditModal 重置(无泄漏路径);editingVariable 每次 open 重置;isSaving/onOk async loading 正常。
- **类型**:`BaseVariableType`/`BaseVariableValueType` 经 sdk 导出链(src/index.ts→lib/index.ts:9,24→globals.ts:527 / base-variable/index.ts:6)可达。

## Issues

- `packages/nc-gui/components/dashboard/settings/base/Variables/index.vue:165`:secret 变量列表掩码永不显示——后端 `BaseVariablesService.list` 对 secret 行无条件 `maskSecretVariable`(value 置 undefined,JSON 序列化剔除),而模板 `variable.value ? '••••••••' : ''` 依赖 value 真值,恒 falsy → 恒渲染空串,'••••••••' 分支为死代码,用户无法从列表区分 secret 是否已设值。建议:secret 分支按 `variable.type === SECRET` 恒显掩码点(如 `••••••••`),不依赖被 mask 的 value 字段。

## 裁决

1 issue(minor,UI 展示;无数据泄露/崩溃/权限问题)。其余全项 PASS。
