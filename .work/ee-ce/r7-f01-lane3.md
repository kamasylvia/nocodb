# r7-f01-lane3（第 7 轮，第 3 路：int + rev）

## 裁决

- int: PASS
- rev: PASS
- 总裁决: **PASS**

issues 列表：无

## rev 证据（commit 744d31618b，packages/nc-gui 范围）

- `packages/nc-gui/composables/useEeConfig.ts:163` — `blockUnique = computed(() => false)`，带 `// [CE-EE]` 标记，:607 导出。正确。
- `packages/nc-gui/components/smartsheet/column/EditOrAdd.vue:1505-1513` — Unique 开关 v-if 门由恒假 `showEEFeatures` 改为 `!blockUnique`，且保留 `isXcdbBase / !isVirtualCol / isUniqueConstraintSupportedType / sqlUi.isUniqueSupportedField / !isUUID / !isAutoNumber` 约束。正确。
- `EditOrAdd.vue:858-869` `unique` computed setter 的 `showUpgradeToUseUnique` 守卫 = useEeConfig.ts:326 CE no-op stub，setter 实际放行；`:1550` PaymentUpgradeBadge 门 `blockUnique && !unique` 在解锁态隐藏。一致。
- 测试 import `~/utils/uniqueConstraintHelpers` 解析正常；该文件与 `composables/useUniqueConstraintHelpers.ts` 来自上游 sync commit 69a29568c7（git ls-files 已跟踪），非 F01 引入缺失件。
- 实跑门：`cd packages/nc-gui && npx vitest run test/unique-constraint-helpers.test.ts` → **8 passed (8)**（47.9s）。
- working tree 并行 F07 WIP（`git status` 多文件改动态）核对：useEeConfig.ts 未提交 diff 仅动 `blockSnapshots`，`blockUnique` 未被并行改动破坏。

## int 证据（真实浏览器 camoufox-cli + API 对照，nocodb-dev）

- API 建 base `pjpae5zc706e7rq`（f06r7c_base）+ 表 `mogdg3ccbvkffxo`（f06r7c_t1，Name/Email/Qty 三列，unique 均空）。
- camoufox 登录 → grid → canvas 列头 (500,107) 合成 mousedown/mouseup/click → Edit 抽屉弹出：「Unique values only」NcSwitch 可见、状态 OFF（无 `ant-switch-checked` 类），与列 meta `unique: None` 一致；全程无 upgrade 弹窗/paywall 徽章。
- 开关切 ON（`ant-switch-checked` 出现）→ Update Field → `GET /api/v2/meta/tables/mogdg3ccbvkffxo` → `Name unique=True`（Email/Qty 不受影响）。持久化确认。
- 重开菜单：开关 checked=true 与 DB meta 一致（第二态核对）。
- 切回 OFF → Update Field → API → `Name unique=False`。往返闭环。
- 清理：表 DELETE 200、base DELETE 200、浏览器 tab 已关。

## 非阻断观察（不计 issue）

1. 本构建 NcSwitch（`button[role=switch]`）不输出 `aria-checked` 属性，状态由 `ant-switch-checked` 类承载——上游组件既有行为，非本 commit 引入；状态一致性已经类名+截图+API 三方核实。
2. 环境竞争（非 F01 缺陷，均实测定位根因）：
   - `users.service.ts:736-773` single-session enforcement 每次signin 轮换 `token_version`，5 路共用 f01e2e 互相踢下线（后端日志 `jwt.strategy.ts:39` "Token Expired" 佐证）。本路改用独占账号 f06r7c3@ce-ee.local（org-level-creator + workspace-level-creator）后稳定。
   - 测试窗口内 working tree 存在并行 F07 未提交改动致 rspack 反复重建，后端 :8080 一度下线（约 00:07-00:09），自动恢复后继续。
