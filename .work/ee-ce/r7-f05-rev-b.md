# r7-f05-rev-b — 前端代码复审（第 4 路，R7 最终收敛确认）

## PASS

证据（F05 前端终审，逐项实测核验）：

1. **Variables/index.vue API 一致性**
   - UI 调用 `/api/v2/meta/bases/:baseId/variables`（list/create）、`/:variableId`（get/patch/delete）= `packages/nocodb/src/controllers/base-variables.controller.ts:28-88` 路由完全一致。
   - list 响应兼容双形态 `res.data?.list ?? res.data ?? []`（service.list 返回数组）。
   - secret 编辑：`openEditModal` 单变量 GET 取真实值预填（service.get 不 mask）；list 响应经 `maskSecretVariable`（`baseVariableValidators.ts:53-63`，value/default_value 置 undefined）→ UI 按 type 显示 `••••••••` dots 分支，与 R4 注释一致。
   - key 不可变：编辑态 input disabled、PATCH 只发 `{value,description,type}`，后端 `service.update:98-100` 拒改 key，三层一致。

2. **三门**
   - `blockBaseVariables = computed(() => false)`（`useEeConfig.ts:357`，带 `[CE-EE]` 标记）。
   - `showUpgradeToUseBaseVariables` no-op（`useEeConfig.ts:359`）。
   - UI ACL `isUIAllowed('baseVariableList')`：sdk `rolePermissions` creator include 含全部 4 op、editor/commenter/viewer 不含（`test/base-variables-acl.test.ts` 实测 2/2 过）；后端 `utils/acl.ts:268-271` creator 段同步注册。

3. **深链**
   - 菜单项 `BaseSettingsMenu.vue:243-256`（gated `!blockBaseVariables && isUIAllowed('baseVariableList')`，带标记）→ slug `'variables'`（`settingsRouteUtils.ts` 双向映射齐）→ `pages/index/[typeOrId]/[baseId]/index/settings/[page].vue` → `View.vue:190-191` watcher（同款 gate）→ tab pane `View.vue:603-615`（`base.id` 就绪才渲染 → `onMounted(loadVariables)` 时 baseId 必非空，无竞态）。
   - 无权限角色直链深链：watcher 落 else → 回退 `collaborator` tab，行为合理。

4. **i18n**：组件用到的 20 个 key 经 node 脚本对 `lang/en.json` 逐个解析全部命中；`baseVariableDeleteDescription` 插值 token `{key}` 与传参一致；`zh-Hans.json` 含 10 处 baseVariable 同步。UPPER_SNAKE_CASE 提示文案有模型层依据（`BaseVariable.ts:18` `KEY_REGEX=/^[A-Z][A-Z0-9_]*$/` + `:216` insert 强制）。

5. **标记**：`[CE-EE]` 标记齐全——组件（L2/L165）、`View.vue`（L41/L602/L190）、`BaseSettingsMenu.vue`（L56/L245）、`useEeConfig.ts`（L356）；后端 controller/service/helpers/acl 均有标记。无 `<NcSpanHidden />` stub 残留。

6. **类型**：`BaseVariableValueType`（sdk `globals.ts:527` enum）、`BaseVariableType`（sdk `base-variable/index.ts`）存在且为 value export；script-setup 导入可直接用于 template 比较，`Partial<BaseVariableType>` 绑定无类型冲突。

7. **测试实跑**：`npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → **2 files / 10 tests 全过**（2+8），0 fail。

8. **找茬扫描**：无。已排查并排除的候选点：list 形态兼容、secret mask 分支、key 格式提示 vs 实际校验（模型层已强制）、深链无权限回退、baseId 挂载竞态（pane 由 `base.id` gate）、编辑态 type select disabled 而后端允许 type flip（UI 严于 API，非 error）。注：F05 相关文件当前在工作区未提交（`git status` M×3），属收尾 commit 流程状态，非代码问题。

issues 列表：无。
