# r2-f05-rev-b.md — F05 前端复审 第 2 轮（独立第 4 路）

## issues

1. `packages/nc-gui/components/project/View.vue:190` — 深链 watch 门行（`else if (newVal === 'variables' && !blockBaseVariables.value && isUIAllowed('baseVariableList'))`）为本 fork 新增逻辑行，缺行尾 `/* [CE-EE] F05 */` 标记。同文件 line 41（destructure）与 line 602（tab 块注释）已有标记，该行漏。违反仓根 AGENTS.md「所有本 fork 的修改处加行尾注释」约定。建议：行尾补 `/* [CE-EE] F05 */`。
2. `packages/nc-gui/components/dashboard/TreeView/Project/BaseSettingsMenu.vue:56-58` — `navigateToBaseSettings` 内 `if (page === 'variables' && blockBaseVariables.value)` 守卫块为本 fork 新增，同样缺 `// [CE-EE]` 标记。建议：该行行尾补标记。

## 逐项核查（非 issue 证据，简录）

- **Variables/index.vue 用法一致性**：`a-input` / `a-input-password` / `a-textarea` 与既有用法（WebhookV2.vue、AirtableImport.vue、SharePage.vue 等）一致；`Modal.confirm`、`message` 经 vite.config.ts 显式 auto-import（line 404-407 `Modal`/`message` from ant-design-vue），与 useTableNew.ts:220、expanded-form/index.vue:651 惯例一致；`NcSelect`（v-model:value + {label,value} options + :disabled）与 CreateBase.vue 同款；`extractSdkResponseErrorMsg` 为 utils/errorUtils.ts:3 auto-import 导出。
- **openEditModal**：secret 分支先单条 GET 预填真实 value，失败即 return 不开 modal；编辑态 key input 与 type select 均 `:disabled="isEditing"`（任务点「编辑时 type 下拉 disabled」满足）；modal 内 value 输入按 type 动态切 a-input-password/a-input。
- **保存 payload**：PATCH 仅送 `{ value, description, type }`（key 编辑态禁改不入 payload）✓；POST 送 `{ key(trim), value, description, type }` ✓。与 controller `@Patch/@Post @Body Partial<BaseVariableType>` 匹配。
- **data-testid**：add / row-{key} / edit-{key} / delete-{key} / key-input / value-input / type-select / description-input / save / proj-view-tab__variables / menu base-variables，全覆盖（f05-e2e.sh 为纯 API 脚本，无 testid 依赖）。
- **三门一致性**：语义统一为 `!blockBaseVariables && isUIAllowed('baseVariableList')` — View.vue:604 tab 门、View.vue:190 深链 watch 门（无权限深链落 else → collaborator，无泄露）、BaseSettingsMenu.vue:242 菜单项门均一致。navigateToBaseSettings:56 守卫仅查 `blockBaseVariables`，与上游 permissions/snapshots 守卫模式一致（入口已受菜单 v-if 双门 + View watch 门兜底），非不一致。`settingsTabToSlug`/`baseSettingsSlugToTab` 含 `'variables': 'variables'`（utils/settingsRouteUtils.ts:22,40）✓。
- **权限字符串**：`baseVariableList` 前端 lib/acl.ts:137、SDK internalBatch.ts:88、后端 utils/acl.ts:268、controller @Acl 全链存在 ✓。
- **后端路由匹配**：GET list / GET 单条 / POST / PATCH / DELETE `/api/v2/meta/bases/:baseId/variables[/:variableId]` 与前端 `$api.instance` 调用逐一匹配（controller line 28-88）✓。list 响应 `res.data?.list ?? res.data ?? []` 兼容裸数组与 {list} 两种形态 ✓。
- **i18n**：组件全部 20 个 $t/t 键逐键 grep 验证，en.json 与 zh-Hans.json 双语均存在（含 `baseVariableDeleteDescription` 的 `{key}` 插值参数，en.json:5796 / zh-Hans.json:3989）；general.*/labels.*/title.baseVariables 嵌套键经 jq 验证 ✓。
- **类型**：项目无 vue-tsc 依赖（package.json 无、node_modules/.bin 无），npx 缓存版 vue-tsc 与 TS 导出不兼容崩溃，无法跑全量 — 改以人工核对替代：SDK dist（build/main，2026-09-12 04:13 构建）导出 `BaseVariableValueType`（globals.ts:527，TEXT/SECRET）与 `BaseVariableType`（base-variable/index.ts:6，type?: BaseVariableValueType）；`ref<Partial<BaseVariableType>>` 初始值与两处重赋值（`{...res.data}` / `{...variable}`）字段/类型匹配；NcSelect options value 用 enum 成员。无类型错配。
- **[CE-EE] 标记**：Variables/index.vue:2（整文件头标记）✓、View.vue:41/602 ✓、BaseSettingsMenu.vue:242 ✓；缺口仅上述 issues 1/2 两处。

## 结论

2 个低危一致性问题（均为 [CE-EE] 行尾标记缺失，无功能 bug、无数据/权限风险）。三门语义统一、i18n 全键双语齐、payload 与后端契约匹配、类型无错配。
