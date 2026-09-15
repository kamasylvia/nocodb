# r1-f01-int-b.md — 集成测试-对抗面（独立第 2 路）

> 账号 r1b@ce-ee.local；base `f01r1b_base`(pxbnhywy4kng1s6)，表 `f01r1b_t1`(mjv3kyrlgxt7oc9)，unique 列 U(ci14kx37ff5r11u)/N(cksxazlyck50q2h)。全部实测于 http://127.0.0.1:8080 + nocodb-dev（schema `pxbnhywy4kng1s6`）。测毕 base 已删（软删 trash 机制，schema 残留属 base trash 行为，非 F01 范畴）。
> 环境注：r1b 注册默认 org-level-viewer 无法 baseCreate；按 r1a 先例（nc_users_v2 同值）DB 提权 `org-level-creator,super` 后方可测试。非 F01 缺陷。

## PASS 项（附证据）

**T1 bulk 插入 — PASS**
- 批内两条同值 `[{"U":"dup1"},{"U":"dup1"}]` → `400 {"error":"FIELD_UNIQUE_CONSTRAINT_VIOLATION","message":"U field unique constraint violation. Value 'dup1' already exists.","fieldName":"U","value":"dup1"}`，回查 `where=(U,eq,dup1)` totalRows=0（整批回滚）。
- 批内撞已存在值 `x` → 同型 400，批内另一条 `y` 未落库（totalRows=0）。

**T2 记录更新冲突 — PASS（错误形态见 I2）**
- `PATCH /api/v2/tables/mjv3kyrlgxt7oc9/records`（body 带 Id）`{"Id":6,"U":"x"}` 撞已存 x → `400 {"error":"ERR_DATABASE_OP_FAILED","message":"U field unique constraint violation. Value 'x' already exists.","code":"23505","details":{"column":"U","value":"x"}}`，回查 U 仍为 z（未部分更新）。
- 自值不变 PATCH → 200；U 置 null → 200（NULL 多值允许）。
- bulk PATCH 两条同值 `[{"Id":6,"U":"bk"},{"Id":3,"U":"bk"}]` → 400，且两行 U 均未被改（无部分落库，事务性回滚）。

**T3 并发竞态 — PASS**
- 5 并发 curl 同插 `U=race1` → 恰 1 个 `200 {"Id":7}`，4 个 `400 FIELD_UNIQUE_CONSTRAINT_VIOLATION`；落库 `where=(U,eq,race1)` totalRows=1。

**T4 undo/redo 与 move — PASS**
- `POST .../records?undo=true` 正常插入（200）；同参数插重复值 x → 400（**undo 不绕过约束**）。
- `PATCH .../records?undo=true` 正常 200。
- `POST .../records/6/move {"order":"0.5"}` → 201 true。

**T5 非法输入 — PASS 部分，1 实锤 issue（I1）**
- `unique:"yes"` → 200，约束真实创建（DB 索引 `uk_pxbnhywy4kng1s6_..._cksxazlyck50q2h` 验证在案），但 meta `unique` 存字符串 `"yes"`（类型污染，并入 I1）。
- `unique:null` → 200，meta unique=None、internal_meta 清空、DB 索引删除、重复插入恢复放行。语义正确（视同关闭）。
- `unique:"false"` → **见 I1（反向开启约束，实锤）**。

**T6 改名/删除 — PASS**
- title 改名 `U→Urenamed`：约束行为保持（同值插入 400，且错误 fieldName 跟随新 title：`"Urenamed field unique constraint violation..."`）；cn/索引不动。
- 物理改名 `column_name U→U2`：PG 索引自动跟随（indexdef `... USING btree ("U2") WHERE ...`），约束保持。
- `DELETE /api/v2/meta/columns/{id}`：DB unique 索引同步消失（pg_indexes 前后比对在案）。

**T7 重复值上限（代码评估）— PASS**
- `duplicate-detection.service.ts:41 checkForDuplicates`：存在性检查 = `SELECT col, COUNT(*) GROUP BY col HAVING COUNT(*)>1 LIMIT 1`，单条聚合查询、LIMIT 1，不物化行集；仅当确有重复时才补 2 条聚合 COUNT（total/distinct）算 count。10 万行 = 1-3 条顺序聚合查询，无逐行取回、无无界结果，不会因行数超限失真；无分页需求，实现正确。
- 行为实测：脏数据（nl1×2）开 unique → `400 {"msg":"Found 1 duplicate values in this field. Please edit or remove duplicates before enabling uniqueness."}`；清重后重开 200。
- 附加边界实测：LongText 开 unique → 400 `Unique constraint is not supported for field type 'LongText'`；cdf+unique 互斥（列更新、列创建两路均 400 `Cannot enable unique constraint because a default value is set...`）。

## Issues

**I1（实锤，实测复现）`packages/nocodb/src/services/columns.service.ts:1309-1343` + `:688-693` + `packages/nocodb/src/db/sql-client/lib/pg/PgClient.ts:2593,3385`: PATCH 列传 `unique:"false"`（字符串假值）被真值判定反向「开启」unique 约束：建议入参强制布尔化或拒绝非布尔**
- 证据：非 unique 列 N 上 `PATCH /api/v2/meta/columns/cksxazlyck50q2h {"unique":"false"}` → 200；meta `unique` 存字符串 `'false'`；DB 新建 partial unique 索引 `uk_pxbnhywy4kng1s6_..._cksxazlyck50q2h ... USING btree ("N") WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`；行为验证两条同 N 值插入第二条 400 `N field unique constraint violation. Value 'sameN' already exists.`。用户意图为关闭，结果约束被开启 + meta 被字符串污染。
- 根因：`columns.service.ts:1309` `'unique' in param.column` 进分支后各处直接用 `param.column.unique` 真值判定（1311/1315/1317/1331/1455 全按 truthy；1323 的 `!!` 只影响 validate 入参不改变流程走向）；`:688-693` `uniqueValue` 原样透传字符串；`PgClient.ts:2593/3385` `!!args.columns[i].unique` → `!!"false"===true` 走「加约束」分支。`unique:"yes"` 同路径会把字符串 `'yes'` 写入 meta（类型污染）。
- 建议：入口归一（如 `unique === true || unique === 'true'` 才算开，其余字符串视为关或直接 422 拒绝非布尔），并保证落 meta 为布尔。

**I2（不一致，中低）`packages/nocodb/src/db/BaseModelSqlv2/insert.ts:234,699` vs update 路缺失 + `packages/nc-gui/utils/errorUtils.ts:82-84`: 插入与更新两路 unique 冲突错误形态不一致，且前端判定函数对更新路消息失配：建议 update 路接 handleUniqueConstraintError 或归一错误码**
- 证据：insert 撞值 → `error=FIELD_UNIQUE_CONSTRAINT_VIOLATION`（exception-mapper.ts:93-107 UCVE 分支）；update 撞值 → `error=ERR_DATABASE_OP_FAILED`+`code 23505`+`details`（pg.extractor.ts:65-124 兜底路径；`handleUniqueConstraintError` 仅 insert.ts 两处接线，update 无调用）。前端 `isUniqueConstraintViolationError`（errorUtils.ts:76-86）依赖 `error===FIELD_UNIQUE_CONSTRAINT_VIOLATION` 或消息含 `'Unique constraint violation'`（大小写敏感），更新路消息 `"U field unique constraint violation."`（小写 u）两条件均不命中 → 依赖该判定的 UI（`useFillHandler.ts`、`useInfiniteData.ts`）对更新冲突走不到唯一约束特判。
- 建议：update 路接 `handleUniqueConstraintError`（与 insert 对齐），或放宽 errorUtils 匹配（小写化比较）。

**I3（语义不一致，低）`packages/nocodb/src/db/sql-client/lib/pg/PgClient.ts:3201-3204` vs `:3540-3616`: unique 约束对软删行的语义随列创建途径而异：建议统一走 partial index 或明示差异**
- 证据：建表时带 `unique:true` 的列 U → 全量 `CREATE UNIQUE INDEX f01r1b_t1_U_key ... USING btree ("U")`（无 WHERE，软删行永久占用该值）；列后开 unique（PATCH 或后加列）→ partial `... WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`（软删行释放值）。同一功能两种回收语义。
- 建议：change===0 内联 UNIQUE 分支改走 `addUniqueConstraintToQuery`（软删感知），保证全 fork 一致。

## 结论（裁决输入）

- 7 项对抗面实测：T1/T3/T4/T6/T7 干净 PASS；T5 中 `unique:"false"` 实锤反向开启（I1，实测复现）；T2 功能正确但错误码形态不一致（I2）；另捕获创建途径语义分裂（I3）。
- I1 为必修（有源可修：入参归一）；I2/I3 属实建议同批修。按规则单路属实经实测验证 → 修但不入计数。
