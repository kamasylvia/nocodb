# r5-f01-rev-a（独立第 3 路：改动面代码复审, R5）

隔离声明：未读任何 r*.md 归档；只读 TASK.md / 仓根 AGENTS.md / 源码 / git diff。

## 实跑证据

| 项 | 命令 | 结果 |
|---|---|---|
| tsc | `cd packages/nocodb && npx tsc --noEmit` | **exit 0，0 error**（log: `.work/ee-ce/r5-tsc-rev-a.log`） |
| jest | `npx jest uniqueConstraint` | **14/14 passed**（Suite: uniqueConstraintHelpers.Fork.spec.ts，validateUniqueConstraint 9 + normalizeFlag 2 + normalizeValue 3） |
| vitest | `npx vitest run --config test/vite.config.ts test/unique-constraint-helpers.test.ts` | **8/8 passed**（canEnableUniqueConstraint 5 + isUniqueConstraintSupportedType 3） |

## R4 修复核验

1. **sqlite 双值判定** ✓ — `uniqueConstraintHelpers.ts`：`sourceType === 'sqlite' || sourceType === 'sqlite3'`；实测 `DriverClient.SQLITE = 'sqlite3'`（`src/utils/nc-config/constants.ts:79`）、`SqlUiFactory` 仅认 `'sqlite3'`（`nocodb-sdk/src/lib/sqlUi/SqlUiFactory.ts:33`）；类型缺口（`Source['type']: DriverClient` 不含 'sqlite'）以 `as string` 收敛，tsc 过。
2. **Fork spec 回归守卫** ✓ — `uniqueConstraintHelpers.Fork.spec.ts` 存在，命中 jest testRegex `(Integration|Source|Fork)\.spec\.ts$`，对 `'sqlite'`/`'sqlite3'` 双值断言 toThrow(/SQLite/)，随 jest 14/14 实跑通过。
3. **UUID 建表 readonly 镜像** ✓ — `tables.service.ts`（createTable）：`uidt === UITypes.UUID && (source.is_meta || source.is_local)` → `column.unique = true; column.readonly = true`；落库链路 `readonly: c.readonly || false`（Model.insert 映射）保留；运行时守卫 `BaseModelSqlv2.ts:4243` / `:6159`（`!allowSystemColumn && col.readonly`）拦截用户传值。columnAdd 侧 `colBody.readonly = true` 已在位。

## 工作树卫生

- `Api.ts` 不在 `git status --short`（grep 无命中）✓
- `.gitignore` 生效实测：`git check-ignore -v` 命中 `.gitignore:139:.work/` 与 `:141:packages/noco-integrations/packages/` ✓
- 未跟踪文件仅 3 个且均为预期：仓根 `AGENTS.md`（项目约束文档）、`nc-gui/test/unique-constraint-helpers.test.ts`、`nocodb/src/helpers/uniqueConstraintHelpers.Fork.spec.ts` ✓
- diff 未引入 console.error / 凭证类内容 ✓

## 前端两文件终审

- `useEeConfig.ts`：`blockUnique = computed(() => false)`，`return` 对象含该键（:605）；全仓 `blockUnique` 仅 EditOrAdd.vue 两个消费点，无其它 UI 依赖翻转副作用。
- `EditOrAdd.vue`：
  - toggle 可见性 `!blockUnique` 替换 `showEEFeatures`（:1512）——CE 上 showEEFeatures 恒 false，原 toggle 永不可见；替换后受 isXcdbBase / 类型支持 / 非UUID / 非AutoNumber 约束，语义正确。
  - `PaymentUpgradeBadge v-if="blockUnique && !unique"`（:1551）在 blockUnique=false 下恒死——与解 gate 一致，非缺陷。
  - `unique` setter（:858）短路依赖 `showUpgradeToUseUnique`，CE stub 为 `(...args) => {}` 返回 undefined（`useEeConfig.ts:326`）→ 不短路，toggle 可写 `formState.unique` ✓。
  - `showEEFeatures` 其余 4 处（:273/:275/:291/:294）为其它 EE 字段 gate，未被本改动波及。

## 逐 hunk 终审（其余 PASS 项）

- `BaseModelSqlv2.ts` 三处 catch（update / bulkUpdate / bulkUpdateAll）接 `handleUniqueConstraintError`：bulkUpdate 先 rollback 再查 handler（无锁内查询）；handler 抛 UniqueConstraintViolationError 时跳过 errorUpdate 与 insert 路径行为一致；tsc 类型过。
- `MysqlClient.ts` 移除无条件 `DROP INDEX`：两个调用点核实——change===1（ADD COLUMN，新列无既有索引）、change===2 且 `nIsUnique !== oIsUnique && nIsUnique`（旧列非 unique，索引不存在）；禁用 unique 的 DROP INDEX 分支（:2744）保留未动。修复正确。
- `uniqueConstraintErrorHandler.ts` R2 守卫：`!column` 且（无 constraintName / `_pkey` 后缀 / 模型无 unique 列）→ return 放行；`_pkey` 命中 PG `<table>_pkey` 主键命名 ✓。
- R3 空串 fallback：`([^)]+)` 正则确实匹配不到空串；fallback 仅在 column 与 insertData 在场时生效 ✓。
- `normalizeUniqueConstraintFlag`：undefined/null → undefined（视为未请求），boolean 透传，其余 badRequest；三处调用点（columnAdd / columnUpdate / tableCreate）均在 validateUniqueConstraint 之前 ✓。
- `columns.service.ts` UUID 分支 `isNcDbSource` gate：external 源不再强写 unique/internal_meta；`source.type !== 'pg' && 'mssql'` 前置拒绝仍在位 ✓。
- `jest.config.js`：testRegex 加 Fork 桶 + `isolatedModules: true`（ts-jest transpile-only），随 jest 实跑无编译崩溃，类型由 tsc 兜底（0 error）✓。

## issues 列表

1. `packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts:771`（R3 `if (columnName === 'PRIMARY') return;`）: MySQL 8 主键冲突消息为 `Duplicate entry 'x' for key '<表名>.PRIMARY'`（该函数自身 docstring 格式 3 即列出 `table.column_name` 带前缀形态）；`extractColumnNameFromError` 首个正则 `/for key ['"]?([^'"]+)['"]?/i` 捕获完整 `'mytable.PRIMARY'`（其后的 `[^.]+\.(...)` 备用正则在首个命中时不可达），严格相等 `=== 'PRIMARY'` 判不中 → 守卫失效 → 走 fallback 将 PK 冲突误归因到 payload/唯一 unique 列，与该修复「放行原始错误」的意图相反。建议：`if (columnName === 'PRIMARY' || columnName?.endsWith('.PRIMARY')) return;`。可达性注：需 MySQL 部署（mysql NC_DB 或外部 mysql 源）+ PK 重复冲突；本 fork 开发环境为 pg，集成测试未覆盖该路径。单路发现，建议实测核验后处置。

## 结论

主验证项全 PASS（tsc 0 error / jest 14/14 / vitest 8/8 / R4 三修复在位 / 工作树卫生 / 前端终审）。报 error 级 issue 1 条（MySQL PRIMARY 前缀形态守卫缺口，单路、低可达性、附代码证据）。
