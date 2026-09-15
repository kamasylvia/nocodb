# r1 F01 前端复审报告（第 3 路）

审查对象：F01「Unique values only」未提交 diff（EditOrAdd.vue / useEeConfig.ts / jest.config.js / 两个新测试）。方法：源码逐行核对 + blockUnique 全仓 grep + 两组测试实测运行。

## 1. 改动正确性 — PASS

- `packages/nc-gui/components/smartsheet/column/EditOrAdd.vue:1505-1513`：v-if 仅尾条件替换，其余 6 条件逐字保留——`isXcdbBase(meta?.source_id)`（1506）、`!isVirtualCol`（1507）、`isUniqueConstraintSupportedType`（1508）、`sqlUi?.isUniqueSupportedField?.(formState.uidt) !== false`（1509）、`!isUUID`（1510）、`!isAutoNumber`（1511）。语义替换等价：原 `showEEFeatures`（CE 恒 false→整块隐藏）→ `!blockUnique`（fork 恒 true→按类型条件显示），即 F01 意图。
- blockUnique 全仓消费点（grep packages 全树，含 ee/；ee overlay 实测不存在——test/vite.config.ts `hasEeSources=false` 运行日志证实）：仅 `useEeConfig.ts:163`（定义）、`useEeConfig.ts:605`（return）、`EditOrAdd.vue:129`（解构）、`:1512`（本改动）、`:1551`（badge v-if）。无其它意外激活面。

## 2. 回归风险 — PASS

- `EditOrAdd.vue:861` setter guard：`showUpgradeToUseUnique` 在 CE stub 为 `(..._args: any[]) => {}`（`useEeConfig.ts:326`），返回 `undefined`（falsy）→ guard 不触发 → `formState.value.unique = value`（866）正常落值。toggle 置 true 无阻碍。
- `PaymentUpgradeBadge`（1550-1557）`v-if="blockUnique && !unique"`：blockUnique 恒 false → 永不渲染。组件实体 `components/payment/upgrade/Badge.vue` 存在（Nuxt 目录前缀自动导入），且 v-if false 不实例化，CE 兼容无风险。`PlanFeatureTypes.FEATURE_UNIQUE` 存在（`nocodb-sdk/src/lib/payment/index.ts:105`），`PlanFeatureTypes` 已 import（EditOrAdd.vue:5）。

## 3. 类型与 lint — PASS

- `useEeConfig.ts:163` `computed(() => false)` 布尔 computed，类型正确。
- `showEEFeatures` 在 EditOrAdd.vue 仍有 4 个消费点（273/275/291/294，UUID/AutoNumber/Colour/AI beta 门控），解构（132）未悬空，无 unused。
- 模板引用（$t keys、canEnableUniqueConstraint、onMouseOverUniqueValuesInfoIcon、useUniqueConstraintHelpers 于 composable:7 导出）均可达。

## 4. 单测质量 — PASS（实测核验，非轻信）

- 后端 `packages/nocodb/src/helpers/uniqueConstraintHelpers.Fork.spec.ts`：jest 实跑 **11/11 passed**。断言对照 `src/helpers/uniqueConstraintHelpers.ts` 真值：LongText+richMode 拒绝（helper:51 经 SDK 列表不含 LongText）✓；UUID+cdf 例外分支 `uidt !== UITypes.UUID`（helper:64）✓；normalizeValueForUniqueCheck trim/lowercase 仅 4 文本类型（helper:85-93）、Number 原样 ✓。
- 前端 `packages/nc-gui/test/unique-constraint-helpers.test.ts`：vitest 实跑 **8/8 passed**。断言对照 SDK `packages/nocodb-sdk/src/lib/uniqueConstraintHelpers.ts`：LongText 不在 `UNIQUE_CONSTRAINT_SUPPORTED_TYPES`（sdk:6-19，仅 12 类型）→ plain 与 rich 两模式断言 false 均真 ✓；`cdf:''` 放行（utils/uniqueConstraintHelpers.ts:31 空串跳过）✓。
- pg SqlUi optional 语义：SDK 仅 MssqlUi.ts:936 / OracleUi.ts:953 实现 `isUniqueSupportedField`，`SqlUI.types.ts:72` 声明 optional（`isUniqueSupportedField?(uidt)`）→ 前端 1509 `?. !== false` 与后端 helper:42 `?. === false` 语义一致：pg 缺方法 → undefined → 放行，由 SDK 类型列表兜底；后端测试 `source={type:'pg'}` 三例（24-56 行）恰好覆盖该路径。
- `packages/nocodb/jest.config.js`：testRegex 增 Fork 桶，新 spec 位于 rootDir=src/helpers 下实测被匹配执行；原 `(Integration|Source)` 桶不回归。

## 5. i18n — PASS

- `lang/en.json:2626` `"uniqueValuesOnly": "Unique values only"`、`en.json:5338` `"uniqueConstraintTooltip"`；`lang/zh-Hans.json:2007` `"仅唯一值"`、`:3721` tooltip 均存在；grep 证实全部 40 个语言文件含 uniqueValuesOnly。

## 6. 上游合并安全 — PASS（附 1 条范围观察，非 F01 缺陷）

- `// [CE-EE]` 标记 5 处齐全：EditOrAdd.vue:1512、useEeConfig.ts:161-162、jest.config.js:8-9、uniqueConstraintHelpers.Fork.spec.ts:8-9、nc-gui test:4-5。改动最小：两处单行条件替换 + 注释、testRegex 单处扩桶，无多余重排。

### 观察（范围一致性，非 F01 bug）

- `packages/nocodb-sdk/src/lib/Api.ts`（:位置=整文件多处）:问题=工作树含大量非 F01 未提交改动（V3 fields 404 注释、`IntegrationsType.Channel`、`TableType.fk_base_section_id`、`UserType.blocked/blocked_reason`、`UserCommentNotificationPreferenceType.preference→preferences` 改名、`ScriptType/WorkflowType.fk_automation_section_id`、userId 参数），无 `[CE-EE]` 标记，不在 F01 文件清单:建议=orchestrator 确认归属其它任务，提交时与 F01 拆分；前端消费面已核——nc-gui 未消费 SDK `UserCommentNotificationPreferenceType`（`useRowComments.ts:346` 用本地类型），无前端破坏。

## 裁决

**PASS**（6/6 项 PASS，无 F01 bug/安全/一致性问题；1 条超范围文件归属观察转 orchestrator）。
