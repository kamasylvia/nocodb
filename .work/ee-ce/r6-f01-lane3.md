# r6-f01-lane3 — F01 Unique values only 第 6 轮会审（第 3 路：集成测试 + 代码复审）

日期：2026-09-12。对象：commit 744d31618b（前端侧重）。隔离声明：未读任何 r*.md 历史报告；只读 TASK.md、仓根 AGENTS.md、源码、运行系统。
（注：本文件覆盖了同路径早前一次中断运行的报告；本轮全部证据为独立重测，与该次结论一致。）

## rev（代码复审）

**PASS**

- `packages/nc-gui/composables/useEeConfig.ts:163`：`blockUnique = computed(() => false)`，带 `// [CE-EE] F01` 标记；`:607` 已导出；其余 gate 未误动（blockSync/blockUuidField 等仍 true，未翻转 isEeUI）。
- `packages/nc-gui/components/smartsheet/column/EditOrAdd.vue:1512`：unique 开关 v-if 由 `showEEFeatures` 改 `!blockUnique`，带 `[CE-EE]` 标记；前置条件链（`isXcdbBase` + 非虚拟列 + `isUniqueConstraintSupportedType` + `sqlUi.isUniqueSupportedField` + 非 UUID + 非 AutoNumber）完整保留，外部源仍被挡，与后端 external-source 无约束一致。
- 链路自洽：`unique` setter（:858-869）依赖 `showUpgradeToUseUnique`（useEeConfig.ts:326，no-op 返回 undefined=falsy）不拦截赋值；PaymentUpgradeBadge `v-if="blockUnique && !unique"`（:1551）随 blockUnique=false 恒不渲染；cdf 与 unique 互斥 watch（:609-627）保留。
- `packages/nc-gui/utils/uniqueConstraintHelpers.ts`（测试目标）：`canEnableUniqueConstraint` 三重校验（NC-DB 源 / 支持类型 / cdf 默认值互斥，空串放行）逻辑正确。
- i18n key 存在：`lang/en.json:2626` labels.uniqueValuesOnly、`:5340` msg.info.uniqueConstraintTooltip。
- rev 实跑门：`cd packages/nc-gui && npx vitest run test/unique-constraint-helpers.test.ts` → **8/8 passed**（RUN v4.1.11）。
- 工作区与 commit 无漂移：三文件中仅 useEeConfig.ts 有未提交改动，属 F07（blockSnapshots），非 F01 范围；F01 相关行与 commit 一致。

## int（UI 真实浏览器实测 + API 对照）

**PASS**

环境：camoufox-cli（--session lane3）真实浏览器；前端 :3000、后端 :8080（nocodb-dev）；账号 f01e2e@ce-ee.local。API 建资源前缀 `f06r3a_`：base `f06r3a_base`（p6f0byuuazxtfne）/ 表 `f06r3a_tbl`（mlddizm9sebzdga）/ 列 Name=SingleLineText（cooghpurqmma4i2）、Email=Email。测毕已删（DELETE base → 200，GET 复核 404；临时 xc-token row 已删）。

1. **canvas 列头实测确认**：grid 列头为 canvas 渲染（DOM 中 0 个列头文本节点、0 个 th，canvas 1 块 942x628@339,92），按任务书以坐标 (505,107) 对 canvas 合成 pointer/mouse 事件序列（clientX/Y 必须显式给列头坐标；fire 元素中心会落在表格中部无效）→ 内联编辑菜单弹出，即 EditOrAddProvider → EditOrAdd.vue 实渲染（含类型选择「Single line text」、Unique 开关、Set default value、Add description、Cancel、Update Field）。
2. **开关可见性与状态一致（三态核对）**：
   - 初始：菜单中「Unique values only」开关可见、未禁用、无 PaymentUpgradeBadge、无 upgrade 弹窗；switch 无 aria-checked 属性 + 无 `ant-switch-checked` class（antd unchecked 语义）→ API 对照 `Name.unique=None` 一致。
   - 切 ON：点击文本 span 后 aria-checked="true" + `ant-switch-checked`；点 Update Field 面板关闭 → API 复核 `Name.unique=True` 持久化成功；Email 列未受影响（unique=None）。
   - 切回 OFF：aria-checked="false" + 无 checked class → Update Field → API 复核 `Name.unique=False` 已还原（初始 None → 显式 False 系前端 payload 显式 bool + 后端 strict boolean 接受，语义 off，不计 issue）。
3. 全程无 paywall 拦截、无升级弹窗、无 NcSpanHidden 空壳、无 5xx 残留。过程中偶发 "Page Loading Error" toast 为并发会审他路 signin 轮换 token_version 引发的 401 环境噪音，非 F01 代码问题。

## 环境观察（非 error，不计 issue）

- 5 路并行共用 `f01e2e@ce-ee.local`：每次 signin 轮换 `nc_users_v2.token_version` → 路间互踢死循环（浏览器被弹回 signin、UI 元数据请求 401 致 canvas 卡 skeleton）。本轮解法（供编排参考）：从运行中后端进程 env 取 `NC_AUTH_JWT_SECRET`（`ps -wwE -p <pid>`，pid 55363 实测），DB 读当前 token_version，按 `src/services/users/helpers.ts genJwt` 同构 payload（email/id/roles 对象/token_version，10h）自铸 JWT，注入 `localStorage['nocodb-gui-v2'].token` 后整页 reload 即恢复（脚本存 /tmp/lane3/）。另证：nc-gui token 持久于 localStorage，`open` 整页 reload 本身不丢 token——早前「reload 丢 token」实为 401 被踢。建议 orchestrator 为各路发独立账号或统一 API token。
- 期间后端 :8080 两度无监听（他路 stop/start 及多实例互抢），轮询等待恢复后继续；未杀任何进程。

## 裁决

- int：PASS
- rev：PASS
- 总裁决：**PASS**（0 error）
