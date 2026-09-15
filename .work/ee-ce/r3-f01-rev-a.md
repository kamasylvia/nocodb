# r3-f01-rev-a — F01 Unique values only 第 3 轮 改动面代码复审(独立第 3 路)

审查范围:`git status/diff` 全部改动(10 modified + 2 新测试文件);禁读历史 r* 归档,只读 TASK.md / 仓根 AGENTS.md / 源码。

## 复核记录(按任务书 5 项)

1. **逐 hunk 审全部 diff**:10 文件全部过审,均带 `// [CE-EE]` 标记,无类型错误(除下述 1 项)。
   - uniqueConstraintErrorHandler.ts:
     - ①早期判定:`errorString`/`JSON.stringify` 自由文本扫描已移除,`has23505Anywhere`(L230-245)仅剩结构化 `code`/`errno`(string/number 双态,含 original/nativeError/extracted 三层)。误归因根因已消除;漏检后果仅是原错误经 extractDBError 走通用文案,可接受。
     - ②detail 提取分支两处守卫(L289-306 / L614-631)逐字同型一致。`return` 语义正确:`Promise<void>` 提前返回 = 不抛 = 各调用方 catch 后 `throw e` 透传原错误,与既有 L721-723 "let it propagate" 语义一致;两守卫仅在 `!column`(detail 列名匹配不到任何 meta 列)时触发,正常 meta unique 归因路径(column 命中)不受影响。守卫内 `modelColumns.filter((c)=>c.unique).length === 0` 在两分支均为死条件(两块入口处 `uniqueColumns.length===0` 已先行 throw),冗余但无害,不列为 issue。
2. **三入口布尔归一 + UUID gate + 三 catch handler**:完整。
   - 归一三入口齐备且无第四漏网:tables.service.ts L1151(tableCreate)、columns.service.ts L1315(columnUpdate)、L4031(columnAdd);全仓 grep 确认无其它从请求读 `unique` 的入口;columnUpdate 内部 `updateMetaAndDatabase`(5 个调用点全部位于 columnUpdate 内)收到的 `column.unique` 均已经过归一;UI NcSwitch 只发 boolean,`showUpgradeToUseUnique` 为 no-op,严格拒绝字符串不伤正常 UI 流。
   - UUID gate(columns.service.ts L4155-4164):`isNcDbSource = !!(source.is_meta || source.is_local)` 与 `Source.isMeta()`(Source.ts L336)同构,`is_local` 字段存在(Source.ts L40);external 源不写 internal_meta,与 unique gate 镜像一致。
   - catch handler:updateByPk(L2900)、bulkUpdate(L4642)、bulkUpdateAll(L4821)三处俱在;insert.ts L234/L699 既有路径不受守卫影响。
3. **实跑**:后端 `npx jest uniqueConstraintHelpers --runInBand --forceExit` → 13/13 PASS;前端 `npx vitest run --config test/vite.config.ts test/unique-constraint-helpers.test.ts` → 8/8 PASS。
4. **工作树卫生**:Api.ts 不在改动列表 ✓;.gitignore 新增 `.work/` 与 `packages/noco-integrations/packages/` ✓;新文件仅 2 个测试文件(预期)+ 仓根 AGENTS.md(任务书文档,非功能改动)。
5. **MysqlClient**:两 call site 前置条件成立——change===1(ADD COLUMN,新列不可能已有索引)、change===2 且 `nIsUnique && !oIsUnique`(旧列非 unique → 索引不存在);移除无条件 `DROP INDEX ??` 后不再触发 MySQL 1091;disable 分支的 DROP INDEX 未被本次改动触碰。

类型核验:`npx tsc --noEmit -p tsconfig.json`(packages/nocodb)全仓仅 1 错,即下述 issue,归因于本 diff(jest isolatedModules 不查型,故 jest 全绿不能兜底此项)。

## 裁决

issues:

- packages/nocodb/src/db/BaseModelSqlv2.ts:4824:bulkUpdateAll catch handler 的 `insertData: args?.data` 类型错误且运行时恒为 undefined——`args` 是第一参数(`{ where, filterArr, viewId, ... }` 选项对象,无 `data` 属性,tsc 实测 TS2339),update payload 是第二参数 `data`;现状导致 bulkUpdateAll 路径 handler 拿不到 payload,唯一归因退化为仅靠 error-detail 提取:建议改为 `insertData: data`。
