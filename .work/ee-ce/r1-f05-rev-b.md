# r1 F05 前端复审（rev-b，独立第 4 路）

审查范围：F05 前端 diff（Variables/index.vue、useEeConfig.ts、View.vue、BaseSettingsMenu.vue、lib/acl.ts、lang/en.json、lang/zh-Hans.json）。

## issues

### I1 [error] NcInput 组件不存在，弹窗两个输入框不可用
- 文件：`packages/nc-gui/components/dashboard/settings/base/Variables/index.vue:181`（key 输入）、`:193`（value 输入）
- 证据：全仓唯一 `NcInput` 引用即本文件；`components/nc/` 下无 `Input.vue`（ls 确认，仅有 `NonNullableNumberInput.vue` 等）；`.nuxt/components.d.ts` 无 NcInput 注册；`nuxt.config.ts` unplugin-vue-components 只配 `AntDesignVueResolver`（只解析 A 前缀）+ `IconsResolver`，均解析不了 NcInput。运行时 Vue 解析失败 → 渲染为未知元素，`v-model:value` 失效 → 新建/编辑弹窗的 key、value 输入完全不可用。
- 建议：改用 `a-input`（同仓惯例，如 `components/webhook/index.vue`、`components/dlg/InviteDlg.vue`），或补建 `components/nc/Input.vue`。

### I2 [error] tab 与菜单门缺 isUIAllowed，非 creator 可见但 API 403
- 文件：`packages/nc-gui/components/project/View.vue:602`、`packages/nc-gui/components/dashboard/TreeView/Project/BaseSettingsMenu.vue:242`
- 证据：`lib/acl.ts:137-140` baseVariable* 仅授予 creator（注释即 "creator+ only"）。而 tab 门 `v-if="!blockBaseVariables && base.id && !isMobileMode"`、菜单门 `v-if="!isMobileMode && !blockBaseVariables"` 均无权限判定（blockBaseVariables 恒 false）→ editor/viewer/共享 base 访客可见 tab 与菜单，打开后 `loadVariables` 请求被后端 ACL 拒（controller `@Acl('baseVariableList')`）→ 报错 toast + 空列表误导（"No variables yet"）。
- 对照同文件惯例：mcp tab `isUIAllowed('manageMCP')`（View.vue:595）、skills tab `isUIAllowed('baseSkillList')`（View.vue:613）；菜单同（BaseSettingsMenu.vue:226、:238）。navigateToBaseSettings 守卫同理可加 isUIAllowed。
- 建议：两处门补 `isUIAllowed('baseVariableList', { roles: effectiveRoles })`（菜单处用 effectiveRoles，写法照 skills）。

### I3 [error] View.vue 深链门与 tab 门语义不一致（仍判 showEEFeatures）
- 文件：`packages/nc-gui/components/project/View.vue:190`
- 证据：`else if (newVal === 'variables' && showEEFeatures.value)`，本 fork `showEEFeatures = computed(() => false)`（useEeConfig.ts:384）恒 false；tab pane 已改判 `!blockBaseVariables`（恒 true）。结果：`?page=variables` query 深链落入 else 分支被强制弹回 collaborator，而 tab 本身可见 —— 门语义三处（tab、menu、query watch）不统一。
- 建议：改为 `newVal === 'variables' && !blockBaseVariables.value`（叠加 I2 的 isUIAllowed）。

### I4 [error] 删除确认框 {key} 插值丢失，不显示变量名
- 文件：`packages/nc-gui/components/dashboard/settings/base/Variables/index.vue:101`
- 证据：`t('msg.info.baseVariableDeleteDescription').replace('{key}', ...)`。vue-i18n 9.14.5 对未传命名参数的 `{key}` 占位符渲染为空串（用仓内 vue-i18n 实测：`t('m')` 输出 `"Variable  will be deleted."`），翻译产物里已无 `{key}` 字面量，`.replace` 不命中 → 确认框显示 "Variable  will be permanently deleted."，变量名丢失。
- 建议：`t('msg.info.baseVariableDeleteDescription', { key: variable.key || '' })`。

### I5 [minor] 字符串字面量赋给 string enum，TS 报错
- 文件：`packages/nc-gui/components/dashboard/settings/base/Variables/index.vue:20`、`:42`
- 证据：`ref<Partial<BaseVariableType>>({ ... type: 'text' })`，`BaseVariableValueType` 为 string enum（nocodb-sdk globals.ts:527-530）；TS 5.8.3 实测 `TS2322: Type '"text"' is not assignable to type 'E | undefined'`。仓内暂无 vue-tsc 门，不影响运行时，但 IDE 标红、将来接 typecheck 即挂。
- 建议：用 `BaseVariableValueType.TEXT`（从 nocodb-sdk 导入）。

### I6 [minor] View.vue 模板 hunk 缺 [CE-EE] 标记
- 文件：`packages/nc-gui/components/project/View.vue:602`
- 证据：TASK 要求"所有修改加 [CE-EE] 标记"；该文件仅 :41（script hunk）有标记，:602 被改的 v-if 行无标记。对照 BaseSettingsMenu.vue:242 把标记内联在被改 v-if 行上。上游合并回溯时此处无法识别为 F05 改动。

## 复核过、判非 issue 的点（记录防重复报）
- 竞态：`onMounted(loadVariables)` 无 watch —— 核验 `useBase().base`（store/base.ts:55）与 `useBases().openedProject`（store/bases.ts:49）同源于 `bases` Map（store/base.ts loadProject → basesStore.loadProject → bases.value.set），tab pane `v-if="base.id"` 与组件内 `openedProject?.id` 同 tick 翻转；a-tab-pane 惰性挂载（激活时才 mount），挂载时 baseId 必已就绪。非 issue。
- 自动导入：`message`/`Modal`（ant-design-vue，.nuxt/imports.d.ts:39）、`extractSdkResponseErrorMsg`（:203）、`useBases`（:294）、useNuxtApp/storeToRefs/onMounted 均 in scope；`Modal.confirm`（expanded-form/index.vue 同款）、`a-textarea`（webhook/index.vue 同款）、NcModal `v-model:visible`+`size="small"`、NcButton `type="text"`+`size="small"`+`:loading`、NcSelect `options` 经 attr 透传给 a-select、图标 plus/eye/edit/delete 均有同款用法。
- i18n：组件引用的 20 个键在 en.json 与 zh-Hans.json 全部落位（脚本逐一核验）；labels.key/value/type 为本次新增且落 `labels` 节；title.baseVariables 为存量；其余语言 fallbackLocale='en'（plugins/a.i18n.ts:10）。
- 类型：`BaseVariableType` 从 nocodb-sdk 导出链完整（src/lib/index.ts:24 → build/module/lib/base-variable/index.d.ts）。
- 后端路由与前端调用路径逐一匹配（controller GET/POST/PATCH/DELETE，含 :variableId 子路径）；service list 返回裸数组，`res.data?.list ?? res.data ?? []` 兼容。
- 升级徽章：payment/upgrade/Badge.vue 本身是 stub（NcSpanHidden），菜单 `feature-enabled-callback` 无升级弹窗风险，符合验收项。
