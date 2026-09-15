# r4-f01-rev-a — F01 第 4 轮 · 第 3 路（改动面代码复审）

## issues

1. `packages/nocodb/src/helpers/uniqueConstraintHelpers.ts:62` — sqlite 显式拒绝门失效（R3 修复 c 无效）：`if ((source?.type as string) === 'sqlite')` 比较值 `'sqlite'` 不在 `DriverClient` 值域内，实际值是 `'sqlite3'`（`src/utils/nc-config/constants.ts:84` `SQLITE = 'sqlite3'`）。`Source.type` 全链路只写 `config.client`（`src/services/sources.service.ts:67`，类型 `DriverClient`，`src/models/Source.ts:38`），SDK `SqlUiFactory.ts:33` 也仅识别 `client === 'sqlite3'`，运行时不存在 `source.type === 'sqlite'` → 该分支恒 false，is_local / sqlite NC_DB 的 is_meta 源上请求 unique 不会被拒绝，原始 bug（sqlite DDL 路径静默丢弃 unique flag → meta unique=true 与物理约束不一致）原样保留。注释「runtime values can still be sqlite for local sources」与代码库事实不符（convertUnits/mapFunctionName 里的 `'sqlite'` 是另一层转换后短名，非 Source.type 值）。建议改为 `(source?.type as string) === 'sqlite3'`（或同时匹配两值防御）。另：前后端两套 spec 均无 sqlite case，此门零测试覆盖。

## 实跑记录

- `npx tsc --noEmit`（packages/nocodb）：exit 0，0 error
- `npx jest uniqueConstraintHelpers`：13/13 PASS
- `npx vitest run --config test/vite.config.ts test/unique-constraint-helpers.test.ts`（packages/nc-gui）：8/8 PASS
  - 注：不带 `--config test/vite.config.ts` 直跑会因 `~` alias 未解析 FAIL（Cannot find module '~/utils/uniqueConstraintHelpers'），属跑法问题非代码问题，tracked 配置 `packages/nc-gui/test/vite.config.ts` 下通过

## R3 五项修复核验（4/5 通过）

1. bulkUpdateAll `insertData: data`：`data` 为用户 bulk payload（title 键），handler 内 `insertData[column.column_name] ?? insertData[column.title]` 双键查询可命中 — 通过
2. tables.service UUID NC-DB 强制门：位于 ck 映射循环（`ck: originalUnique ? 1 : ...`）之后、validate 循环之前；只改 `column.unique`，不改 ck 映射；`is_meta || is_local` 限定与 columnAdd 一致；UUID 在 SDK `UNIQUE_CONSTRAINT_SUPPORTED_TYPES` 内，MssqlUi.isUniqueSupportedField(UUID)=true、PgUi/MysqlUi/SqliteUi 无该方法经 `?.` 直通 — 通过
3. sqlite 显式拒绝：**失效，见 issues #1**
4. handler PRIMARY 直通：`columnName === 'PRIMARY'` 判定在 `extractColumnNameFromError` 之后、payload 推断（L781）与 unique 列 fallback（L841）等全部归因 fallback 之前；MySQL ER_DUP_ENTRY（code 非 23505）不进前两个 23505 早退分支，必经此路径 — 通过
5. 空串 value 回退：L318-324 与 L653-659 两处同型分支逐字一致，payload 空串经 `!== undefined && !== null` 正确回填 — 通过

## 其余 diff 终审（无 error）

- BaseModelSqlv2 三处 catch（update L2894 / bulkInsertUpdateAll L4638 / bulkUpdateAll L4820）：`errorUpdate` 为空实现（L6090-6094），handler 先 throw 跳过它无影响；`datas?.[0]` 数组取首条仅用于 value 回退，可接受
- MysqlClient：移除无条件 `DROP INDEX` 正确 — change=1 新列无旧索引；change=2 仅 `nIsUnique && !oIsUnique` 时调用，旧列必无索引
- uniqueConstraintErrorHandler R2 两处 `!column` 分支逐字一致；`has23505Anywhere` 移除 free-text `errorString.includes` 后结构化检查完备
- jest.config testRegex 加 `Fork` bucket + `isolatedModules: true`：全库无 TS `const enum` 声明，transpile-only 安全
- columns.service：columnUpdate normalize `as any` 必要（undefined 合法态）；columnAdd UUID 门 `isNcDbSource ? true : !!colBody.unique`，外部源经前置 validate 已拒 unique，两路一致；internal_meta 仅 NC-DB 生成，镜像正确
- 前端 useEeConfig `blockUnique=false`：消费者仅 EditOrAdd 两处 — toggle 显示条件换 `!blockUnique` 正确；PaymentUpgradeBadge `v-if="blockUnique && !unique"` 随之永不显示（fork 语义正确）；`canEnableUniqueConstraint` 保留在 disabled/tooltip 上，外部源 toggle 仍禁用，与后端 `validateUniqueConstraint` 外部源拒绝一致
- 单测文件：后端 Fork.spec 13 case、前端 8 case，与被测导出匹配，无 over-mock
- 工作树卫生：untracked 仅 AGENTS.md + 2 个新测试文件（预期提交件）；`.work/`、`packages/noco-integrations/packages/`（core symlink shim）经 `.gitignore:139/141` 正确忽略，`git ls-files` 确认两路径无历史跟踪文件
