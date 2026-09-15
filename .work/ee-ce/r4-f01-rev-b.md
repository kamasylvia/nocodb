# r4-f01-rev-b — 第 4 路后端深水区复审（R4）

审查范围：R3 修复落地的 5 项（bulkUpdateAll insertData=data / UUID 建表强制门 / sqlite 显式拒绝 / mysql PRIMARY 直通 / 空串 value 回退）+ 终局清点。
隔离声明：未读任何 r*.md 归档；只读 TASK.md、仓根 AGENTS.md、源码、dev-backend.sh（取凭证方式）。

## 裁决

**PASS**（0 error；5 条 backlog 见文末）

## 逐项验证

### 1. handler 终审：PRIMARY 直通与 value 回退

- PRIMARY 直通无绕行。`extractColumnNameFromError` 三层顺序 normalizedError → originalError → error（uniqueConstraintErrorHandler.ts:764-769），R3 check（:774-776）位于三层**之后**统一判定 `columnName === 'PRIMARY'`——第一层命中即返回（不会走二三层），第一层 null 第二层命中时最终值仍过同一 check。分层无关，覆盖完整。
- MySQL ER_DUP_ENTRY（errno 1062）不满足两段 23505 专用块（has23505Anywhere / definitelyHas23505 均 false），只会走 :741 之后的通用路径 → 必经 PRIMARY check。PG 侧无 'PRIMARY' key 形态（约束名为 `<tbl>_<col>_key` / `_pkey`，后者由 R2 check 处理）。
- 两处同型空串回退（:318-324 / :653-659）一致用 `??`：payload 空串被保留（`payloadValue !== undefined && !== null` 判空），R3 目的达成。
- 活跃路径 `||` 吞空串核查：
  - 第一段 :345-349 / :376-382：columnsWithData 过滤器保证至少一键非 null/''，`||` 不会把可恢复的空串变 unknown；全空串 payload 场景下 PG detail `Key (col)=()` 先经 R3 回退恢复 ''，链在前段已闭合。
  - 第三段 :962-968 / :1085 `||` + `value || 'unknown'`：MySQL 空串重复（`Duplicate entry ''` 不匹配 `[^'']+`）→ value='unknown' 但 fieldName 归因正确。触发前提 = mysql NC-DB 部署 + 空串冲突，本部署（PG）不可达 → backlog B2。
  - 第二段 :583-739 整块为不可达死代码：任何 23505 形态必先被第一段（检查集等价）throw 或 R2 return，到不了第二段。其 else 分支（:699-701）有「已归因 column 被覆盖为 uniqueColumns[0]」潜伏 bug → backlog B3。

### 2. sqlite 拒绝面

- validateUniqueConstraint 三入口 = 全部 API DDL 入口：columnAdd（columns.service.ts:4035）、columnUpdate（:1328）、tableCreate（tables.service.ts:1166）。
- columnBulk（POST columns/bulk）add/update op 逐条代理 `this.columnAdd` / `this.columnUpdate`（columns.service.ts:7649-7665 区域），同一 validate，无旁路。
- UUID 建列有 source.type 白名单 pg/mssql（columns.service.ts:4142），sqlite 直接 400；UUID 强制门（tableCreate :1147-1153 / columnAdd :4156）限定 is_meta/is_local，与 sqlite 拒绝正交。
- meta-diffs（colMeta.unique 同步，meta-diffs.service.ts:1072-1080）：只读外部库真实 schema 写 meta，不产生 DDL，非 NC-DB sqlite 注入面。
- form-columns columnBulkUpdate 只动 order/row_id，不触 unique。
- SqliteClient：createTable（change=0）/addColumn（change=1）UNIQUE 生成已注释（R3 注释属实）；change=2 改列（SqliteClient.ts:2178）仍生成 UNIQUE——但到达需 meta.unique=true 且过 columnUpdate validate（sqlite+unique=true 被 :62-66 拒），API 链闭合 → backlog B4（注释不准确）。

### 3. UUID 建表强制门 + ck 映射 + PG 内联 UNIQUE（实测）

实测：:8080 建 base + 表（Title unique:true / RowId UUID 不传 unique / Num），查 nocodb-dev（qnap pg18）：

- meta 层：RowId unique=true（R3 建表门生效）、Title unique=true（API 响应确认）。
- DB 层：`r4uuid_*_row_id_key` UNIQUE btree(row_id)、`r4uuid_*_title_key` UNIQUE btree(title) 均落库——PgClient createTable change=0 内联 UNIQUE（PgClient.ts:3202-3203）生效。
- internal_meta=null（建表路径不写约束名）：disable 实测 PATCH unique=false → PgClient :2596-2636 缺名兜底 queryUniqueConstraintName 查库回填 → DB 索引删除成功（TITLE_INDEX_DROPPED）。链完整。
- ck 映射：meta unique ↔ pg_index.indisunique 一致（columnList :856-909 读 TC CONSTRAINT_TYPE='UNIQUE'）。
- 清理：测试 base 已删（DELETE 200）。

### 4. bulkUpdateAll catch 时序

- bulkUpdateAll **无事务**：单 UPDATE 经 execAndParse autocommit 直跑（BaseModelSqlv2.ts:4810-4812），catch（:4819）不存在 rollback——UPDATE 原子失败库态未变，handler 用 baseModel.dbDriver（非 trx）查到的即冲突现场，findDuplicateColumnByQuery 归因正确。
- bulkUpdate（:4639-4647）：trx rollback 先于 handler（内层 :4574 回滚并置 null，外层 :4640 兜底，无双 rollback）；回滚后查 committed 状态——冲突既有行仍在 → query 命中正确列；冲突值仅存在于本 trx 写入（批内互撞）时 query miss → fallback columnsWithData 取 payload 第一有值 unique 列，列与值仍归因正确。
- bulkInsert（insert.ts:697）trx rollback 先于 handler。handler 查询均不在 trx 内，无自锁/脏读。

### 5. 全消费点终清点 + 测试

- handleUniqueConstraintError 消费点全量 = 5：BaseModelSqlv2.ts:2900（update）、:4642（bulkUpdate）、:4821（bulkUpdateAll）、insert.ts:234（单条 insert）、:699（bulkInsert）。read/delete/list 无 DML 冲突面，不接合理。
- jest：13/13 passed（uniqueConstraintHelpers.Fork.spec.ts）。
- tsc --noEmit：0 error。
- jest.config.js：Fork 桶 + ts-jest isolatedModules（TS 5.8 兼容），合理。

## Backlog（非本轮 error，不计违反）

- B1 handler 第一段 R2 return 门槛：extracted 列名在 modelColumns（全列）找得到即不查 `_pkey`——PG PK 冲突（列如 id 总在 meta）会以 fieldName=<PK 列> 抛 UniqueConstraintViolationError 而非传播原始错误。可达性弱（NC-DB PK serial/DB 生成 + insert readonly guard 拒用户传值，仅序列错位类运维事故可触发），且唯一性冲突语义未失真。
- B2 第三段通用路径 MySQL 空串 value 被 `||` 吞成 'unknown'（:962-968/:1085），fieldName 归因正确；需 mysql NC-DB + 空串重复，本部署不可达。
- B3 第二段（:583-739）23505 块为不可达死代码，内部 else（:699-701）有 column 覆盖潜伏 bug；建议后续清理重复段以免未来改动第一段时暴露。
- B4 SqliteClient.ts:2178 change=2 仍生成 UNIQUE，与 R3 注释「alterColumn drop silently」不符；API 链已被 validate 封死，注释可修正。
- B5 src/helpers/isUniqueViolation.ts 与 uniqueConstraintErrorHandler.ts 模块级 isUniqueViolation 均零消费者（两份同名死代码）；建议删除或接线。
