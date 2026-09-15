# r3-f01-rev-b — 后端深水区复审(第 4 路,第 3 轮)

范围:handler 加固回归 / 归因正确性 / update 路径副作用 / unique DDL 生成面 / 消费点清点 / jest。隔离:只读 TASK.md、仓根 AGENTS.md、源码。jest 实跑:`uniqueConstraintHelpers.Fork.spec.ts` 13/13 PASS,断言与实现一致(normalize 拒非布尔、UUID+cdf 例外、类型面、cdf 互斥)。

## issues

1. `packages/nocodb/src/db/sql-client/lib/sqlite/SqliteClient.ts:2211-2212`(建表 change===0):`UNIQUE` 内联被注释(`// query += n.unique ? ' UNIQUE' : '';`)。`SqliteClient.ts:2213-2229`(加列 change===1):无任何 unique 处理。`SqliteClient.ts:2178`(改列 change===2):`query += n.unique ? ' UNIQUE' : ''` 追加的 `query` 在 `2197` 行被整体覆盖(`${backup}${addNew}${update}${drop}`),UNIQUE 从未进入最终 SQL——死代码。即 **sqlite NC-DB 三条 DDL 路径全部静默丢弃 unique**。而 `uniqueConstraintHelpers.ts:40` `validateUniqueConstraint` 对 sqlite 放行(SqliteUi 无 `isUniqueSupportedField` 覆盖,`=== false` 判定不命中;SDK `SqlUI.types.ts:67` 注释明写支持 "pg/mysql/sqlite"),meta 随即保存 `unique=true`。可达性:① sqlite 是 NocoDB CE 默认库类型(NC_DB 缺省即 sqlite);② 建表 `POST /api/v2/meta/bases/:baseId/tables/` 或加列 `POST /api/v1/db/meta/columns/:tableId` 带 `unique: true` → validate 200 → DDL 无约束;③ data API 插入重复值 → 无 SQLITE_CONSTRAINT → 静默成功,EE unique 功能整体失效且无任何报错。注:DDL 丢失本身是上游遗留(0e13bff899),但 fork 打开了该入口(validate/normalize/SDK 声明),入口开了就得兑现。建议:sqlite 路径用 `CREATE UNIQUE INDEX`(sqlite 支持部分索引,可对齐 pg partial 语义;change===2 修 `2178` 追加目标),或在 `validateUniqueConstraint` 对 `source.type === 'sqlite2'/'sqlite3'` 明确拒绝,二选一,不留静默缺口。

2. `packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts:99-107` + `814-830`:MySQL `ER_DUP_ENTRY` for key `'PRIMARY'` 无 PK 直通。`extractColumnNameFromError` 的 `mysqlKeyMatch` 把 `'PRIMARY'` 原样返回(注释自己承认 "If it's not 'PRIMARY'..." 却没做过滤),上层 `column` 查找失败 → `814-819` `uniqueColumns.length === 1` 直接归因到唯一 unique 列并 throw `UniqueConstraintViolationError`。这违反 R2 已确立的原则(pg `<table>_pkey` 冲突直通放行,不归因 unique 列)——同一条原则只修了 pg 一侧。可达性:mysql NC-DB 表,insert payload 显式提供 PK 值(`insert.ts:63-89` 不剥离 PK,validate 保留用户值;auto_increment 与 UUID-PK 均允许显式值)→ 重复 Id → `ER_DUP_ENTRY ... for key 'PRIMARY'` → handler 报「unique 列冲突」而非 PK 冲突,前端按 FIELD_UNIQUE_CONSTRAINT_VIOLATION 高亮错误字段。建议:与 `_pkey` 对称——`mysqlKeyMatch` 命中 `'PRIMARY'` 时返回 null,且第二 tier 归因段(814 起)对 keyName `'PRIMARY'` 直接 `return`(放行原错误)。

## 复核说明(不构成 issue)

- jest:13/13 PASS,断言与三入口实现(tables.service:1151 / columns.service:4031 / columns.service:1315)语义一致。
- 结构化判定枚举:pg `DatabaseError.code='23505'` 顶层直达;mysql2 `code='ER_DUP_ENTRY'`/`errno=1062` 走第二 tier;sqlite `SQLITE_CONSTRAINT` + `/UNIQUE/i` message 命中;knex/pg/mysql2 均直接 rethrow 驱动错误、无包装层,`original/nativeError` 防御位足够。
- update 路径(insertData 传参):`findDuplicateColumnByQuery` 仅在 detail 提取失败后执行;NC-DB 下 pg 23505 的 `detail`、mysql 的 `sqlMessage` 由服务端恒定携带,提取必成功 → 查询兜底与 payload fallback 在 NC-DB 不可达,"本行当重复源"无 API 触达路径(见 backlog)。
- MysqlClient `addUniqueConstraintToQuery:2657` R1 修复正确:两个调用点(2717 新列 / 2736 `oIsUnique===false` 分支)均保证旧索引不存在;drop 分支 `DROP INDEX:2744` 为必要删除,不属 R1 误删面。
- PgClient drop 分支 `3414-3427` schema 限定正确;`queryUniqueConstraintName:3464` 限单列约束(conkey 长度 1),不会误取组合约束名。
- 消费点清点无漏网:三入口 normalize/validate + DDL(pg/mysql ✓,sqlite 见 issue 1)+ meta 回读(pg:909 / mysql:657 / sqlite:488)+ handler 五调用点(insert.ts:234,699;BaseModelSqlv2.ts:2900,4642,4821)+ duplicate-detection.service 启用前置检查 + SDK 类型面。`MssqlClient.ts` 在本 fork 不存在(SqlClientFactory 无 mssql 注册),handler 的 mssql/oracle 分支为防御性死分支。

## backlog 注记(不计 issues)

- 死代码:`uniqueConstraintErrorHandler.ts:22-33` 内联 export `isUniqueViolation`(模块内 502 行被同名 const shadow,且全仓无消费者);`helpers/isUniqueViolation.ts` 完备版(含 `errors[]` AggregateError 展开、1062/2601/2627 数字码)同样零消费者。建议二合一接入 handler,删冗余。
- `has23505Anywhere` 未查 `error?.cause?.code` 与 `e.errors[]`:knex 直接 rethrow,pg/mysql2 无 cause 包裹形态,不可达;若未来接 `isUniqueViolation.ts` 完备版即自动覆盖。
- 组合 unique(外部 pg 表,成员列经 `PgClient:851-859` is_unique SQL 全员标 unique):detail `Key (a, b)=(v1, v2)` 被 `split(',')[0]` 截断 → 单列归因 + 单值报告;列名含引号/逗号时提取断裂 → 落 payload fallback 可能归因无关列。NC-DB 生成面全是单列约束(内联 UNIQUE / ADD CONSTRAINT 单列 / partial 单列),组合仅外部表可现;外部表 unique 属用户自带 schema,错归因仅影响报错文案。保持观察。
- 多 unique 列 + detail 缺失 + payload 双列有值 → `columnsWithData[0]` 可能错归因:NC-DB 下 detail 恒存在,不可达;仅外部 + 畸形错误形态理论可现。
- `findDuplicateColumnByQuery` 本行命中(update 语义):依赖上述不可达前置,同上,不构成现行问题。
- pg 建表内联 `UNIQUE:3202` 与加列 partial index(3599-3619)分叉:本 fork `Model.isTrashEnabled` 硬编码 `false`(Model.ts:123-125 stub),无软删行,两形态行为等价;解 trash gate 时必须同步改建表分支(建表路径未传 `softDeleteColumnName`),MySQL 无 partial index 能力,届时需 product 决策 unique×trash 语义。
- `isExtractedDbError`(`error.error==='ERR_DATABASE_OP_FAILED'`)形态:extractDBError 在全局 exception filter 层,晚于 handler 调用点,handler 收不到该形态——防御性代码,无害。
- `error?.errno === 23505`(243-245):mysql2 实际 errno=1062,该分支永不命中,无害冗余。

## 结论

**2 issues**(sqlite unique DDL 静默失效;MySQL PRIMARY 冲突错归因),均给出 API 可达链;静态证据充分,建议 orchestrator 在 mysql/sqlite source 上实测复核后修复重开新一轮。pg 主路径(ncodb-dev 面示)前两轮修复项复核无回归。
