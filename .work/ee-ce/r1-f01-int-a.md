# r1-f01-int-a — F01 Unique 集成测试报告（第 1 路：正向+边界）

> 会审子代理独立第 1 路。实测环境：dev server http://127.0.0.1:8080（nocodb-dev 库 @ qnap.elf-balance.ts.net:5432），测试账号 r1a@ce-ee.local（经 PG 提升为 org-level-creator,super，因新注册默认 org-level-viewer 无法 baseCreate）。测试 base `f01r1a_unique`（id pzpajhv8at9can1）+ 两张表，测后已 DELETE base 清理，临时文件已删。

## 裁决结论

**issues：2**（均为一致性/设计-行为脱节类，非功能损坏；核心 CRUD/校验/约束路径全部实测通过）

---

## 逐项结果

### T1 支持类型全覆盖 — PASS

建表 `f01r1a_types`（11 列 unique:true 一次建齐）：SingleLineText/Email/PhoneNumber/URL/Number/Decimal/Currency/Percent/Date/DateTime/Time。

- meta：全部 `unique:true` 回读（POST /api/v2/meta/bases/{baseId}/tables 响应 11 列逐一确认）。
- PG：11 个 unique btree index 全部落库（`information_schema`/`pg_index` 实查，schema `pzpajhv8at9can1`，索引名 `f01r1a_types_{col}_key` ×11）。
- 证据摘录：`f01r1a_types_txt_key ... USING btree (txt)`、`f01r1a_types_num_key ... USING btree (num)` 等 11 条 indexdef 全数命中。

### T2 不支持类型 — PASS

POST /api/v2/meta/tables/{tableId}/columns 逐个加列（Attachment/Checkbox/Lookup/Rollup/LongText，各带 unique:true）→ 5/5 返 400：

```
{"msg":"Unique constraint is not supported for field type 'Attachment'"} HTTP:400
{"msg":"Unique constraint is not supported for field type 'Checkbox'"} HTTP:400
（Lookup / Rollup / LongText 同格式）
```

信息含具体类型名，明确。

### T3 cdf 互斥 + UUID 例外 — PASS

- 3a 新列 cdf+unique → 400 `Cannot enable unique constraint because a default value is set...`
- 3b 已有 unique 列设 cdf（PATCH /api/v2/meta/columns/{colId}）→ 400 `Default values are not allowed for unique fields...`
- 3c UUID 列 unique + `meta.aggregate_auto_generate` → 200，`internal_meta.unique_constraint_name` 落值。

### T4 值唯一性 — 结果如实记录（行为=精确匹配；与 normalize 设计不一致 → issue I2）

- 文本：插入 `Abc`（Id=1）→ `abc `（Id=2，HTTP 200）→ `ABC`（Id=3，HTTP 200）。PG 实查确认三行原样共存（`[2,'abc ',4]` 含尾空格 4 字符）。**大小写/首尾空格均不归一、不判重**。
- 数字：`Num=1` 重复插入 → 400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION ... Value '1' already exists`（友好错误）。
- Decimal：`Dec=1` 后 `Dec=1.0` → 400 同上（PG numeric 数值等价语义判重，正确）。
- bulk 数组内重复（`[{"Txt":"bulk_x","Num":100},{"Txt":"bulk_x","Num":101}]`）→ 400 整体拒绝，事务性正确。

### T5 NULL 语义 — PASS

`Num` 唯一列多行 NULL/缺省（Id=7,8,9 三行）全部 200，无冲突。PG 默认 unique 索引 NULL 不参与判重，行为正确。

### T6 改列路径 — PASS

表 `f01r1a_alt` 列 `Nq`：

- 6a 重复预检：两行 `dup` 后 PATCH `unique:true` → 400 `Found 1 duplicate values in this field. Please edit or remove duplicates before enabling uniqueness.`
- 6b 清重后开 → 200，`internal_meta.unique_constraint_name` 落值。
- 6c 开后插重复 → 400 友好错误；meta 回读 `unique:true`。
- 6d PATCH `unique:false` 关 → 200，随后插重复值 → 200。
- soft-delete 复用：API 删除行后同值重插 → 200（删除为物理删除；且该索引带 `WHERE __nc_deleted IS NULL OR =false` 条件，见 I1）。

### T7 外部源行为（仅代码确认）— PASS（代码层面）

- `packages/nocodb/src/helpers/uniqueConstraintHelpers.ts:34-38`：`source && !is_meta && !is_local` → 400 `Unique constraint is only supported for NC-DB (not external databases)`。
- 调用点均传 source：`columns.service.ts:1319`（columnUpdate）、`columns.service.ts:4023`（columnInsert，构造 `{is_meta,is_local,type}`）、`tables.service.ts:1150`（tableCreate，同构造）。逻辑闭环，未实测外部 DB（按任务书）。

---

## issues 列表

**I1**（中低，一致性问题/未来隐患）
`packages/nocodb/src/services/tables.service.ts:1150`（tableCreate 路径） vs `columns.service.ts:4023`（column update 路径）：两条路径生成的 PG unique 索引结构不一致——建表路径为 non-partial，改列路径为 partial：
- 建表路径实测 indexdef：`CREATE UNIQUE INDEX f01r1a_types_txt_key ... USING btree (txt)`（`indpred IS NOT NULL = false`）
- 改列路径实测 indexdef：`CREATE UNIQUE INDEX uk_... USING btree (nq) WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`

后果（实测复现）：non-partial 索引表中一行被标 `__nc_deleted=true` 后（PG 模拟软删），同值插入被拒：400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION ... Value 'ABC' already exists`——该值在用户视图中不可见却判重复且不可复用；partial 路径同场景重插 200 正常。CE 现状 `Model.isTrashEnabled` 硬编码 `false`（`packages/nocodb/src/models/Model.ts:123-125`），API 无软删写路径，故现网不可触发；但 `__nc_deleted` 列、软删 filter（`BaseModelSqlv2.ts:10443 getSoftDeleteFilter`）、duplicate 预检的软删排除（`duplicate-detection.service.ts applySoftDeleteFilter`）均已存在，trash 一旦解封即成真 bug。
建议：tableCreate 路径生成 unique 索引时与 column update 路径对齐，统一带 `WHERE __nc_deleted IS NULL OR __nc_deleted = false` 条件。

**I2**（低，设计-行为脱节）
`packages/nocodb/src/helpers/uniqueConstraintHelpers.ts:79 normalizeValueForUniqueCheck`：设计为 trim+lowercase 文本归一，实际仅被 `duplicate-detection.service.ts:171 validateUniqueValue` 引用，而后者自注释 "keeping this function for future reference... at the moment it's not used anywhere"。任务书明示设计意图 trim+lowercase，实测（T4）唯一性完全由 PG 精确匹配执行——`Abc`/`abc `/`ABC` 三行共存。前端若存在"已存在同值（忽略大小写）"类提示将与后端行为不一致。行为本身（精确匹配）自洽且可预期，但归一 helper 与实际执行语义脱节。
建议：要么删除/标注 `normalizeValueForUniqueCheck` 为未启用设计稿，要么在 insert/update 预检真正接入归一语义（需同步处理 PG 索引侧，如函数索引 `lower(trim(col))`），二选一，消除意图与行为的分叉。

---

## 测试方法备注

- 全部经 curl/jq 实测 + `uv run --with pg8000 python3` 直查 nocodb-dev（凭证经 Infisical KDL 运行时拉取，未落盘）。未连接 `nocodb` 生产库。
- 环境注意（非 issue）：Infisical CLI `login` 当前必须显式传 `--domain $INFISICAL_URL`，否则落到 app.infisical.com 报 Invalid credentials（与全局 AGENTS §2.3.2 正本流程不符，正本 login 步骤无 `--domain`）。
- 测试资源已清理：base `pzpajhv8at9can1` DELETE 200；`/tmp/f01r1a_*` 临时文件已删。
