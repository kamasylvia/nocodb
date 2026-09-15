# r3-f05-rev-b — F05 前端第 3 轮终审（独立第 4 路）

## issues

- packages/nc-gui（F05 前端 diff 整体）:无对应前端 vitest 单测:TASK.md 实现阶段要求「补/改单测（前端 vitest）」,但 `packages/nc-gui/test/` 及全 nc-gui 无任何 baseVariable / blockBaseVariables / baseVariableList 相关 test（`find packages/nc-gui -name "*.test.ts" | xargs grep -ln "baseVariable\|baseVariableList"` 返回空;门禁 useEeConfig gate 与 Variables UI 均无测试）:建议至少补 1 个 gating/acl 或 i18n 键存的轻量 vitest,或在 GOAL-STATE 明示豁免理由。

## 已核无 error 项（证据摘要）

1. **Variables/index.vue 运行时终审**:两处 open 路径均整体重置 editingVariable/isEditing,无 modal 状态残留;isSaving + NcButton :loading（antd Button loading 态禁点）防并发保存;保存失败 modal 保持开启 + toast;secret 编辑预览走 GET single,失败早退不开 modal;删除走 Modal.confirm（message/Modal 均经 nuxt.config imports 注册,antd 组件经 AntDesignVueResolver）;NcSelect `:disabled="isEditing"` 经 attrs fallthrough 覆盖内层 `:disabled="loading"`（Vue mergeProps 语义,`:options` fallthrough 有 json-exporter 先例）;PATCH 只发 value/description/type,key 不回传（与后端 key 不可变语义一致）;list 契约 `res.data?.list ?? res.data` 兼容后端裸数组返回。
2. **三门 + 深链**:View.vue template(a-tab-pane v-if) / View.vue watch(roles 加载后判定,非授权回落 collaborator) / BaseSettingsMenu.vue 菜单项,三处均为 `!blockBaseVariables && isUIAllowed('baseVariableList')` 一致;路由 slug 'variables' 在 settingsRouteUtils.ts baseSettingsTabToSlug 已映射;acl.ts baseVariable* 置于 ProjectRoles.CREATOR include,经 role-scope cascade 继承至 OWNER、EDITOR 及以下拒绝,与后端 utils/acl.ts:268 及 controller @Acl 命名一致;blockBaseVariables 已解 gate(false)。
3. **i18n 逐键双向**:组件引用的 19 个键(title.baseVariables、msg.info.baseVariables*5、msg.error.baseVariableKeyRequired、msg.success.baseVariable*3、labels.key/value/type、general.add/edit/save/create/cancel/delete)在 en.json 与 zh-Hans.json 全部可解析且为字符串;`{key}` 命名参数两语言一致;精确重复键扫描(整文件)两文件均 0 dup。
4. **[CE-EE] 标记**:全部非 JSON 变更 hunk 均带标记(useEeConfig.ts / lib/acl.ts / View.vue ×3 处 / BaseSettingsMenu.vue ×2 处 / Variables/index.vue 新文件头标记);lang JSON 文件无法承载注释,按惯例豁免;无漏标功能行。
5. **类型自扫**:`: any` 仅 4 处 `catch (e: any)`,与代码库惯例一致(全 components 159 处);BaseVariableValueType 以值导入(nocodb-sdk 经 lib/index → lib/globals 运行时导出,TEXT/SECRET 枚举成员与后端 ALLOWED_VARIABLE_TYPES 一致),BaseVariableType 以 type 导入,接口字段(id/key/value/description/type)与后端 service 序列化契约一致;无其他 any 滥用。
