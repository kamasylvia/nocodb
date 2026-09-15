# r5-f01-int-a — F01 Unique 集成测试(正向+边界)第 5 轮报告

范围:F01「Unique values only」R4 修复后全实测回归。环境:127.0.0.1:8080 dev server + nocodb-dev(PG 18.2, qnap.elf-balance.ts.net:5432)。资源前缀 f01r5a_,测后 base 删除 + 孤儿 schema 手动 DROP 并验证 0 残留。

## 结论

PASS(附 1 条低危一致性 issue + 2 条非 F01 观察,均附证据,供裁决)。

## 分项结果

### T1 支持类型建表 unique:true → meta + PG 索引:PASS

- 建表 `f01r5a_supported`,12 个支持类型(SingleLineText/Email/PhoneNumber/URL/Number/Decimal/Currency/Percent/Date/DateTime/Time/UUID)各带 unique:true → HTTP 200。
- meta:12 列 `unique=true`;UUID 列额外 `readonly=true, cdf=gen_random_uuid()`(符合 UUID gate 设计)。
- PG:`pg_indexes` 确认 12 个 UNIQUE INDEX 全部存在(如 `f01r5a_supported_txt_key ... UNIQUE INDEX ... (txt)`、`..._uud_key ... (uud)`)。
- UUID 例外验证:显式传 `unique:false` 建列仍被强制 `unique=true, readonly=true`(addCol uu3 实测)。

### T2 不支持类型/richMode → 400:PASS

- addCol 路径 12 种:LongText/Checkbox/SingleSelect/MultiSelect/Attachment/JSON/Geometry/Rating/Formula/Rollup/Links/User + unique:true → 全 400,报错 `Unique constraint is not supported for field type '<X>'`。
- LongText+meta.richMode+unique:true → 400(addCol 与 createTable 双路径均实测)。
- createTable 路径抽查(Checkbox、richMode LongText)→ 400,且 `pg_tables` 确认无残留半建表。

### T3 UUID 双路径一致性(R4 修复验证):PASS(附 issue-1)

建表路径(f01r5a_supported.uud)与加列路径(f01r5a_uuidadd.uu2,不显式传 unique)对比:

| 检查项 | 建表路径 | 加列路径 |
|---|---|---|
| meta unique | true | true(未传 flag 仍强制) |
| meta readonly | true | true |
| 显式插 UUID 值 | 400 `Column "uud" is readonly column and cannot be updated` | 400 同型(uu2) |
| 显式 PATCH UUID 值 | 400 readonly guard(update 路径同拦) | — |
| PG 唯一索引 | 存在(`f01r5a_supported_uud_key`,普通) | 存在(`uk_..._crwipz5qq2x1r6b`,partial) |
| internal_meta 约束名 | null(禁用时回落 DB 查询可用,见 T7) | `unique_constraint_name` 正确存储 |
| SingleLineText→UUID 转换 | 400 `Cannot convert 't2u' to UUID. UUID values are auto-generated...`(明确拒绝,无半改状态) | 同 |

四项核心行为(meta/readonly/插值拒绝/索引存在)双路径一致。

**issue-1(低危,当前行为无差异)**:索引类型双轨。tableCreate 生成的唯一索引是普通索引(无 WHERE);addColumn 与 columnUpdate(enable/re-enable)生成 partial 索引 `WHERE __nc_deleted IS NULL OR __nc_deleted = false`。实测:建表 `..._txt_key` 无 WHERE,addCol `utx`、re-enable 后的 `txt`(uk_..._ckv55iepybyt8cy)均带 WHERE。行为影响仅在 soft delete 生效时(trash 后值释放 vs 保留);当前 fork `Model.isTrashEnabled` 硬编码 `false`(packages/nocodb/src/models/Model.ts:123),删除为硬删,两型索引行为等价。建议:统一 tableCreate 路径与 add/update 路径的索引形态(倾向统一为 partial),或在解 trash 功能前记录该已知差异。

### T4 cdf 互斥双向 + UUID 例外;判重全项:PASS

- 双向互斥:addCol `unique:true+cdf:'x'` → 400 `Cannot enable unique constraint because a default value is set...`;createTable 同组合 → 400 同文案;对已有 cdf 列 PATCH `unique:true` → 400 同文案;对 unique 列 PATCH `cdf` → 400 `Default values are not allowed for unique fields...`。
- 例外:`unique:false+cdf` → 200 正常;UUID 列 unique(强制)+cdf=gen_random_uuid() 合法共存。
- 判重全项(均返回 `FIELD_UNIQUE_CONSTRAINT_VIOLATION` + 正确 fieldName/value):
  - SingleLineText 撞值:`Value 'u1' already exists`,fieldName=txt。
  - **空串重复(R3 修复验证)**:插入 `{"txt":""}` 两次 → 第二次 400,message `Value '' already exists`,value=`''`(空串 fallback 正确,非 'unknown')。
  - Number:第二次 `{"num":5}` → 400,fieldName=num,value=5。
  - Date:第二次 `{"dte":"2026-01-01"}` → 400,fieldName=dte。
  - NULL 可重复(标准 PG NULLS DISTINCT 语义):多次不传 txt → 均 200。

### T5 布尔归一回归 + sqlite 拒绝:PASS

- 归一(addCol/PATCH 路径):`unique:1`/`unique:'true'`(数字/字符串)→ 400 `The unique flag must be a boolean value`(normalizeUniqueConstraintFlag)。
- createTable 路径:JSON schema Bool oneOf 拒绝字符串 → 400(验证层拦截)。无 truthy 字符串放行路径,回归成立。
- sqlite 拒绝(代码路径核验,按任务要求):`packages/nocodb/src/helpers/uniqueConstraintHelpers.ts:63-68` 在 validateUniqueConstraint 前置拒绝 `source.type === 'sqlite'|'sqlite3'` → 400 `Unique constraint is not supported for SQLite databases`;且位于类型支持检查之前,顺序正确。
- **观察-2(非 F01 错误)**:addCol 传 `unique:"true"`(字符串)时被 columnAdd 的 JSON schema oneOf 先拦,报错文案错位为 `'uidt' must be one of: Formula, ...`(实际由 unique 非布尔触发);仍为 400 无放行风险,仅文案可读性问题。

### T6 五条写路径撞值 → FIELD_UNIQUE_CONSTRAINT_VIOLATION:PASS

| 写路径 | 触发 | 结果 |
|---|---|---|
| 单插 POST /records(object) | txt='u1' 撞已有 | 400,error=FIELD_UNIQUE_CONSTRAINT_VIOLATION,fieldName=txt,value=u1 |
| bulk 插 POST /records(array) | 批内重复(b1,b1) + 撞已有(c1,u1) | 均 400 + fieldName/value;批内首条 b1 已回滚(`pg` 无 b1 残留,事务性成立) |
| PATCH /records(单对象) | Id=9 改 txt='u1' | 400 + fieldName/value |
| PATCH /records(数组) | Id=1/Id=9 同改 'zz' | 400 + fieldName/value;行 1 值未被污染 |
| bulkUpdateAll(v1 `PATCH /api/v1/db/data/bulk/noco/{baseId}/{tableId}/all?where=...`) | where=(Id,eq,9) 改 txt='u1' 撞行 1;where=(Id,in,3,9) 两行同改 'm9' | 均 400 + fieldName/value;非冲突更新(where 指定行改新值)正常返回 count=1 且仅目标行变化 |

注:bulkUpdateAll 的 `where` 是 **query string 参数**,body 仅放 data(body 内嵌 where/data 会被整体当作 data、where 被忽略)——为调用契约,非缺陷,但易误用。

### T7 并发、列生命周期、错误体:PASS

- 并发:4 路并行插同值 → 恰 1 条 200,3 条 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION;DB 中该值恰 1 行。
- 改名(title):c_unq→c_unq_r → meta `unique=true` 与 internal_meta 约束名保留,PG 索引仍在。
- 禁用:PATCH unique:false → meta unique=false,PG 索引删除(create 路径列 internal_meta=null 时回落 DB 查询约束名成功,索引确实 DROP)。
- 重启用撞值拦截:禁用后插入 2 行同值 'dd' → PATCH unique:true → 400 `Found 1 duplicate values in this field...`(count 语义 = 冗余行数 total-distinct=1,与实现一致)。
- 重启用成功路径:txt 无重复 → 禁用→重启用 → 200,新唯一索引生成。
- 删列:DELETE column → meta 移除,对应唯一索引消失(`pg_indexes` 0 行)。
- 错误体:5 条写路径全部含 `error/message/fieldName/value` 四字段(exception-mapper FIELD_UNIQUE_CONSTRAINT_VIOLATION 分支)。

## 清理

- base p05z8z2pmbgn51n 删除 → meta 404。
- **观察-3(非 F01 错误)**:base 删除后 per-base schema `p05z8z2pmbgn51n` 与 2 张表残留于 nocodb-dev(base 删除不 DROP SCHEMA,疑似既有行为,非 F01 引入)。已按任务要求手动 `DROP SCHEMA ... CASCADE`(前置断言 schema 内仅 f01r5a_ 表);终态验证:`tablename like 'f01r5a_%'` 全库 0 行,`f01r5a_t2tc*` 等半建表 0 残留。

## Issues 汇总(供裁决)

- issue-1(低危,当前无行为差异):唯一索引 partial/普通双轨,tableCreate 与 add/update 路径不一致;isTrashEnabled 硬编码 false 下等价,解 trash 时需统一。证据见 T3。
- 观察-2:unique 字符串值的 schema 报错文案错位(仍 400 拒绝)。
- 观察-3:base 删除不清理 per-base schema(既有行为,已手动清理)。

无 ≥2 路必修复类 error。
