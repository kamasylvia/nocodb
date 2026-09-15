# r8-f01-lane3（第 8 轮收敛确认，第 3 路：集成实测 + 代码复审）

## rev — PASS

- `packages/nc-gui/composables/useEeConfig.ts:163` `blockUnique = computed(() => false)`，带 `// [CE-EE] F01` 注释，与 commit 744d3161 一致；工作区后续 diff 仅 F05/F07 追加，未回改 F01 行。
- `packages/nc-gui/components/smartsheet/column/EditOrAdd.vue:1512` gate 由 `showEEFeatures` 改 `!blockUnique`（含 `[CE-EE]` 行尾注释），与 commit 一致。toggle 显示条件组合完整：`isXcdbBase(source_id)` + 非虚拟列 + `isUniqueConstraintSupportedType` + `sqlUi.isUniqueSupportedField !== false` + 非 UUID + 非 AutoNumber。
- `showUpgradeToUseUnique`（useEeConfig.ts:326）为 no-op，unique setter（EditOrAdd.vue:858-868）不被拦截；`PaymentUpgradeBadge` 渲染条件 `blockUnique && !unique`（:1551），blockUnique=false 下不渲染——无 paywall 残留。
- i18n key 存在：`lang/en.json:2626` `labels.uniqueValuesOnly`、`:5340` `msg.info.uniqueConstraintTooltip`。
- `utils/uniqueConstraintHelpers.ts` 正确 re-export SDK 实现（`packages/nocodb-sdk/src/lib/uniqueConstraintHelpers.ts`，`UNIQUE_CONSTRAINT_SUPPORTED_TYPES` / `isUniqueConstraintSupportedType`），测试引用链完整。
- 实跑门：`cd packages/nc-gui && npx vitest run test/unique-constraint-helpers.test.ts` → **8/8 pass**（Test Files 1 passed, Tests 8 passed）。

## int — PASS

环境说明（非 F01 缺陷）：多路并行共用 f01e2e 账号，每次 login 旋转 `token_version`（users.service.ts single-session enforcement），导致 JWT 秒级互相踢（DB 实测 1.5s 内 token_version 变更、curl signin 后立即 401）。API 对照改经 account-wide API token（`xc-token`，AuthTokenStrategy 对 `is_api_token` 短路 token_version 校验）完成，浏览器侧经 camoufox 重登完成。属测试碰撞干扰，与本 commit 无关（上游既有行为）。

1. API 建 base `f06r8c_base`（provf1cdwwu680w，pg NC-DB source，is_meta=false）+ 表 `f06r8c_t1`（Name=SingleLineText pv，Qty=Number）+ 2 行数据；初始 Name 列 `unique=null`。
2. camoufox（session lane3）登录 → 纯点击导航进 base → grid 渲染正常（截图 /tmp/f01lane3_grid.png：2 records 可见）。
3. canvas 列头合成事件点击（elementFromPoint + mousedown/mouseup/click dispatch）→ EditOrAdd 菜单打开（截图 /tmp/f01lane3_colmenu.png）。
4. **「Unique values only」开关可见，初始 off，与 API meta `unique=null` 一致；无升级 badge。**
5. 开关切 on（`aria-checked=true`）→ Update Field → API 复核 `unique=true` 持久化 ✓。
6. 重开列菜单，开关 on，与 meta `true` 一致 ✓；切回 off → Update Field → API `unique=false` ✓；pg_indexes 确认 Name 列唯一索引已移除（仅剩 pkey/order/deleted 索引，无 DDL 残留）✓。
7. 补充 API DDL 证据：PATCH `/api/v2/meta/columns/{colId}` `{"unique":true}` → `pg_indexes` 出现 `uk_provf1cdwwu680w_mc1bvepopge63xk_c91kvl15g1bgpz1`（partial unique index on "Name" WHERE `__nc_deleted`）✓。
8. 端到端行为：on 态插入重复值 → `400 FIELD_UNIQUE_CONSTRAINT_VIOLATION`，`fieldName=Name`、`value='r8-lane3-a'`，结构化错误正确 ✓。
9. 清理：unique 恢复 false、base DELETE 200、临时 API token 行已删、camoufox 会话已关、/tmp 凭证临时文件已清 ✓。

## 总裁决

int PASS + rev PASS → **PASS**
