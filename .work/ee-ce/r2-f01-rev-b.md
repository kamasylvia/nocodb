# r2-f01-rev-b — 第 4 路后端深水区复审（F01 Unique 第 2 轮）

审读范围：uniqueConstraintErrorHandler.ts 全文 / BaseModelSqlv2.ts + insert.ts 四个 handler 接入点 / columns.service.ts 全部 unique 消费点 / PgClient + MysqlClient 建表与 alter 双路径 / LTARColsUpdater / bulkUpdateAll。jest uniqueConstraintHelpers 13/13 PASS。:8080 未实测（读码足以定案以下各项）。

## Issues

1. `packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts:262`: `errorString.includes('23505')` 对 JSON.stringify 后的整个 error 做子串扫描，任何 message/detail 恰含数字串 "23505" 的非 unique 错误都会被归因为 unique violation。构造场景：向 Number 列插入非法值 "23505" → PG 报 22P02 `invalid input syntax for type integer: "23505"` → has23505Anywhere=true → 返回 FIELD_UNIQUE_CONSTRAINT_VIOLATION（"值已存在"），真实 invalid-input 错误被吞。四个入口（insert.ts:234/699、BaseModelSqlv2.ts:2900/4642）全部先过 handler，全暴露面受影响。建议：删除 JSON 子串扫描；归因只信 code/errno/number 等结构化字段（isUniqueViolation.ts 的 codes-set 写法即正确基线）。

2. `packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts:245-276,571-582`: PK 冲突（PG `_pkey` 冲突同为 23505）被同码吞入 unique 通道：模型无 unique 列时抛 fieldName='unknown' 的 unique violation；有 unique 列且 detail 丢失时走 fallback 猜列 → 报错列/错值。用户显式给重复 id 的 bulk insert 场景可得 "字段 unknown 值已存在" 类误导信息。建议：detail/constraint 名含 `_pkey`/PRIMARY 时按 PK 重复单独报错或原样重抛。

3. `packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts:139-187`: findDuplicateColumnByQuery 无排除当前行的参数。update 场景（updateByPk:2900、bulkUpdate:4642 新接入）触发 23505 且 detail 丢失时（extractDBError 处理链可丢 detail），payload 多 unique 列有值时 columnsWithData[0]/findDuplicateColumnByQuery 可命中行自身未变的 unique 值 → 误报该列重复（真正的冲突列是别的列）或 PK 冲突（issue 2）被报成 unique 列重复。建议：调用方传当前行 pk，查询加 `.whereNot(pk, currentPk)`；或先比对"payload 值 == 行原值"跳过。

4. `packages/nocodb/src/db/BaseModelSqlv2.ts:4789-4791`: bulkUpdateAll 的 catch 为 `catch (e) { throw e; }`，未接 handleUniqueConstraintError。API 暴露面存在（services/bulk-data-alias.service.ts:133 operation='bulkUpdateAll'，v2 bulk update with where）。unique 列经该路径更新违反唯一时返回通用 DB 错误文本而非 FIELD_UNIQUE_CONSTRAINT_VIOLATION，与第 1 轮 updateByPk/bulkUpdate 修复不一致，前端 errorUtils 字段级映射失效。建议：与 bulkUpdate 同款接 handler。

5. `packages/nocodb/src/db/sql-client/lib/pg/PgClient.ts:3474-3477`: queryUniqueConstraintName catch 吞异常返回 null；叠加 `getUniqueConstraintName`(3487) 的 ID/随机后缀 fallback 与 `IF EXISTS` DROP(3420-3428)，构成静默不 DROP 路径——可达条件：建表内联 UNIQUE（PG 自动名 `tbl_col_key`，internal_meta 未存名，见 issue 6）+ 预取查询抛异常（网络/权限）。后果：DB 约束残留、meta unique=off、无任何报错，后续同列再开 unique 时 addUniqueConstraintToQuery 的 DROP CONSTRAINT IF EXISTS 也打不中自动名，残留固化。建议：查询失败或 constraintName 来自猜测名时显式 NcError（或至少 warn + 失败语义），DROP 前先以 pg_constraint/pg_indexes 实名确认。

6. `packages/nocodb/src/db/sql-client/lib/pg/PgClient.ts:3201-3203 vs 3234-3241`: 表创建内联 UNIQUE 与 alter 路径 partial index 语义分叉。CREATE TABLE（change===0）内联 `UNIQUE`，不看 softDeleteColumnName、不落 unique_constraint_name；ALTER ADD COLUMN（change===1）走 addUniqueConstraintToQuery，软删列存在时生成 partial unique index（`WHERE __nc_deleted IS NULL OR false`，软删行不占值）。CE 现网 isTrashEnabled=false、无 __nc_deleted 列 → 两路径同型（全量唯一），无实际问题；**软删列存在（EE/trash 开启）时同表内先建列全量唯一、后加列 partial，分叉真实**，触发条件 = 同表先建 unique 列后开 trash 再加 unique 列。内联 UNIQUE 不存 internal_meta 同时放大 issue 5 攻击面。建议：建表路径改走 addUniqueConstraintToQuery（具名 + internal_meta）或在分叉注释/文档标注触发条件。

7. `packages/nocodb/src/helpers/isUniqueViolation.ts:1-48`: 独立 isUniqueViolation 实现零引用（全仓 grep 无 importer、无 spec），为死代码；且与 uniqueConstraintErrorHandler.ts:22-33 内嵌同名函数行为面不同（独立版含 mssql 2601/2627、mysql 1062、SQLITE_CONSTRAINT_UNIQUE；内嵌版有宽松 `/unique|duplicate/i` message 正则）。同名双实现易被后续误引错版本。建议：删除独立文件，或将内嵌版替换为独立版（顺带缓解 issue 1）。

8. `packages/nocodb/src/db/BaseModelSqlv2/insert.ts:701` 与 `packages/nocodb/src/db/BaseModelSqlv2.ts:4644`: bulk 路径 handler 的 insertData 一律取 `datas?.[0]`，批量第 N 行冲突且 detail 丢失时用第 1 行数据猜列，可错报列/值。issue 2/3 的次要症状，建议与 issue 3 同修（从冲突 detail 取行定位，不依赖 datas[0]）。

## 清点结论（无新 issue 的任务项）

- 任务 2 归一覆盖清点：columnAdd:4031、columnUpdate:1315 均走 normalizeUniqueConstraintFlag；POST /api/v2/meta/tables/:tableId/columns/bulk（columns.controller:124 → columnsBulk:7573）内部复用 columnAdd/columnUpdate → 覆盖；updateMetaAndDatabase(646) 的 uniqueValue 透传输入域已归一（param 已 boolean + DB 列 boolean），无字符串泄漏面；UUID NC-DB gate（columnAdd 4136-4139 isNcDbSource）在位。columns.service 无遗漏 unique 入口。
- 任务 5 更新族：bulkUpdateAll 见 issue 4；updateLTARCols（ltar-cols-updater）经 add-remove-links 的 cardinality enforcement（add-remove-links.ts:436 先清冲突 junction 行）后关联表 23505 概率极低，且其异常最终落 bulk catch 已接 handler；onInsertedPks 仅 bulk 内 pk 回调，异常同走 bulk catch。除 issue 8 的 datas[0] 猜列外无未映射错误码的独立暴露面。
- MysqlClient 第 1 轮修复确认无回退（addUniqueConstraintToQuery:2657 注释在位，无无条件 DROP INDEX）；MySQL drop 分支 `DROP INDEX ??`（2744）无 IF EXISTS，名字失配时显式 1091 失败而非静默，与 PG 行为不对称但非静默残留，随 issue 5 一并权衡即可。
- 任务 6：`npx jest uniqueConstraintHelpers --runInBand --forceExit` = 13/13 passed（30.8s）。
