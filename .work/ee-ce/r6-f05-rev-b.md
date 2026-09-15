# r6-f05-rev-b — F05 前端第 6 轮终审（独立第 4 路）

## PASS

### 审查覆盖与证据

**1. Variables/index.vue 终审**（`packages/nc-gui/components/dashboard/settings/base/Variables/index.vue`）
- CRUD 端点与后端 controller 逐一对齐（`packages/nocodb/src/controllers/base-variables.controller.ts:28-88`）：GET/POST `/api/v2/meta/bases/:baseId/variables`、GET/PATCH/DELETE `.../variables/:variableId`，前端 5 处调用 URL 全部匹配。
- list 响应：service 返回裸数组（`base-variables.service.ts:23-29`），前端 `res.data?.list ?? res.data ?? []`（index.vue:33）正确兜底。
- secret 编辑流：list 响应服务端 strip secret（`baseVariableValidators.ts:53-62` maskSecretVariable 置 `value: undefined`），前端按 type 显示 `••••••••`（index.vue:162-169，R4 标记与实现一致），编辑时单条 GET 取真实值预填（index.vue:56-65）。
- PATCH body `{ value, description, type }`：key 不可变由后端强制（`base-variables.service.ts:98-100`），前端 UI 同步禁用 key/type 输入（`:disabled="isEditing"`）。
- key 格式：模型 `KEY_REGEX` 强制 UPPER_SNAKE_CASE（`BaseVariable.ts:215-218`），与 i18n hint「UPPER_SNAKE_CASE only」文案一致。

**2. 三门**
- ① plan gate：`blockBaseVariables = computed(() => false)` + `showUpgradeToUseBaseVariables` no-op（`composables/useEeConfig.ts:356-359`），与 F01 `blockUnique=false` 同款「fork 已实现、去付费墙」注释模式，已导出（:628-629）。
- ② ACL gate：前端 `lib/acl.ts:137-140` CREATOR include 含 baseVariableList/Create/Update/Delete 四权限；role-scope 级联（acl.ts:305-320）使 base OWNER 继承 CREATOR（base scope 次序 NO_ACCESS→VIEWER→COMMENTER→EDITOR→CREATOR→OWNER）；EDITOR/COMMENTER/VIEWER include 均无。后端 exclude-based creator/owner 语义自动放行（`extract-ids.middleware.ts:1247-1257`：exclude 角色对非排除权限一律允许），editor 系 include 无 → 前后端一致。sdk `internalBatch.ts:88` 亦注册 baseVariableList。
- ③ stub 替换：`DashboardSettingsBaseVariables` 已注册（`.nuxt/components.d.ts:271` → Variables/index.vue）；挂载点 View.vue:604 与 BaseSettingsMenu.vue:243 均为三重 gate `!blockBaseVariables && isUIAllowed('baseVariableList')`（+ `base.id && !isMobileMode`）；grep 全量 `NcSpanHidden` 残留文件无任何 variable 相关组件。

**3. 深链**
- `settingsRouteUtils.ts:24` baseSettingsTabToSlug / :48 baseSettingsSlugToTab 双向含 `'variables'`。
- 路径深链：`/{ws}/{base}/settings/variables` → `pages/index/[typeOrId]/[baseId]/index/settings/[page].vue` → `baseSettingsSlugToTab` → ProjectView `:tab` → props.tab watch（View.vue:280-290, immediate）+ onMounted（:321-326）设 projectPageTab。
- query 深链分支：View.vue:190 `newVal === 'variables' && !blockBaseVariables && isUIAllowed('baseVariableList')`。
- 标题映射：settingsPageTitle `'variables': t('title.baseVariables')`（View.vue:238）。

**4. i18n**
- 新增 10 key（msg.info.baseVariablesSubtitle/Empty/KeyFormat/DeleteTitle/DeleteDescription、msg.error.baseVariableKeyRequired、msg.success.baseVariableCreated/Updated/Deleted、title.baseVariables）en.json 与 zh-Hans.json 双双齐备；labels.key/value/type/description 与 general.* 既有 key 齐备。其余 locale 缺 key 走 `fallbackLocale: 'en'`（`plugins/a.i18n.ts:10`），合规。

**5. 类型**
- `BaseVariableValueType`（TEXT/SECRET）与 `BaseVariableType` 定义于 `nocodb-sdk/src/lib/globals.ts:527-531`、`base-variable/index.ts:6-20`，经 `lib/index.ts:24` 导出；前端 import 与 sdk 字段（key/value/description/type/id）对齐，无漂移。

**6. 测试实跑**
```
cd packages/nc-gui && npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts
✓ test/base-variables-acl.test.ts (2 tests)
✓ test/unique-constraint-helpers.test.ts (8 tests)
Test Files  2 passed (2)   Tests  10 passed (10)
```

**7. 找茬扫描**
无。以下候选项经核实均非 F05 error：
- 深链至 variables 但无权限/移动端时 a-tabs 无匹配 pane 呈空白 —— mcp/syncs/integrations/skills 全部 settings tab 共有的既有模式，非 F05 引入。
- `composables/useBaseVariables.ts` 为 CE 上游既有 no-op stub，F05 UI 直调 `$api.instance` 未依赖它，无功能影响。
