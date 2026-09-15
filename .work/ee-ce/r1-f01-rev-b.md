# r1-f01-rev-b — F01 Unique 后端代码复审（独立第 4 路）

复审人：后端代码复审子代理。只读 TASK.md / 仓根 AGENTS.md / 源码，未读任何他路报告。
范围：uniqueConstraintHelpers.ts / columns.service.ts / PgClient.ts / uniqueConstraintErrorHandler.ts / 新增 spec + jest.config / MySQL 路径（只读评估）。

## 裁决：FAIL（10 issues，按严重度排序）

### issues

- packages/nocodb/src/db/sql-client/lib/mysql/MysqlClient.ts:2659（addUniqueConstraintToQuery）：MySQL 路径启用 unique 必然失败——无条件追加 `, DROP INDEX ??`，而 change===1（新增 unique 列，2713-2716）与 change===2 首次启用（2719-2734）时该索引尚不存在，MySQL 无 `DROP INDEX IF EXISTS`，直接抛 ER_CANT_DROP_FIELD_OR_KEY (1091)。PG 路径正常、MySQL 路径全坏，跨库功能不一致。建议：仅当 `oIsUnique` 为真（替换既有索引）才发 DROP INDEX，否则只 ADD CONSTRAINT。

- packages/nocodb/src/services/columns.service.ts:4128-4192（columnAdd UUID 分支）：UUID 强制 unique 绕过 NC-DB gate——4022 的 validateUniqueConstraint 仅 `if (colBody.unique)` 时执行，用户创建 UUID 不带 unique 时校验被跳过，4140 事后强制 `colBody.unique = true`，NC-DB 限制（helpers:34）、类型/cdf 校验全部漏掉。外部 pg/mssql source（is_meta=false）建 UUID 列会把 unique 约束 + partial index + gen_random_uuid 默认值写进用户外部库，违背「unique 仅限 NC-DB」策略。建议：4140 强制 unique 后补调 validateUniqueConstraint（带 source），或强制前先查 source.isMeta/is_local。

- packages/nocodb/src/db/sql-client/lib/pg/PgClient.ts:3202-3204 + packages/nocodb/src/services/tables.service.ts:1144-1167（tableCreate unique）：两条不一致。① change===0 内联 `UNIQUE` 完全忽略 softDeleteColumnName——含软删列表建表时生成全量约束，同表后加列走 addUniqueConstraintToQuery（3602-3613）却是排除软删行的 partial index：同一库内两种语义并存，建表路径下被trash记录的值永久占用。② 建表路径不写 internal_meta.unique_constraint_name（PG 自动命名 tn_cn_key），之后 disable 依赖 queryUniqueConstraintName 回查（2589-2639）；该回查 catch 全部异常返 null，查不到时落回确定性名 `uk_base_model_col`（3487-3517），与实际约束名不符 → `DROP CONSTRAINT IF EXISTS` 静默空转，DB 仍强制 unique 而元数据已标 false，且无任何报错。建议：tableCreate 的 unique 也走 addUniqueConstraintToQuery（带名 + partial），或在 Model.insert 前补写 internal_meta。

- packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts:262（has23505Anywhere）：`errorString.includes('23505')` 对整个 error JSON 做子串搜索——序列化结果含 SQL 原文、bind 值、position 等字段；任何与 unique 无关的 DB 错误（如 CHECK 违规、语法错），只要 SQL 文本/用户值/数字字段恰好含 "23505" 子串，就被改写成 UniqueConstraintViolationError（伪字段名/伪值），误伤面大。下方 436-451 已有完备的类型化 code 检查，此兜底纯属风险。建议：删除 stringify 子串匹配，仅保留类型化 code 判定。

- packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts:266-276、571-582、859-866：任何 23505（含主键冲突、junction 表约束）都转成 unique 报错；model 无 unique 列时抛 fieldName='unknown'，有 unique 列时兜底取 `uniqueColumns[0]`——主键重复会被错误指认到某个业务 unique 字段，用户看到错误的字段名与值（误伤归因错误）。建议：先用 error detail 的 constraint name 与 internal_meta 名单精确匹配，匹配不上且无候选 unique 列时放行给通用 DB error extractor。

- packages/nocodb/src/services/columns.service.ts:1309-1317、1455（+ PgClient.ts:2593、3385）：`unique` 值不做类型归一——API body 传字符串 `"false"`/`"0"` 时真值判定为「启用」：1309 `'unique' in param.column` → 1317 走启用分支（跑校验+查重），1455 存约束名，PgClient `!!n.unique` 为真直接 ADD CONSTRAINT。请求方意图是关闭，结果开了 unique。建议：入口统一 `unique = param.column.unique === true` 归一（或校验非法类型直接 400）。

- packages/nocodb/src/helpers/uniqueConstraintHelpers.ts:60-65（+ columns.service.ts:1352-1356、4039-4049）：cdf 互斥检查 `cdf !== ''` 把空字符串 default 当作「未设默认」。unique 文本列 + `DEFAULT ''` 可创建成功，第二行走默认值即触发 23505——校验期漏放、运行期爆炸。（反向边界 OK：cdf='0'/'false' 是真实默认值，被拒正确。）建议：unique 场景对 cdf==='' 也拒绝，或仅允许显式 null/undefined。

- packages/nocodb/src/services/columns.service.ts:1315-1316（columnUpdate）：old/new 都 unique 时完全跳过校验——若同请求改 uidt（如 unique 文本列转 Attachment/JSON 等不支持类型，或转换后 cast 产生重复值），新类型不校验、重复不预检，DDL 阶段裸抛 DB 错（该路径无 handleUniqueConstraintError 包裹），用户见原始错误。建议：uidt 变化且 unique 保持时，用新 uidt 重跑 validateUniqueConstraint + 对 cast 结果做 duplicate 预检。

- packages/nocodb/src/services/duplicate-detection.service.ts:223-246（validateUniqueValue）：normalizedValue（lower/trim）算完不用，查询仍用原始 `String(value)`——且 lower/trim 语义与 PG 约束（大小写敏感、不 trim）相悖。当前该函数无调用方（262 行注释自认），属休眠不一致：一旦后续接线，app 层大小写不敏感、DB 层敏感，行为劈叉。建议：删除 normalize 调用或删整个死函数；若要大小写不敏感 unique 须改索引为 `lower(col)` 表达式。

- packages/nocodb/src/services/columns.service.ts:1452-1464（columnUpdate disable 分支缺失清理）：关闭 unique 不清 internal_meta.unique_constraint_name，旧名残留。当前重启用时 586 会覆盖同名列，平时无害；但 partial index 场景 `DROP INDEX IF EXISTS schema.<name>`（PgClient.ts:3423-3427）是 schema 级操作，若该 internal_meta 被表复制/导入类路径原样带走，同名 DROP INDEX 会误删他表索引。建议：disable 时同步删除 internal_meta.unique_constraint_name。

### PASS 项（核过无问题）

- packages/nocodb/jest.config.js:8-11：testRegex 增 `Fork` 桶，全 src 仅 uniqueConstraintHelpers.Fork.spec.ts 一个匹配文件，无误纳；nc-gui vitest 不受影响。PASS
- packages/nocodb/src/helpers/uniqueConstraintHelpers.Fork.spec.ts：8+3 用例逐一与实现核对（NC-DB 拒绝/放行、类型名单、LongText richMode、cdf 拒绝、UUID 豁免、normalize 空值/trim/小写/原值），断言与代码行为一致。PASS
- 约束名长度：nanoidv2=14 字符（meta.service.ts:30），`uk_` + p15 + m15 + c15 = 50 < 63（PG 标识符上限），无截断风险；PgClient 随机兜底已 slice(0,63)。PASS
- queryUniqueConstraintName（PgClient.ts:3441-3479）：nspname 以 args.schema || searchPath[0] 限定，sqlClient 为 per-source 实例，多 base per-schema 无串扰；确定性名含 base_id 天然跨 schema 唯一。PASS
- duplicate-detection.checkForDuplicates：`HAVING COUNT(*)>1 LIMIT 1` 存在性判定正确；count=total-distinct 正确；软删过滤（IS NULL OR false）与 partial index 谓词一致；NULL 排除与 PG 多 NULL 允许一致。PASS
- validateUniqueConstraint 主体（source gate / 类型名单 / UUID cdf 豁免）逻辑正确，与 spec 吻合；上述 issues 均为边界/调用方组合漏洞，主体不推翻。PASS
